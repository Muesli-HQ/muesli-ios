import AVFoundation
import CoreML
import FluidAudio
import Foundation
import os

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
    private var loadedFingerprint: String?

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
            KeyboardSpeechModel.recordKeyboardState(.tooLittleMemory, modelID: manifest.modelID)
            KeyboardDiagnosticsLog.record("parakeet.skipped", [
                "limitMB": String(limit / 1_048_576),
                "availableMB": String(Self.availableMemory() / 1_048_576)
            ])
            state = .unavailable
            return
        }

        guard !KeyboardSpeechModel.previousLoadDidNotFinish(manifest: manifest) else {
            KeyboardSpeechModel.recordKeyboardState(.failed, modelID: manifest.modelID, fingerprint: manifest.sourceFingerprint)
            KeyboardDiagnosticsLog.record("parakeet.skippedAfterFailedLoad", ["model": manifest.modelID])
            state = .unavailable
            return
        }
        KeyboardSpeechModel.recordKeyboardState(.loading, modelID: manifest.modelID, fingerprint: manifest.sourceFingerprint)
        KeyboardDiagnosticsLog.record("parakeet.loading", [
            "model": manifest.modelID,
            "limitMB": String(limit / 1_048_576),
            "footprintMB": String(Self.footprint() / 1_048_576)
        ])
        loadedFingerprint = manifest.sourceFingerprint
        let fingerprint = manifest.sourceFingerprint
        let startedAt = ContinuousClock.now
        let task = Task { [weak self] in
            do {
                let runner = try await Runner.load(manifest.version, from: directory)
                guard let self, self.loadedFingerprint == fingerprint else {
                    await runner.cleanup()
                    return
                }
                self.state = .ready(runner, manifest)
                self.onReady?()
                KeyboardSpeechModel.recordKeyboardState(.ready, modelID: manifest.modelID, fingerprint: fingerprint)
                KeyboardDiagnosticsLog.record("parakeet.ready", [
                    "model": manifest.modelID,
                    "loadSeconds": String(format: "%.1f", Self.seconds(since: startedAt)),
                    "footprintMB": String(Self.footprint() / 1_048_576),
                    "peakMB": String(Self.peakFootprint() / 1_048_576)
                ])
            } catch {
                guard let self, self.loadedFingerprint == fingerprint else { return }
                self.state = .unavailable
                KeyboardSpeechModel.recordKeyboardState(.failed, modelID: manifest.modelID, fingerprint: fingerprint)
                KeyboardDiagnosticsLog.record("parakeet.loadFailed", [
                    "reason": String(String(describing: error).prefix(64))
                ])
            }
        }
        state = .loading(task, manifest)
    }

    /// Waits for a load in progress (the recording itself never waits), then
    /// transcribes.
    func transcribe(_ samples: [Float]) async throws -> String {
        if case .loading(let task, _) = state {
            let waitStarted = ContinuousClock.now
            let finished = await Self.wait(for: task, limit: Self.loadWaitLimit)
            KeyboardDiagnosticsLog.record("parakeet.waitedForLoad", [
                "seconds": String(format: "%.1f", Self.seconds(since: waitStarted)),
                "finished": finished ? "true" : "false"
            ])
        }
        guard case .ready(let runner, let manifest) = state else { throw CancellationError() }
        guard Self.availableMemory() >= KeyboardSpeechModel.requiredAvailableBytes / 2 else {
            KeyboardDiagnosticsLog.record("parakeet.skippedTranscribe", [
                "availableMB": String(Self.availableMemory() / 1_048_576)
            ])
            throw CancellationError()
        }
        let startedAt = ContinuousClock.now
        let text = try await runner.transcribe(samples)
        KeyboardDiagnosticsLog.record("parakeet.transcribed", [
            "model": manifest.modelID,
            "audioSeconds": String(format: "%.1f", Double(samples.count) / 16_000),
            "seconds": String(format: "%.2f", Self.seconds(since: startedAt)),
            "footprintMB": String(Self.footprint() / 1_048_576),
            "peakMB": String(Self.peakFootprint() / 1_048_576)
        ])
        return text
    }

    /// Frees the model, for example on a memory warning. The next appearance
    /// loads it again.
    func unload() {
        if case .loading(let task, _) = state { task.cancel() }
        if case .ready(let runner, _) = state {
            Task { await runner.cleanup() }
        }
        state = .idle
        loadedFingerprint = nil
    }

    /// True if the task finished within `limit`.
    private static func wait(for task: Task<Void, Never>, limit: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await task.value; return true }
            group.addTask { try? await Task.sleep(for: limit); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
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
        }
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        switch self {
        case .tdt(let manager):
            var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
            return try await manager.transcribe(samples, decoderState: &state).text
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
        }
    }

    func cleanup() async {
        switch self {
        case .tdt(let manager): await manager.cleanup()
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
