import Foundation

enum TranscriptionDisplayName {
    static func engineName(for identifier: String) -> String {
        switch identifier {
        case "fluidaudio-parakeet-v3", "parakeet-v3":
            "Parakeet v3"
        case "parakeet-tdt-ctc-110m":
            "Parakeet 110M"
        case "placeholder":
            "Placeholder"
        default:
            identifier
        }
    }
}
