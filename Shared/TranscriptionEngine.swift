import Foundation

protocol TranscriptionEngine: Sendable {
    var identifier: String { get }
    func transcribe(audioURL: URL) async throws -> String
}

struct PlaceholderSpeechEngine: TranscriptionEngine {
    let identifier = "placeholder"

    func transcribe(audioURL: URL) async throws -> String {
        _ = audioURL
        return "Muesli iOS transcription engine is ready to be connected."
    }
}

