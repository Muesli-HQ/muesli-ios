import Foundation

struct TranscriptionProgressUpdate: Sendable, Equatable {
    let fractionCompleted: Double?
    let message: String?
    let updatedAt: Date

    init(
        fractionCompleted: Double? = nil,
        message: String? = nil,
        updatedAt: Date = .now
    ) {
        self.fractionCompleted = fractionCompleted.map { min(max($0, 0), 1) }
        self.message = message
        self.updatedAt = updatedAt
    }
}

protocol TranscriptionEngine: Sendable {
    var identifier: String { get }
    func transcribe(
        audioURL: URL,
        progress: (@Sendable (TranscriptionProgressUpdate) -> Void)?
    ) async throws -> String
}

extension TranscriptionEngine {
    func transcribe(audioURL: URL) async throws -> String {
        try await transcribe(audioURL: audioURL, progress: nil)
    }
}

struct PlaceholderSpeechEngine: TranscriptionEngine {
    let identifier = "placeholder"

    func transcribe(
        audioURL: URL,
        progress: (@Sendable (TranscriptionProgressUpdate) -> Void)? = nil
    ) async throws -> String {
        _ = audioURL
        progress?(.init(fractionCompleted: 1, message: "Transcription ready"))
        return "Muesli iOS transcription engine is ready to be connected."
    }
}
