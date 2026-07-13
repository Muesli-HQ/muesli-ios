import Foundation

enum TranscriptionDisplayName {
    static func engineName(for identifier: String) -> String {
        switch identifier {
        case "fluidaudio-parakeet-v3", "parakeet-v3":
            "Parakeet v3"
        case "parakeet-tdt-ctc-110m":
            "Parakeet 110M"
        case "parakeet-realtime-eou-120m":
            "Parakeet Realtime"
        case "whisper-tiny-en":
            "Whisper Tiny"
        case "whisper-small-en":
            "Whisper Small"
        case "whisper-medium-en":
            "Whisper Medium"
        case "whisper-large-turbo":
            "Whisper Turbo"
        case "placeholder":
            "Placeholder"
        default:
            identifier
        }
    }
}
