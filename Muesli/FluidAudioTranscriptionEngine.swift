import Foundation
@preconcurrency import FluidAudio

// FluidAudio's offline diarizer internally guards its mutable CoreML state but
// does not currently declare Sendable conformance.
extension OfflineDiarizerManager: @retroactive @unchecked Sendable {}

actor FluidAudioTranscriptionEngine: TranscriptionEngine {
    nonisolated let identifier = "parakeet-v3"

    private var manager: AsrManager?
    private var diarizationRuntime: FluidAudioDiarizationRuntime?

    func prepare(progress: (@Sendable (Double, String?) -> Void)? = nil) async throws {
        _ = try await loadedManager(progress: progress)
    }

    func transcribe(audioURL: URL) async throws -> String {
        let result = try await transcribeDetailed(audioURL: audioURL)
        return result.text
    }

    func transcribeDetailed(audioURL: URL) async throws -> DetailedTranscriptionResult {
        let manager = try await loadedManager(progress: nil)
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(audioURL, decoderState: &decoderState)
        return DetailedTranscriptionResult(
            text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
            duration: result.duration,
            tokens: (result.tokenTimings ?? []).map {
                TimedTranscriptToken(
                    token: $0.token,
                    startTime: $0.startTime,
                    endTime: $0.endTime,
                    confidence: $0.confidence
                )
            }
        )
    }

    func diarize(audioURL: URL) async throws -> [SpeakerDiarizationSegment] {
        let runtime = loadedDiarizationRuntime()
        let result = try await runtime.process(audioURL: audioURL)
        return result.segments.map {
            SpeakerDiarizationSegment(
                speakerID: $0.speakerId,
                startTime: TimeInterval($0.startTimeSeconds),
                endTime: TimeInterval($0.endTimeSeconds),
                qualityScore: $0.qualityScore
            )
        }
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

    private func loadedDiarizationRuntime() -> FluidAudioDiarizationRuntime {
        if let diarizationRuntime {
            return diarizationRuntime
        }
        let runtime = FluidAudioDiarizationRuntime()
        diarizationRuntime = runtime
        return runtime
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

private actor FluidAudioDiarizationRuntime {
    nonisolated(unsafe) private var manager: OfflineDiarizerManager?

    func process(audioURL: URL) async throws -> DiarizationResult {
        let manager = try await loadedManager()
        return try await manager.process(audioURL)
    }

    private func loadedManager() async throws -> OfflineDiarizerManager {
        if let manager {
            return manager
        }
        let manager = OfflineDiarizerManager()
        try await manager.prepareModels()
        self.manager = manager
        return manager
    }
}

struct DetailedTranscriptionResult: Sendable, Equatable {
    let text: String
    let duration: TimeInterval
    let tokens: [TimedTranscriptToken]
}

struct TimedTranscriptToken: Codable, Sendable, Equatable {
    let token: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let confidence: Float
}

struct SpeakerDiarizationSegment: Codable, Sendable, Equatable {
    let speakerID: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let qualityScore: Float
}
