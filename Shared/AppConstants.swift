import Foundation

enum MuesliAppConstants {
    static let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.phequals7.muesli.ios"
    static let appGroupIdentifier = configuredValue(
        forInfoDictionaryKey: "MuesliAppGroupIdentifier",
        fallback: "group.com.phequals7.muesli"
    )
    static let crossProcessPrefix = configuredValue(
        forInfoDictionaryKey: "MuesliCrossProcessPrefix",
        fallback: "com.phequals7.muesli"
    )
    static let urlScheme = configuredValue(
        forInfoDictionaryKey: "MuesliURLScheme",
        fallback: "muesli"
    )
    static let dictateHost = "dictate"
    static let syncHost = "sync"
    static let settingsHost = "settings"
    static let debugHost = "debug"
    static let resetOnboardingPath = "/reset-onboarding"
    static let resetOnboardingLaunchArgument = "--muesli-reset-onboarding"
    static let uiTestingLaunchArgument = "--muesli-ui-testing"
    static let activeQuickNoteUITestLaunchArgument = "--muesli-ui-testing-active-quick-note"
    static let longVoiceNoteUITestLaunchArgument = "--muesli-ui-testing-long-voice-note"
    static let completedLongVoiceNoteUITestLaunchArgument = "--muesli-ui-testing-completed-long-voice-note"
    static let emptyNotepadUITestLaunchArgument = "--muesli-ui-testing-empty-notepad"
    static let directStartNotepadUITestLaunchArgument = "--muesli-ui-testing-direct-start-notepad"
    static let missingActiveMeetingHistoryUITestLaunchArgument = "--muesli-ui-testing-missing-active-meeting-history"
    static let interruptedMeetingRecoveryUITestLaunchArgument = "--muesli-ui-testing-interrupted-meeting-recovery"
    static let processingMeetingUITestLaunchArgument = "--muesli-ui-testing-processing-meeting"
    static let liveMeetingTranscriptUITestLaunchArgument = "--muesli-ui-testing-live-meeting-transcript"
    static let processingMeetingSummaryUITestLaunchArgument = "--muesli-ui-testing-processing-meeting-summary"
    static let requestQueryItem = "request"
    static let actionQueryItem = "action"
    static let sourceQueryItem = "source"
    static let startAction = "start"
    static let stopAction = "stop"
    static let cancelAction = "cancel"

    private static func configuredValue(forInfoDictionaryKey key: String, fallback: String) -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return fallback
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else {
            return fallback
        }
        return trimmed
    }
}
