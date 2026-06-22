import Foundation

enum OnboardingUseCase: String, CaseIterable, Codable {
    case voiceNotes = "voice_notes"
    case dictation = "dictation"
    case keyboardDictation = "keyboard_dictation"
    case meetings = "meetings"
    case everything = "everything"

    var title: String {
        switch self {
        case .voiceNotes:
            "Voice Notes"
        case .dictation:
            "Transcribe & Copy"
        case .keyboardDictation:
            "Keyboard"
        case .meetings:
            "Meetings"
        case .everything:
            "Everything"
        }
    }

    var subtitle: String {
        switch self {
        case .voiceNotes:
            "Record inside Muesli"
        case .dictation:
            "Capture text quickly"
        case .keyboardDictation:
            "Use from text fields"
        case .meetings:
            "Notes and summaries"
        case .everything:
            "Voice notes + meetings"
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
        case .meetings:
            "person.2.wave.2"
        case .everything:
            "rectangle.3.group.fill"
        }
    }

    var needsKeyboardSetup: Bool {
        self == .keyboardDictation || self == .everything
    }

    var includesMeetingWorkflow: Bool {
        self == .meetings || self == .everything
    }

    var includesDictationTest: Bool {
        self != .meetings
    }
}
