import XCTest

/// Launch-argument string literals used by the XCUITest target.
///
/// MUST stay in sync with MuesliAppConstants in Shared/AppConstants.swift.
/// The UI test target does NOT link the app module, so it cannot import
/// `MuesliAppConstants`; these literals are duplicated here on purpose. If a
/// value changes in `MuesliAppConstants`, update the matching entry below.
enum UITestArgs {
    static let uiTesting = "--muesli-ui-testing"
    static let onboarding = "--muesli-ui-testing-onboarding"
    static let completedDictation = "--muesli-ui-testing-completed-dictation"
    static let dictionaryEntries = "--muesli-ui-testing-dictionary-entries"
    static let resetOnboarding = "--muesli-reset-onboarding"
    static let mockDictations = "--muesli-mock-dictations"
    static let previewWaveform = "--muesli-preview-waveform"

    static let longVoiceNote = "--muesli-ui-testing-long-voice-note"
    static let completedLongVoiceNote = "--muesli-ui-testing-completed-long-voice-note"
    static let missingActiveMeetingHistory = "--muesli-ui-testing-missing-active-meeting-history"
    static let interruptedMeetingRecovery = "--muesli-ui-testing-interrupted-meeting-recovery"
    static let processingMeeting = "--muesli-ui-testing-processing-meeting"
    static let liveMeetingTranscript = "--muesli-ui-testing-live-meeting-transcript"
    static let processingMeetingSummary = "--muesli-ui-testing-processing-meeting-summary"
}

/// Shared base class for all Muesli XCUITest flow classes.
///
/// Provides the common launch helpers, scroll utility, and microphone
/// permission handling that every flow relies on.
@MainActor
class MuesliUITestCase: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// Launches the app in UI-testing mode, appending any extra launch arguments.
    @discardableResult
    func launchApp(_ extraArgs: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [UITestArgs.uiTesting] + extraArgs
        app.launch()
        return app
    }

    /// Launches the app in UI-testing mode WITHOUT auto-completing onboarding,
    /// so the real OnboardingView steps are exercised.
    @discardableResult
    func launchOnboardingApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [UITestArgs.onboarding]
        app.launch()
        return app
    }

    /// Swipes up until `element` exists and is hittable, replacing the
    /// hand-rolled `for _ in 0..<N { app.swipeUp() }` loops. Returns whether the
    /// element became hittable within `maxSwipes` attempts.
    @discardableResult
    func scrollToElement(_ element: XCUIElement, in app: XCUIApplication, maxSwipes: Int = 6) -> Bool {
        if element.exists && element.isHittable {
            return true
        }
        for _ in 0..<maxSwipes {
            app.swipeUp()
            if element.exists && element.isHittable {
                return true
            }
        }
        return element.exists && element.isHittable
    }

    /// Registers a UI interruption monitor that grants the microphone permission
    /// alert when it appears. The caller must trigger a UI event (e.g.
    /// `app.tap()`) after the alert appears for the monitor to fire.
    func addMicPermissionMonitor(on app: XCUIApplication) {
        addUIInterruptionMonitor(withDescription: "Microphone") { alert in
            for label in ["Allow While Using App", "Allow", "OK"] {
                let button = alert.buttons[label]
                if button.exists {
                    button.tap()
                    return true
                }
            }
            return false
        }
    }

    /// Springboard fallback for granting the microphone permission alert when the
    /// interruption monitor does not fire. Safe to call unconditionally; it is a
    /// no-op if no springboard alert is present.
    @discardableResult
    func grantMicPermissionViaSpringboard(timeout: TimeInterval = 3) -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow While Using App", "Allow"] {
            let button = springboard.buttons[label]
            if button.waitForExistence(timeout: timeout) {
                button.tap()
                return true
            }
        }
        return false
    }
}
