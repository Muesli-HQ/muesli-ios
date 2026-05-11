import Foundation

enum OnboardingUseCase: String, CaseIterable, Codable {
    case voiceNotes = "voice_notes"
    case dictation = "dictation"
    case keyboardDictation = "keyboard_dictation"

    var title: String {
        switch self {
        case .voiceNotes:
            "Voice Notes"
        case .dictation:
            "Dictation"
        case .keyboardDictation:
            "Keyboard"
        }
    }

    var subtitle: String {
        switch self {
        case .voiceNotes:
            "Record inside Muesli"
        case .dictation:
            "Transcribe and copy"
        case .keyboardDictation:
            "Use from text fields"
        }
    }

    var icon: String {
        switch self {
        case .voiceNotes:
            "waveform"
        case .dictation:
            "mic.fill"
        case .keyboardDictation:
            "keyboard.fill"
        }
    }

    var needsKeyboardSetup: Bool {
        self == .keyboardDictation
    }
}
