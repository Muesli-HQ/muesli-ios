import AVFoundation
import Foundation
import Speech

@available(iOS 26, *)
actor AppleSpeechRuntime {
    private var preparedLocale: Locale?
    enum Failure: LocalizedError {
        case unavailable, unsupportedLanguage, assetsMissing, emptyTranscript
        var errorDescription: String? {
            switch self {
            case .unavailable: "Apple Speech is unavailable on this iPhone. Choose another model."
            case .unsupportedLanguage: "Apple Speech does not support your iPhone’s language. Choose another model."
            case .assetsMissing: "Apple Speech language setup did not finish. Check your connection and retry."
            case .emptyTranscript: "No speech was found in this recording."
            }
        }
    }
    func prepare(progress: (@Sendable (Double, String?) -> Void)?) async throws {
        guard SpeechTranscriber.isAvailable else { throw Failure.unavailable }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else { throw Failure.unsupportedLanguage }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        progress?(0.05, "Preparing Apple Speech…")
        _ = try await AssetInventory.reserve(locale: locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            progress?(0.1, "Downloading Apple Speech language…")
            let downloadProgress = request.progress
            try await withTaskCancellationHandler {
                try await request.downloadAndInstall()
            } onCancel: { downloadProgress.cancel() }
        }
        try Task.checkCancellation()
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else { throw Failure.assetsMissing }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        do {
            try await analyzer.prepareToAnalyze(in: AVAudioFormat(commonFormat: .pcmFormatInt16,
                sampleRate: 16_000, channels: 1, interleaved: true)!)
            try Task.checkCancellation()
        } catch { await analyzer.cancelAndFinishNow(); throw error }
        await analyzer.cancelAndFinishNow()
        preparedLocale = locale
        AppleSpeechAssetState.shared.markPrepared()
        progress?(1, "Apple Speech ready")
    }
    func transcribe(_ url: URL, progress: (@Sendable (TranscriptionProgressUpdate) -> Void)? = nil) async throws -> DetailedTranscriptionResult {
        guard let locale = preparedLocale else { throw Failure.assetsMissing }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: url)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        let collector = Task { try await Self.collect(transcriber, duration: duration, progress: progress) }
        return try await withTaskCancellationHandler {
            do {
                if let end = try await analyzer.analyzeSequence(from: file) {
                    try await analyzer.finalizeAndFinish(through: end)
                } else { await analyzer.cancelAndFinishNow() }
                let result = try await collector.value
                try Task.checkCancellation()
                guard !result.text.isEmpty else { throw Failure.emptyTranscript }
                return result
            } catch {
                collector.cancel()
                await analyzer.cancelAndFinishNow()
                throw error
            }
        } onCancel: {
            collector.cancel()
            Task { await analyzer.cancelAndFinishNow() }
        }
    }
    nonisolated static func timedTokens(from text: AttributedString, fallbackRange: CMTimeRange) -> [TimedTranscriptToken] {
        text.runs.compactMap { run in
            let range = run.audioTimeRange ?? fallbackRange
            let start = CMTimeGetSeconds(range.start)
            let end = CMTimeGetSeconds(CMTimeRangeGetEnd(range))
            let token = String(text[run.range].characters)
            guard start.isFinite, end.isFinite, end >= start, !token.isEmpty else { return nil }
            return TimedTranscriptToken(token: token, startTime: max(0, start),
                                        endTime: max(0, end), confidence: 1)
        }
    }

    private static func collect(_ transcriber: SpeechTranscriber, duration: TimeInterval,
                                progress: (@Sendable (TranscriptionProgressUpdate) -> Void)?) async throws -> DetailedTranscriptionResult {
        var fragments: [String] = []
        var tokens: [TimedTranscriptToken] = []
        for try await result in transcriber.results {
            try Task.checkCancellation()
            let end = CMTimeGetSeconds(CMTimeRangeGetEnd(result.range))
            progress?(.init(fractionCompleted: duration > 0 && end.isFinite ? end / duration : nil, message: "Transcribing"))
            if result.isFinal {
                let text = String(result.text.characters)
                fragments.append(text)
                tokens.append(contentsOf: timedTokens(from: result.text, fallbackRange: result.range))
            }
        }
        return DetailedTranscriptionResult(text: fragments.joined().trimmingCharacters(in: .whitespacesAndNewlines),
                                           duration: duration, tokens: tokens)
    }
}
