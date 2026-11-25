import CoreML
import FluidAudio
import Foundation
import os

/// Runs the Parakeet model the app shared into the App Group, inside the
/// keyboard process. Loads only when the keyboard's memory limit and current
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
        case ready(AsrManager, KeyboardSpeechModel.Manifest)
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

        guard let manifest = KeyboardSpeechModel.readManifest(),
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
                let models = try await ParakeetModelLoading.loadAsrModels(
                    from: directory,
                    version: manifest.version.asrVersion,
                    encoderComputeUnits: manifest.version == .redux ? .cpuOnly : nil,
                    modelComputeUnits: .cpuAndNeuralEngine
                )
                let manager = AsrManager(config: .default)
                try await manager.loadModels(models)
                guard let self, self.loadedFingerprint == fingerprint else { return }
                self.state = .ready(manager, manifest)
                self.onReady?()
                KeyboardSpeechModel.recordKeyboardState(.ready, modelID: manifest.modelID, fingerprint: fingerprint)
                KeyboardDiagnosticsLog.record("parakeet.ready", [
                    "model": manifest.modelID,
                    "loadSeconds": String(format: "%.1f", Self.seconds(since: startedAt)),
                    "footprintMB": String(Self.footprint() / 1_048_576)
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
        guard case .ready(let manager, _) = state else { throw CancellationError() }
        guard Self.availableMemory() >= KeyboardSpeechModel.requiredAvailableBytes / 2 else {
            KeyboardDiagnosticsLog.record("parakeet.skippedTranscribe", [
                "availableMB": String(Self.availableMemory() / 1_048_576)
            ])
            throw CancellationError()
        }
        let startedAt = ContinuousClock.now
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(samples, decoderState: &decoderState)
        KeyboardDiagnosticsLog.record("parakeet.transcribed", [
            "audioSeconds": String(format: "%.1f", Double(samples.count) / 16_000),
            "seconds": String(format: "%.2f", Self.seconds(since: startedAt)),
            "footprintMB": String(Self.footprint() / 1_048_576)
        ])
        return result.text
    }

    /// Frees the model, for example on a memory warning. The next appearance
    /// loads it again.
    func unload() {
        if case .loading(let task, _) = state { task.cancel() }
        if case .ready(let manager, _) = state {
            Task { await manager.cleanup() }
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

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }
}

private extension KeyboardSpeechModel.Version {
    var asrVersion: AsrModelVersion {
        switch self {
        case .tdtCtc110m: .tdtCtc110m
        case .v3: .v3
        case .redux: .redux
        }
    }
}
