import AVFoundation
import CoreML
import FluidAudio
import Foundation
import os
@preconcurrency import WhisperKit

/// Runs the speech model the app shared into the App Group (Parakeet TDT
/// variants, Phonon, Parakeet Unified, Nemotron or Parakeet Realtime) inside
/// the keyboard process. Loads only when the keyboard's memory limit and current
/// free memory allow it, and never uses the GPU, which keyboards can't use
/// from another app. Not compiled into the unit tests, which use a fake
/// `InKeyboardModelTranscribing`.
@MainActor
final class KeyboardParakeetEngine: InKeyboardModelTranscribing {
    /// Shared across keyboard presentations in one extension process, so the
    /// model loads once rather than on every open.
    static let shared = KeyboardParakeetEngine()

    /// The first compile after an install or app update can take ~20 s;
    /// warm loads from Core ML's cache are much faster.
    private static let loadWaitLimit: Duration = .seconds(60)

    private enum State {
        case idle
        case loading(Task<Void, Never>, KeyboardSpeechModel.Manifest)
        case ready(Runner, KeyboardSpeechModel.Manifest)
        case unavailable
    }

    private var state: State = .idle
    /// Fires when the model becomes ready, so Record can stop requiring
    /// Apple Speech.
    var onReady: (() -> Void)?
    private var loadAttempt: UUID?

    var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    var isPreparing: Bool {
        if case .loading = state { return true }
        return false
    }

    var canTranscribe: Bool { isReady || isPreparing }

    private var manifest: KeyboardSpeechModel.Manifest? {
        switch state {
        case .loading(_, let manifest), .ready(_, let manifest): manifest
        case .idle, .unavailable: nil
        }
    }

    var displayName: String? { manifest?.displayName }

    var maximumAudioSeconds: Double {
        manifest.map { KeyboardSpeechModel.maximumDurationSeconds(for: $0.version) }
            ?? KeyboardSpeechModel.maximumDurationSeconds
    }

    var engineIdentifier: String? {
        manifest.map { "\($0.engineIdentifier)-keyboard" }
    }

    /// Records the keyboard's memory limit for the app, then loads the shared
    /// model in the background if it fits. Safe to call on every appearance.
    func prepareIfPossible() {
        let limit = Self.measureMemoryLimit()
        KeyboardSpeechModel.recordMemoryLimit(limit)

        // The keyboard's model catalog holds the current pick, including one
        // made in the keyboard that the app has not adopted yet.
        let selected = (try? SharedStore().keyboardModelCatalog())?.selectedRawValue
        guard let manifest = KeyboardSpeechModel.readManifest(for: selected),
              let directory = KeyboardSpeechModel.modelDirectory(for: manifest.modelID) else {
            unload()
            return
        }
        if case .ready(_, let loaded) = state, loaded == manifest { return }
        if case .loading(_, let loading) = state, loading == manifest { return }
        unload()

        guard KeyboardSpeechModel.canHoldModel(memoryLimit: limit),
              Self.availableMemory() >= KeyboardSpeechModel.requiredAvailableBytes else {
            KeyboardDiagnosticsLog.record("parakeet.skipped", [
                "limitMB": String(limit / 1_048_576),
                "availableMB": String(Self.availableMemory() / 1_048_576)
            ])
            state = .unavailable
            return
        }

        guard !KeyboardSpeechModel.isUnsupported(manifest) else {
            // Failed or ended the keyboard before: never load this download
            // again. The keyboard uses Apple Speech, and its menu hides it.
            state = .unavailable
            return
        }
        if KeyboardSpeechModel.previousLoadDidNotFinish(manifest: manifest),
           !KeyboardSpeechModel.keepsEndingTheKeyboard(manifest: manifest) {
            // Once could be the keyboard closing mid-load; try again.
            KeyboardDiagnosticsLog.record("parakeet.retryAfterUnfinishedLoad", ["model": manifest.modelID])
        }
        guard !KeyboardSpeechModel.keepsEndingTheKeyboard(manifest: manifest) else {
            // Hide it from the keyboard's model menu for this download.
            KeyboardSpeechModel.markUnsupported(manifest)
            KeyboardSpeechModel.endLoad(manifest)
            KeyboardDiagnosticsLog.record("parakeet.skippedAfterFailedLoad", ["model": manifest.modelID])
            state = .unavailable
            return
        }
        KeyboardSpeechModel.beginLoad(manifest)
        KeyboardDiagnosticsLog.record("parakeet.loading", [
            "model": manifest.modelID,
            "limitMB": String(limit / 1_048_576),
            "footprintMB": String(Self.footprint() / 1_048_576)
        ])
        // Identifies this attempt, so a cancelled earlier load of the same
        // model can't install itself over this one.
        let attempt = UUID()
        loadAttempt = attempt
        let startedAt = ContinuousClock.now
        let task = Task { [weak self] in
            do {
                let runner = try await Runner.load(manifest.version, from: directory)
                guard let self, self.loadAttempt == attempt else {
                    await runner.cleanup()
                    return
                }
                self.state = .ready(runner, manifest)
                self.onReady?()
                KeyboardSpeechModel.endLoad(manifest)
                KeyboardDiagnosticsLog.record("parakeet.ready", [
                    "model": manifest.modelID,
                    "loadSeconds": String(format: "%.1f", Self.seconds(since: startedAt)),
                    "footprintMB": String(Self.footprint() / 1_048_576),
                    "peakMB": String(Self.peakFootprint() / 1_048_576)
                ])
            } catch {
                guard let self, self.loadAttempt == attempt else { return }
                self.state = .unavailable
                KeyboardSpeechModel.endLoad(manifest)
                KeyboardSpeechModel.markUnsupported(manifest)
                KeyboardDiagnosticsLog.record("parakeet.loadFailed", [
                    "reason": String(String(describing: error).prefix(64))
                ])
            }
        }
        state = .loading(task, manifest)
    }

    /// Waits for a load in progress (the recording itself never waits), then
    /// transcribes.
    func transcribe(_ samples: [Float]) async throws -> InKeyboardModelTranscript {
        if case .loading(let task, _) = state {
            let waitStarted = ContinuousClock.now
            let finished = await TaskDeadline.wait(for: task, limit: Self.loadWaitLimit)
            KeyboardDiagnosticsLog.record("parakeet.waitedForLoad", [
                "seconds": String(format: "%.1f", Self.seconds(since: waitStarted)),
                "finished": finished ? "true" : "false"
            ])
        }
        guard case .ready(let runner, let manifest) = state else { throw CancellationError() }
        // Checked per recording: longer audio needs more room. Without it iOS
        // ends the keyboard mid-transcription and nothing is pasted; with
        // Apple Speech's transcript, the dictation still completes.
        let audioSeconds = Double(samples.count) / 16_000
        let needed = KeyboardSpeechModel.requiredBytesToTranscribe(seconds: audioSeconds)
        let available = Self.availableMemory()
        guard available >= needed else {
            KeyboardDiagnosticsLog.record("parakeet.skippedTranscribe", [
                "model": manifest.modelID,
                "audioSeconds": String(format: "%.1f", audioSeconds),
                "availableMB": String(available / 1_048_576),
                "neededMB": String(needed / 1_048_576)
            ])
            throw CancellationError()
        }
        // Logged first, so a keyboard that iOS ends mid-transcription leaves a
        // trace in the diagnostics.
        KeyboardDiagnosticsLog.record("parakeet.transcribing", [
            "model": manifest.modelID,
            "audioSeconds": String(format: "%.1f", Double(samples.count) / 16_000)
        ])
        let startedAt = ContinuousClock.now
        let text = try await runner.transcribe(samples)
        KeyboardDiagnosticsLog.record("parakeet.transcribed", [
            "model": manifest.modelID,
            "audioSeconds": String(format: "%.1f", Double(samples.count) / 16_000),
            "seconds": String(format: "%.2f", Self.seconds(since: startedAt)),
            "footprintMB": String(Self.footprint() / 1_048_576),
            "peakMB": String(Self.peakFootprint() / 1_048_576)
        ])
        // Named after the model that actually ran, which can differ from the
        // one selected when recording started.
        return InKeyboardModelTranscript(text: text, engineIdentifier: "\(manifest.engineIdentifier)-keyboard")
    }

    /// Frees the model, for example on a memory warning. The next appearance
    /// loads it again.
    func unload() {
        if case .loading(let task, let manifest) = state {
            task.cancel()
            // A deliberate unload is not a crash: clear the loading marker so
            // the crash guard doesn't block this model next time.
            KeyboardSpeechModel.endLoad(manifest)
        }
        if case .ready(let runner, _) = state {
            Task { await runner.cleanup() }
        }
        state = .idle
        loadAttempt = nil
    }

    // MARK: - Memory

    /// The process's limit: what it uses now plus what iOS still allows.
    static func measureMemoryLimit() -> UInt64 {
        footprint() + availableMemory()
    }

    static func availableMemory() -> UInt64 {
        UInt64(os_proc_available_memory())
    }

    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// The highest footprint this process has reached: what counts against
    /// the keyboard's memory limit.
    static func peakFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.ledger_phys_footprint_peak) : 0
    }

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }
}

/// One loaded model and how to run it. Every configuration keeps to the CPU
/// and Neural Engine: keyboards can't use the GPU from another app.
private enum Runner: Sendable {
    case tdt(AsrManager)
    case unified(UnifiedAsrManager)
    case nemotron(StreamingNemotronMultilingualAsrManager)
    case eou(StreamingEouAsrManager)
    case whisper(KeyboardWhisper)

    static func load(_ version: KeyboardSpeechModel.Version, from directory: URL) async throws -> Runner {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        switch version {
        case .tdtCtc110m, .v3, .redux, .phonon:
            let asrVersion: AsrModelVersion = switch version {
            case .tdtCtc110m: .tdtCtc110m
            case .redux: .redux
            default: .v3
            }
            // Redux and Phonon run their encoders on the CPU, as in the app.
            let models = try await ParakeetModelLoading.loadAsrModels(
                from: directory,
                version: asrVersion,
                encoderComputeUnits: version == .redux || version == .phonon ? .cpuOnly : nil,
                modelComputeUnits: .cpuAndNeuralEngine
            )
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            if version == .phonon {
                // As in the app: Phonon is ready only after a first inference.
                var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
                _ = try await manager.transcribe([Float](repeating: 0, count: 16_000), decoderState: &state)
            }
            return .tdt(manager)
        case .unified:
            let manager = UnifiedAsrManager(configuration: configuration, encoderPrecision: .int8)
            try await manager.loadModels(from: directory)
            return .unified(manager)
        case .nemotron:
            let manager = StreamingNemotronMultilingualAsrManager(configuration: configuration)
            try await manager.loadModels(from: directory)
            return .nemotron(manager)
        case .eou320:
            let manager = StreamingEouAsrManager(configuration: configuration, chunkSize: .ms320)
            try await manager.loadModels(from: directory)
            return .eou(manager)
        case .whisper:
            let whisper = KeyboardWhisper()
            try await whisper.load(from: directory)
            return .whisper(whisper)
        }
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        switch self {
        case .tdt(let manager):
            // Keep every call on the single-pass path; see QuietSplit.
            var texts: [String] = []
            for range in QuietSplit.ranges(for: samples) {
                var piece = Array(samples[range])
                if piece.count < QuietSplit.sampleRate {
                    // Too short for the model on its own; pad with silence.
                    piece += [Float](repeating: 0, count: QuietSplit.sampleRate - piece.count)
                }
                var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
                let text = try await manager.transcribe(piece, decoderState: &state).text
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { texts.append(text) }
            }
            return texts.joined(separator: " ")
        case .unified(let manager):
            return try await manager.transcribeWithTimings(samples).text
        case .nemotron(let manager):
            await manager.reset()
            await manager.setPartialCallback { _ in }
            for start in stride(from: 0, to: samples.count, by: Self.chunk) {
                let buffer = try Self.buffer(from: samples, start: start)
                _ = try await manager.process(audioBuffer: buffer)
            }
            return try await manager.finish()
        case .eou(let manager):
            await manager.reset()
            for start in stride(from: 0, to: samples.count, by: Self.chunk) {
                let buffer = try Self.buffer(from: samples, start: start)
                _ = try await manager.process(audioBuffer: buffer)
            }
            return try await manager.finish()
        case .whisper(let whisper):
            return try await whisper.transcribe(samples)
        }
    }

    func cleanup() async {
        switch self {
        case .tdt(let manager): await manager.cleanup()
        case .whisper(let whisper): await whisper.unload()
        case .unified, .nemotron, .eou: break
        }
    }

    private static let chunk = 16_000

    /// One second of 16 kHz mono Float32 audio, as the app feeds streaming models.
    private static func buffer(from samples: [Float], start: Int) throws -> AVAudioPCMBuffer {
        let count = min(chunk, samples.count - start)
        guard let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let channel = buffer.floatChannelData?[0] else { throw CocoaError(.featureUnsupported) }
        buffer.frameLength = AVAudioFrameCount(count)
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress {
                channel.update(from: base + start, count: count)
            }
        }
        return buffer
    }
}

/// WhisperKit in the keyboard, from the shared folder the app prepared (model
/// and tokenizer together), so it never downloads. Kept in an actor because
/// `WhisperKit` itself isn't Sendable.
actor KeyboardWhisper {
    private var kit: WhisperKit?

    func load(from directory: URL) async throws {
        let configuration = WhisperKitConfig(
            model: nil,
            modelFolder: directory.path,
            tokenizerFolder: directory,
            // WhisperKit defaults the mel step to the GPU, which a keyboard
            // can't use from another app.
            computeOptions: ModelComputeOptions(
                melCompute: .cpuOnly,
                audioEncoderCompute: .cpuAndNeuralEngine,
                textDecoderCompute: .cpuAndNeuralEngine,
                prefillCompute: .cpuOnly
            ),
            verbose: false,
            logLevel: .error,
            prewarm: false,
            load: true,
            download: false
        )
        kit = try await WhisperKit(configuration)
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        guard let kit else { throw CancellationError() }
        let results: [TranscriptionResult] = try await kit.transcribe(audioArray: samples)
        return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func unload() async {
        await kit?.unloadModels()
        kit = nil
    }
}
