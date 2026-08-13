import AVFoundation
import CoreML
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
    private var whisperRuntime: WhisperKitTranscriptionRuntime?
    private var loadedWhisperModel: LocalTranscriptionModel?
    private var isLoadingManager = false
    private var isLoadingStreamingManager = false
    private var isLoadingWhisperRuntime = false
    private var selectedModel = MuesliPreferences.transcriptionModel
    private var diarizationRuntime: FluidAudioDiarizationRuntime?

    func selectModel(_ model: LocalTranscriptionModel) async {
        guard selectedModel != model else { return }
        let runtimeToUnload = whisperRuntime
        selectedModel = model
        manager = nil
        streamingManager = nil
        whisperRuntime = nil
        loadedWhisperModel = nil
        isLoadingManager = false
        isLoadingStreamingManager = false
        isLoadingWhisperRuntime = false
        await runtimeToUnload?.unload()
    }

    func isLoaded(for model: LocalTranscriptionModel) -> Bool {
        guard selectedModel == model else { return false }
        if model.family == .whisper {
            return loadedWhisperModel == model && whisperRuntime != nil
        }
        if model.supportsRealtimeStreaming {
            return streamingManager != nil
        }
        return manager != nil
    }

    func unloadModel(_ model: LocalTranscriptionModel) async {
        guard selectedModel == model else { return }
        if let whisperRuntime {
            await whisperRuntime.unload()
        }
        manager = nil
        streamingManager = nil
        whisperRuntime = nil
        loadedWhisperModel = nil
        isLoadingManager = false
        isLoadingStreamingManager = false
        isLoadingWhisperRuntime = false
    }

    func prepare(progress: (@Sendable (Double, String?) -> Void)? = nil) async throws {
        if selectedModel.family == .whisper {
            _ = try await loadedWhisperRuntime(progress: progress)
        } else if selectedModel.supportsRealtimeStreaming {
            _ = try await loadedStreamingManager(progress: progress)
        } else {
            _ = try await loadedManager(progress: progress)
        }
    }

    func transcribe(
        audioURL: URL,
        progress: (@Sendable (TranscriptionProgressUpdate) -> Void)? = nil
    ) async throws -> String {
        let result = try await transcribeDetailed(audioURL: audioURL, progress: progress)
        return result.text
    }

    func transcribeDetailed(
        audioURL: URL,
        progress: (@Sendable (TranscriptionProgressUpdate) -> Void)? = nil
    ) async throws -> DetailedTranscriptionResult {
        if selectedModel.family == .whisper {
            return try await transcribeWithWhisperKit(audioURL: audioURL, progress: progress)
        }
        if selectedModel.supportsRealtimeStreaming {
            return try await transcribeWithStreamingManager(audioURL: audioURL, progress: progress)
        }

        let manager = try await loadedManager { fraction, status in
            progress?(.init(fractionCompleted: fraction, message: status))
        }
        progress?(.init(fractionCompleted: 0, message: "Transcribing"))
        let progressTask: Task<Void, Never>? = Self.shouldObserveOfflineProgress(for: audioURL)
            ? Task {
                let stream = await manager.transcriptionProgressStream
                do {
                    for try await fraction in stream {
                        try Task.checkCancellation()
                        progress?(.init(fractionCompleted: fraction, message: "Transcribing"))
                    }
                } catch is CancellationError {
                    return
                } catch {
                    return
                }
            }
            : nil
        defer {
            progressTask?.cancel()
        }

        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(audioURL, decoderState: &decoderState)
        progress?(.init(fractionCompleted: 1, message: "Transcription complete"))
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
        let modelDirectory = try localModelDirectory(for: model)
        progress?(0.88, "Loading downloaded model...")
        let models = try await Self.loadLocalAsrModels(from: modelDirectory, version: asrVersion)
        progress?(1.0, "Preparing model for this iPhone...")
        let manager = AsrManager(config: .default)
        let loadHeartbeat = Self.modelLoadHeartbeatTask(
            progress: progress,
            message: "Preparing model for this iPhone..."
        )
        defer {
            loadHeartbeat?.cancel()
        }
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
        let modelDirectory = try localModelDirectory(for: model)

        let manager = StreamingEouAsrManager(chunkSize: chunkSize)
        progress?(0.9, "Loading downloaded model...")
        try await manager.loadModels(from: modelDirectory)
        self.streamingManager = manager
        progress?(1.0, "\(model.shortName) ready")
        return manager
    }

    private func loadedWhisperRuntime(
        progress: (@Sendable (Double, String?) -> Void)?
    ) async throws -> WhisperKitTranscriptionRuntime {
        if let whisperRuntime, loadedWhisperModel == selectedModel {
            return whisperRuntime
        }

        while isLoadingWhisperRuntime {
            try await Task.sleep(for: .milliseconds(150))
            if let whisperRuntime, loadedWhisperModel == selectedModel {
                return whisperRuntime
            }
        }

        let model = selectedModel
        guard let variant = model.whisperVariant else {
            throw TranscriptionEngineError.unsupportedOfflineModel(model.shortName)
        }
        _ = try localModelDirectory(for: model)

        isLoadingWhisperRuntime = true
        defer {
            isLoadingWhisperRuntime = false
        }

        let runtime = WhisperKitTranscriptionRuntime()
        do {
            try await runtime.load(variant: variant, progress: progress)
            try Task.checkCancellation()
            guard selectedModel == model else { throw CancellationError() }
            whisperRuntime = runtime
            loadedWhisperModel = model
            return runtime
        } catch {
            await runtime.unload()
            throw error
        }
    }

    private func localModelDirectory(for model: LocalTranscriptionModel) throws -> URL {
        guard ModelBackgroundDownloadService.isModelDownloaded(model),
              let directory = ModelBackgroundDownloadService.storageDirectory(for: model)
        else {
            throw TranscriptionEngineError.modelNotDownloaded(model.shortName)
        }
        return directory
    }

    private static func loadLocalAsrModels(
        from directory: URL,
        version: AsrModelVersion
    ) async throws -> AsrModels {
        let preprocessorFile: String
        let encoderFile: String?
        let decoderFile: String
        let jointFile: String
        switch version {
        case .tdtCtc110m:
            preprocessorFile = ModelNames.ASR.preprocessorFile
            encoderFile = nil
            decoderFile = ModelNames.ASR.decoderFile
            jointFile = ModelNames.ASR.jointFile
        case .v3:
            preprocessorFile = ModelNames.ASR.preprocessorFile
            encoderFile = ModelNames.ASR.encoderFile
            decoderFile = ModelNames.ASR.decoderFile
            jointFile = ModelNames.ASR.jointV3File
        default:
            throw TranscriptionEngineError.unsupportedOfflineModel("Parakeet")
        }

        let defaultConfiguration = AsrModels.defaultConfiguration()
        let preprocessorConfiguration = MLModelConfiguration()
        preprocessorConfiguration.computeUnits = .cpuOnly

        let preprocessor = try await MLModel.load(
            contentsOf: directory.appendingPathComponent(preprocessorFile),
            configuration: preprocessorConfiguration
        )
        let encoder: MLModel?
        if let encoderFile {
            encoder = try await MLModel.load(
                contentsOf: directory.appendingPathComponent(encoderFile),
                configuration: defaultConfiguration
            )
        } else {
            encoder = nil
        }
        let decoder = try await MLModel.load(
            contentsOf: directory.appendingPathComponent(decoderFile),
            configuration: defaultConfiguration
        )
        let joint = try await MLModel.load(
            contentsOf: directory.appendingPathComponent(jointFile),
            configuration: defaultConfiguration
        )
        let vocabularyData = try Data(
            contentsOf: directory.appendingPathComponent(ModelNames.ASR.vocabularyFile)
        )

        return AsrModels(
            encoder: encoder,
            preprocessor: preprocessor,
            decoder: decoder,
            joint: joint,
            configuration: defaultConfiguration,
            vocabulary: try decodeParakeetVocabulary(vocabularyData),
            version: version
        )
    }

    static func decodeParakeetVocabulary(_ data: Data) throws -> [Int: String] {
        let object = try JSONSerialization.jsonObject(with: data)
        if let array = object as? [String] {
            return Dictionary(uniqueKeysWithValues: array.enumerated().map { ($0.offset, $0.element) })
        }
        if let dictionary = object as? [String: String] {
            return dictionary.reduce(into: [:]) { vocabulary, entry in
                if let tokenID = Int(entry.key) {
                    vocabulary[tokenID] = entry.value
                }
            }
        }
        throw TranscriptionEngineError.invalidLocalVocabulary
    }

    private func transcribeWithWhisperKit(
        audioURL: URL,
        progress: (@Sendable (TranscriptionProgressUpdate) -> Void)?
    ) async throws -> DetailedTranscriptionResult {
        let runtime = try await loadedWhisperRuntime { fraction, message in
            progress?(.init(fractionCompleted: fraction, message: message))
        }
        progress?(.init(fractionCompleted: 0, message: "Transcribing with WhisperKit"))
        let text = try await runtime.transcribe(audioURL: audioURL)
        let duration: TimeInterval
        if let audioFile = try? AVAudioFile(forReading: audioURL),
           audioFile.fileFormat.sampleRate > 0 {
            duration = Double(audioFile.length) / audioFile.fileFormat.sampleRate
        } else {
            duration = 0
        }
        progress?(.init(fractionCompleted: 1, message: "Transcription complete"))
        return DetailedTranscriptionResult(text: text, duration: duration, tokens: [])
    }

    private func transcribeWithStreamingManager(
        audioURL: URL,
        progress: (@Sendable (TranscriptionProgressUpdate) -> Void)? = nil
    ) async throws -> DetailedTranscriptionResult {
        let manager = try await loadedStreamingManager { fraction, status in
            progress?(.init(fractionCompleted: fraction, message: status))
        }
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
            let fraction = audioFile.length > 0
                ? Double(audioFile.framePosition) / Double(audioFile.length)
                : nil
            progress?(.init(fractionCompleted: fraction, message: "Processing audio"))
            try Task.checkCancellation()
        }

        let text = try await manager.finish()
        progress?(.init(fractionCompleted: 1, message: "Transcription complete"))
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

    private nonisolated static func modelLoadHeartbeatTask(
        progress: (@Sendable (Double, String?) -> Void)?,
        message: String
    ) -> Task<Void, Never>? {
        guard let progress else { return nil }
        return Task.detached(priority: .utility) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                progress(1, message)
            }
        }
    }

    private nonisolated static func shouldObserveOfflineProgress(for audioURL: URL) -> Bool {
        guard let audioFile = try? AVAudioFile(forReading: audioURL),
              audioFile.fileFormat.sampleRate > 0 else {
            return true
        }
        return Double(audioFile.length) / audioFile.fileFormat.sampleRate > 15
    }
}

private enum TranscriptionEngineError: LocalizedError {
    case invalidLocalVocabulary
    case modelNotDownloaded(String)
    case unsupportedOfflineModel(String)
    case unsupportedStreamingModel(String)

    var errorDescription: String? {
        switch self {
        case .invalidLocalVocabulary:
            "The downloaded transcription vocabulary is invalid. Download the model again."
        case .modelNotDownloaded(let modelName):
            "\(modelName) is still downloading. Open Models to check its progress."
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
