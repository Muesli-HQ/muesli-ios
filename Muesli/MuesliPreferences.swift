import Foundation

enum MuesliPreferences {
    static let liveActivitiesForDictationsKey = "muesli.liveActivities.dictations"
    static let liveActivitiesForMeetingsKey = "muesli.liveActivities.meetings"

    static var liveActivitiesForDictationsEnabled: Bool {
        bool(for: liveActivitiesForDictationsKey, defaultValue: true)
    }

    static var liveActivitiesForMeetingsEnabled: Bool {
        bool(for: liveActivitiesForMeetingsKey, defaultValue: true)
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
