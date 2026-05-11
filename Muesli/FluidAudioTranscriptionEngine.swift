import Foundation
import FluidAudio

actor FluidAudioTranscriptionEngine: TranscriptionEngine {
    nonisolated let identifier = "fluidaudio-parakeet-v3"

    private var manager: AsrManager?

    func transcribe(audioURL: URL) async throws -> String {
        let manager = try await loadedManager()
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(audioURL, decoderState: &decoderState)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func loadedManager() async throws -> AsrManager {
        if let manager {
            return manager
        }

        let models = try await AsrModels.downloadAndLoad(version: .v3)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
        return manager
    }
}
