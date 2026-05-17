import Foundation

enum MuesliPreferences {
    static let liveActivitiesForDictationsKey = "muesli.liveActivities.dictations"
    static let liveActivitiesForMeetingsKey = "muesli.liveActivities.meetings"
    static let keyboardSessionModeKey = "muesli.keyboardSession.enabled"
    static let keyboardSessionTimeoutMinutesKey = "muesli.keyboardSession.timeoutMinutes"
    static let fillerWordRemovalKey = "muesli.transcription.fillerWordRemoval"
    static let customDictionaryKey = "muesli.transcription.customDictionary"

    static var liveActivitiesForDictationsEnabled: Bool {
        bool(for: liveActivitiesForDictationsKey, defaultValue: true)
    }

    static var liveActivitiesForMeetingsEnabled: Bool {
        bool(for: liveActivitiesForMeetingsKey, defaultValue: true)
    }

    static var keyboardSessionModeEnabled: Bool {
        bool(for: keyboardSessionModeKey, defaultValue: false)
    }

    static var keyboardSessionTimeoutMinutes: Int {
        let value = UserDefaults.standard.integer(forKey: keyboardSessionTimeoutMinutesKey)
        return value == 0 ? 10 : min(max(value, 1), 30)
    }

    static var fillerWordRemovalEnabled: Bool {
        bool(for: fillerWordRemovalKey, defaultValue: true)
    }

    static var customDictionaryEnabled: Bool {
        bool(for: customDictionaryKey, defaultValue: true)
    }

    static func liveActivitiesEnabled(for kind: RecordingSessionKind) -> Bool {
        switch kind {
        case .quickDictation, .keyboardDictation:
            liveActivitiesForDictationsEnabled
        case .meeting:
            liveActivitiesForMeetingsEnabled
        }
    }

    private static func bool(for key: String, defaultValue: Bool) -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }
}
