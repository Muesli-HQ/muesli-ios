import AVFoundation
import Foundation
@preconcurrency import FluidAudio

// FluidAudio's offline diarizer internally guards its mutable CoreML state but
// does not currently declare Sendable conformance.
extension OfflineDiarizerManager: @retroactive @unchecked Sendable {}

// Muesli only passes AVAudioPCMBuffer instances across actor boundaries after
// they have been copied out of the realtime audio tap or created for local file
// reads. FluidAudio's streaming API is actor-isolated, so Swift needs this
// explicit assertion for those immutable handoff buffers.
extension AVAudioPCMBuffer: @retroactive @unchecked Sendable {}

actor FluidAudioTranscriptionEngine: TranscriptionEngine {
    nonisolated var identifier: String {
        MuesliPreferences.transcriptionModel.engineIdentifier
    }

    private var manager: AsrManager?
    private var streamingManager: StreamingEouAsrManager?
    private var isLoadingManager = false
    private var isLoadingStreamingManager = false
    private var selectedModel = MuesliPreferences.transcriptionModel
    private var diarizationRuntime: FluidAudioDiarizationRuntime?

    func selectModel(_ model: LocalTranscriptionModel) {
        guard selectedModel != model else { return }
        selectedModel = model
        manager = nil
        streamingManager = nil
        isLoadingManager = false
        isLoadingStreamingManager = false
    }

    func isLoaded(for model: LocalTranscriptionModel) -> Bool {
        guard selectedModel == model else { return false }
        if model.supportsRealtimeStreaming {
            return streamingManager != nil
        }
        return manager != nil
    }

    func prepare(progress: (@Sendable (Double, String?) -> Void)? = nil) async throws {
        if selectedModel.supportsRealtimeStreaming {
            _ = try await loadedStreamingManager(progress: progress)
        } else {
            _ = try await loadedManager(progress: progress)
        }
    }

    func transcribe(audioURL: URL) async throws -> String {
        let result = try await transcribeDetailed(audioURL: audioURL)
        return result.text
    }

    func transcribeDetailed(audioURL: URL) async throws -> DetailedTranscriptionResult {
        if selectedModel.supportsRealtimeStreaming {
            return try await transcribeWithStreamingManager(audioURL: audioURL)
        }

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

    func startRealtimeSession(
        partialTranscript: (@Sendable (String) -> Void)? = nil,
        endOfUtterance: (@Sendable (String) -> Void)? = nil,
        progress: (@Sendable (Double, String?) -> Void)? = nil
    ) async throws {
        let manager = try await loadedStreamingManager(progress: progress)
        await manager.reset()
        if let partialTranscript {
            await manager.setPartialCallback(partialTranscript)
        }
        if let endOfUtterance {
            await manager.setEouCallback(endOfUtterance)
        }
    }

    func processRealtimeAudioBuffer(_ buffer: AVAudioPCMBuffer) async throws {
        guard selectedModel.supportsRealtimeStreaming else { return }
        let manager = try await loadedStreamingManager(progress: nil)
        _ = try await manager.process(audioBuffer: buffer)
    }

    func finishRealtimeSession() async throws -> String {
        guard selectedModel.supportsRealtimeStreaming else {
            throw TranscriptionEngineError.unsupportedStreamingModel(selectedModel.shortName)
        }
        let manager = try await loadedStreamingManager(progress: nil)
        return try await manager.finish().trimmingCharacters(in: .whitespacesAndNewlines)
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

        while isLoadingManager {
            try await Task.sleep(for: .milliseconds(150))
            if let manager {
                return manager
            }
        }

        isLoadingManager = true
        defer {
            isLoadingManager = false
        }

        let model = selectedModel
        guard let asrVersion = model.asrVersion else {
            throw TranscriptionEngineError.unsupportedOfflineModel(model.shortName)
        }
        let models = try await AsrModels.downloadAndLoad(version: asrVersion) { downloadProgress in
            let fraction = min(max(downloadProgress.fractionCompleted, 0), 1)
            progress?(fraction, Self.statusText(for: downloadProgress.phase, fraction: fraction))
        }
        progress?(1.0, "Preparing model for this iPhone...")
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
        progress?(1.0, "\(model.shortName) ready")
        return manager
    }

    private func loadedStreamingManager(
        progress: (@Sendable (Double, String?) -> Void)?
    ) async throws -> StreamingEouAsrManager {
        if let streamingManager {
            return streamingManager
        }

        while isLoadingStreamingManager {
            try await Task.sleep(for: .milliseconds(150))
            if let streamingManager {
                return streamingManager
            }
        }

        isLoadingStreamingManager = true
        defer {
            isLoadingStreamingManager = false
        }

        let model = selectedModel
        guard let variant = model.streamingVariant, let chunkSize = variant.eouChunkSize else {
            throw TranscriptionEngineError.unsupportedStreamingModel(model.shortName)
        }

        let manager = StreamingEouAsrManager(chunkSize: chunkSize)
        try await manager.loadModels(to: nil, configuration: nil) { downloadProgress in
            let fraction = min(max(downloadProgress.fractionCompleted, 0), 1)
            progress?(fraction, Self.statusText(for: downloadProgress.phase, fraction: fraction))
        }
        self.streamingManager = manager
        progress?(1.0, "\(model.shortName) ready")
        return manager
    }

    private func transcribeWithStreamingManager(audioURL: URL) async throws -> DetailedTranscriptionResult {
        let manager = try await loadedStreamingManager(progress: nil)
        await manager.reset()

        let audioFile = try AVAudioFile(forReading: audioURL)
        let duration = audioFile.fileFormat.sampleRate > 0
            ? Double(audioFile.length) / audioFile.fileFormat.sampleRate
            : 0
        let framesPerRead: AVAudioFrameCount = 16_000

        while audioFile.framePosition < audioFile.length {
            let remaining = audioFile.length - audioFile.framePosition
            let framesToRead = AVAudioFrameCount(min(Int64(framesPerRead), remaining))
            guard framesToRead > 0,
                  let buffer = AVAudioPCMBuffer(
                    pcmFormat: audioFile.processingFormat,
                    frameCapacity: framesToRead
                  )
            else {
                break
            }
            try audioFile.read(into: buffer, frameCount: framesToRead)
            guard buffer.frameLength > 0 else { break }
            _ = try await manager.process(audioBuffer: buffer)
            try Task.checkCancellation()
        }

        let text = try await manager.finish()
        return DetailedTranscriptionResult(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            duration: duration,
            tokens: []
        )
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

private enum TranscriptionEngineError: LocalizedError {
    case unsupportedOfflineModel(String)
    case unsupportedStreamingModel(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedOfflineModel(let modelName):
            "\(modelName) does not support offline transcription."
        case .unsupportedStreamingModel(let modelName):
            "\(modelName) does not support realtime streaming."
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
