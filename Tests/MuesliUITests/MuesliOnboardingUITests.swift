import XCTest

/// Onboarding flow XCUITests (Task A3).
///
/// These drive the REAL `OnboardingView` steps (not a completed-onboarding
/// fixture) via `launchOnboardingApp()`, which launches with both
/// `UITestArgs.uiTesting` and `UITestArgs.onboarding` so the coordinator's
/// UI-testing setup runs but leaves onboarding INCOMPLETE (model seeded "ready",
/// use-case seeded).
///
/// Step flow (see `OnboardingStep.orderedSteps(for:)` in OnboardingView.swift):
///   - `.voiceNotes` ("voice_notes"): profile → permissions → sync → model → **test**
///     (includes the "Test Voice Note" step; NO summary; no keyboard setup).
///   - `.meetings` ("meetings"): profile → permissions → sync → model → **summary**
///     (SKIPS the "Test Voice Note" step; adds the "Meeting Summaries" step).
/// That real difference is what `testOnboardingUseCaseSelectionChangesStepFlow`
/// asserts on.
///
/// Permission handling: onboarding's `canContinue` gates the permissions step on
/// `microphoneGranted` (mic == `.authorized`). The finish path therefore needs a
/// granted mic, which the CodeBuild buildspec pre-grants before the pre-granted
/// run. The deny test runs FIRST in a separate pre-grant-free `xcodebuild test`
/// invocation and is guarded with `XCTSkipIf` so it is deterministic everywhere.
@MainActor
final class MuesliOnboardingUITests: MuesliUITestCase {

    // MARK: - Test 1: use-case selection changes the step flow (deterministic)

    /// Selecting `.voiceNotes` vs `.meetings` produces a different ordered step
    /// list: `.voiceNotes` reaches a "Test Voice Note" step and never a
    /// "Meeting Summaries" step, while `.meetings` reaches "Meeting Summaries" and
    /// never "Test Voice Note". Pure UI navigation assertions.
    ///
    /// Walking past the permissions step needs a granted mic; on the CodeBuild
    /// fleet the mic is pre-granted, so no permission interaction happens here.
    /// `grantMicIfNeeded` is best-effort and a no-op when the mic already reads
    /// "Granted".
    func testOnboardingUseCaseSelectionChangesStepFlow() {
        // Voice Notes flow: reaches "Test Voice Note", never "Meeting Summaries".
        let voiceApp = launchOnboardingApp()
        selectUseCaseAndAdvanceToPermissions(voiceApp, rawValue: "voice_notes")
        grantMicIfNeeded(voiceApp)
        XCTAssertTrue(
            walkToStepTitle(voiceApp, "Test Voice Note"),
            "Voice Notes onboarding should include the Test Voice Note step"
        )
        XCTAssertFalse(
            voiceApp.staticTexts["Meeting Summaries"].exists,
            "Voice Notes onboarding should not include the Meeting Summaries step"
        )
        voiceApp.terminate()

        // Meetings flow: reaches "Meeting Summaries", never "Test Voice Note".
        let meetingApp = launchOnboardingApp()
        selectUseCaseAndAdvanceToPermissions(meetingApp, rawValue: "meetings")
        grantMicIfNeeded(meetingApp)
        XCTAssertTrue(
            walkToStepTitle(meetingApp, "Meeting Summaries"),
            "Meetings onboarding should include the Meeting Summaries step"
        )
        XCTAssertFalse(
            meetingApp.staticTexts["Test Voice Note"].exists,
            "Meetings onboarding should skip the Test Voice Note step"
        )
    }

    // MARK: - Test 2: stepping through reaches Finish (requires granted mic)

    /// Full happy-path: type a name, pick a use case that needs only the mic
    /// (`.voiceNotes` does NOT require keyboard setup, so `canContinue` at the
    /// permissions step depends solely on `microphoneGranted`), grant the mic, and
    /// advance through sync ("Skip for Now") and model ("Continue"/"Continue in
    /// Background") to the last step ("Skip Test"/"Finish"), then assert the main
    /// shell appears.
    ///
    /// This is NOT deny-tolerant: it needs the mic granted (CodeBuild pre-grant).
    func testOnboardingSteppingReachesFinish() {
        let app = launchOnboardingApp()

        // Select the use case FIRST (no keyboard on screen), so nothing that lives
        // under the keyboard needs tapping after we start typing. `.voiceNotes` has
        // no keyboard-setup gating, so `canContinue` at the permissions step
        // depends solely on the mic.
        let voiceCard = app.buttons["onboarding.useCaseCard.voice_notes"]
        XCTAssertTrue(voiceCard.waitForExistence(timeout: 8))
        voiceCard.tap()

        // Then type into the name field. The footer primary button sits outside the
        // scroll view and stays above the keyboard via SwiftUI keyboard avoidance.
        let nameField = app.textFields["onboarding.nameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText("Casey")

        let primary = app.buttons["onboarding.primaryButton"]
        XCTAssertTrue(primary.waitForExistence(timeout: 5))
        XCTAssertTrue(primary.isEnabled, "profile step should be continuable with a name")
        primary.tap() // profile → permissions

        XCTAssertTrue(app.staticTexts["Permissions"].waitForExistence(timeout: 5))
        XCTAssertTrue(grantMicIfNeeded(app), "microphone should be granted (CodeBuild pre-grant)")

        // Advance through the remaining steps until the main shell appears. Each
        // remaining step (sync/model/test) is continuable once mic is granted.
        let dictationsTab = app.buttons["tab.dictations"]
        for _ in 0..<6 {
            if dictationsTab.waitForExistence(timeout: 2) { break }
            if primary.exists && primary.isEnabled && primary.isHittable {
                primary.tap()
            }
        }

        XCTAssertTrue(
            dictationsTab.waitForExistence(timeout: 8),
            "completing onboarding should land on the main shell (tab.dictations)"
        )
    }

    // MARK: - Test 3: permission deny keeps the permissions step blocked

    /// Deny branch. The CodeBuild buildspec runs THIS test FIRST in a separate,
    /// pre-grant-free `xcodebuild test` invocation (via
    /// `-only-testing:MuesliUITests/MuesliOnboardingUITests/testOnboardingPermissionDenyStaysBlocked`),
    /// then resets + pre-grants the mic and runs the rest of the suite with a
    /// matching `-skip-testing:` for this method. `XCTSkipIf` makes it safe even
    /// if the mic is already authorized (e.g. a re-used pre-granted simulator or
    /// the pre-granted run), so the test is deterministic everywhere.
    ///
    /// Authorization is detected from the UI: the mic permission button's label
    /// reflects `AVCaptureDevice.authorizationStatus` — "Granted" (authorized,
    /// button disabled), "Grant" (undetermined), or "Open Settings" (denied).
    func testOnboardingPermissionDenyStaysBlocked() throws {
        let app = launchOnboardingApp()
        selectUseCaseAndAdvanceToPermissions(app, rawValue: "voice_notes")

        let micButton = app.buttons["onboarding.micPermissionButton"]
        XCTAssertTrue(micButton.waitForExistence(timeout: 5))

        // Skip when the mic is already authorized: the deny path cannot be
        // exercised there (and tapping would be a no-op disabled button).
        try XCTSkipIf(micButton.label == "Granted", "microphone already authorized; deny path not applicable")

        // If the mic is already denied ("Open Settings"), it is effectively blocked
        // already — do NOT tap, since tapping would call `openAppSettings()` and
        // navigate out of the app. Otherwise ("Grant"/undetermined) tap and deny
        // the springboard alert.
        if micButton.label != "Open Settings" {
            micButton.tap()
            denyMicPermissionViaSpringboard()
        }

        let primary = app.buttons["onboarding.primaryButton"]
        XCTAssertTrue(primary.waitForExistence(timeout: 5))

        // With the mic denied/undetermined, `canContinue` for the permissions step
        // is false, so the primary button stays disabled and the step stays put.
        let disabledPredicate = NSPredicate(format: "isEnabled == false")
        let disabledExpectation = XCTNSPredicateExpectation(predicate: disabledPredicate, object: primary)
        XCTAssertEqual(
            XCTWaiter().wait(for: [disabledExpectation], timeout: 6),
            .completed,
            "permissions step should stay blocked (primary button disabled) after deny"
        )

        // We are still on the permissions step and never reached the main shell.
        XCTAssertTrue(app.staticTexts["Permissions"].exists, "should remain on the permissions step")
        XCTAssertFalse(
            app.buttons["tab.dictations"].exists,
            "onboarding must not reach the main shell when the mic is denied"
        )
    }

    // MARK: - Helpers

    /// Selects the use-case card with `rawValue` on the profile step (the name is
    /// pre-seeded by the UI-testing setup, so the profile step is continuable) and
    /// advances to the permissions step. Selecting a card also resigns the
    /// keyboard so the footer primary button is reachable.
    private func selectUseCaseAndAdvanceToPermissions(_ app: XCUIApplication, rawValue: String) {
        let card = app.buttons["onboarding.useCaseCard.\(rawValue)"]
        XCTAssertTrue(card.waitForExistence(timeout: 8), "use-case card \(rawValue) should exist")
        card.tap()

        let primary = app.buttons["onboarding.primaryButton"]
        XCTAssertTrue(primary.waitForExistence(timeout: 5))
        XCTAssertTrue(primary.isEnabled, "profile step should be continuable (name pre-seeded)")
        primary.tap()

        XCTAssertTrue(app.staticTexts["Permissions"].waitForExistence(timeout: 5))
    }

    /// Grants the microphone permission at the permissions step if it is not
    /// already granted. Best-effort: returns true once the mic button reads
    /// "Granted". A no-op when the mic is already granted (e.g. CodeBuild
    /// pre-grant), where no alert appears.
    @discardableResult
    private func grantMicIfNeeded(_ app: XCUIApplication) -> Bool {
        let micButton = app.buttons["onboarding.micPermissionButton"]
        guard micButton.waitForExistence(timeout: 5) else { return false }
        if micButton.label == "Granted" { return true }

        addMicPermissionMonitor(on: app)
        micButton.tap()
        // Tolerate the springboard alert appearing or not: try the direct
        // springboard allow first, then poke the app so the interruption monitor
        // can fire.
        grantMicPermissionViaSpringboard()
        app.staticTexts["Permissions"].tap()

        // Wait for the primary button to become enabled (canContinue == true once
        // the mic is authorized).
        let primary = app.buttons["onboarding.primaryButton"]
        let enabledPredicate = NSPredicate(format: "isEnabled == true")
        let enabledExpectation = XCTNSPredicateExpectation(predicate: enabledPredicate, object: primary)
        _ = XCTWaiter().wait(for: [enabledExpectation], timeout: 8)
        return micButton.label == "Granted" || primary.isEnabled
    }

    /// Taps the springboard "Don't Allow"/"Deny" button for the microphone alert.
    /// Safe no-op if no springboard alert is present (tolerates the alert
    /// appearing or not).
    @discardableResult
    private func denyMicPermissionViaSpringboard(timeout: TimeInterval = 4) -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Don't Allow", "Deny"] {
            let button = springboard.buttons[label]
            if button.waitForExistence(timeout: timeout) {
                button.tap()
                return true
            }
        }
        return false
    }

    /// Advances via the primary button until a step whose title `title` appears
    /// (checking BEFORE each tap so it stops exactly on the target step and never
    /// taps past a last step, which would complete onboarding). Assumes the mic is
    /// already granted so the permissions step is continuable. Returns whether the
    /// target title became visible.
    private func walkToStepTitle(_ app: XCUIApplication, _ title: String, maxTaps: Int = 6) -> Bool {
        let target = app.staticTexts[title]
        let primary = app.buttons["onboarding.primaryButton"]
        for _ in 0..<maxTaps {
            if target.waitForExistence(timeout: 2) { return true }
            if primary.exists && primary.isEnabled && primary.isHittable {
                primary.tap()
            }
        }
        return target.exists
    }
}
