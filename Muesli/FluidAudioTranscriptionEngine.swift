import Foundation
import FluidAudio

actor FluidAudioTranscriptionEngine: TranscriptionEngine {
    nonisolated let identifier = "parakeet-v3"

    private var manager: AsrManager?

    func prepare(progress: (@Sendable (Double, String?) -> Void)? = nil) async throws {
        _ = try await loadedManager(progress: progress)
    }

    func transcribe(audioURL: URL) async throws -> String {
        let manager = try await loadedManager(progress: nil)
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(audioURL, decoderState: &decoderState)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func loadedManager(progress: (@Sendable (Double, String?) -> Void)?) async throws -> AsrManager {
        if let manager {
            return manager
        }

        let models = try await AsrModels.downloadAndLoad(version: .v3) { downloadProgress in
            let fraction = min(max(downloadProgress.fractionCompleted, 0), 1)
            progress?(fraction, Self.statusText(for: downloadProgress.phase, fraction: fraction))
        }
        progress?(1.0, "Preparing model for this iPhone...")
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
        progress?(1.0, "Parakeet v3 ready")
        return manager
    }

    private nonisolated static func statusText(
        for phase: DownloadUtils.DownloadPhase,
        fraction: Double
    ) -> String {
        switch phase {
        case .listing:
            return "Checking model files..."
        case .downloading(let completedFiles, let totalFiles):
            let percent = Int((fraction * 100).rounded())
            if totalFiles > 0 {
                return "Downloading \(completedFiles) of \(totalFiles) files • \(percent)%"
            }
            return "Downloading model • \(percent)%"
        case .compiling:
            return "Compiling CoreML model..."
        }
    }
}
