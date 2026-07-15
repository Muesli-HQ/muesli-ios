import Foundation

enum MuesliAppConstants {
    static let appGroupIdentifier = "group.com.phequals7.muesli"
    static let urlScheme = "muesli"
    static let dictateHost = "dictate"
    static let syncHost = "sync"
    static let settingsHost = "settings"
    static let debugHost = "debug"
    static let resetOnboardingPath = "/reset-onboarding"
    static let resetOnboardingLaunchArgument = "--muesli-reset-onboarding"
    static let uiTestingLaunchArgument = "--muesli-ui-testing"
    static let longVoiceNoteUITestLaunchArgument = "--muesli-ui-testing-long-voice-note"
    static let completedLongVoiceNoteUITestLaunchArgument = "--muesli-ui-testing-completed-long-voice-note"
    static let missingActiveMeetingHistoryUITestLaunchArgument = "--muesli-ui-testing-missing-active-meeting-history"
    static let interruptedMeetingRecoveryUITestLaunchArgument = "--muesli-ui-testing-interrupted-meeting-recovery"
    static let processingMeetingUITestLaunchArgument = "--muesli-ui-testing-processing-meeting"
    static let liveMeetingTranscriptUITestLaunchArgument = "--muesli-ui-testing-live-meeting-transcript"
    static let processingMeetingSummaryUITestLaunchArgument = "--muesli-ui-testing-processing-meeting-summary"
    // NOTE: These UI-testing launch-argument string literals are mirrored in the
    // XCUITest target's `enum UITestArgs` (the test target does NOT link the app
    // module, so it cannot reference `MuesliAppConstants`). If you change a value
    // here, update the matching case in `UITestArgs` (and vice versa) so they stay
    // in sync.
    static let onboardingUITestLaunchArgument = "--muesli-ui-testing-onboarding"
    static let completedDictationUITestLaunchArgument = "--muesli-ui-testing-completed-dictation"
    static let dictionaryEntriesUITestLaunchArgument = "--muesli-ui-testing-dictionary-entries"
    static let requestQueryItem = "request"
    static let actionQueryItem = "action"
    static let sourceQueryItem = "source"
    static let startAction = "start"
    static let stopAction = "stop"
    static let cancelAction = "cancel"
}
