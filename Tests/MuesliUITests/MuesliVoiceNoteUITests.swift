import XCTest

@MainActor
final class MuesliVoiceNoteUITests: MuesliUITestCase {
    func testVoiceNotePreviewExpandsAndShowsMetadataBadges() {
        let app = launchApp([UITestArgs.mockDictations])

        let readMore = firstElement(
            matchingIdentifierPrefix: "dictation.readMore.", ofType: .button, in: app
        )
        // The mock history rows live in the DictationView ScrollView/LazyVStack
        // below the recorder panel, so scroll the `readMore` button into view to
        // make it hittable before interacting with it.
        XCTAssertTrue(scrollToElement(readMore, in: app))
        XCTAssertTrue(readMore.waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any)["voiceNote.badge.notes"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["voiceNote.badge.longForm"].firstMatch.exists)

        readMore.tap()

        XCTAssertTrue(app.buttons[readMore.identifier].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons[readMore.identifier].label, "Show less")
        attachScreenshot(app, named: "Expanded voice note preview with metadata badges")

        app.buttons[readMore.identifier].tap()
        XCTAssertEqual(app.buttons[readMore.identifier].label, "Read more")
        attachScreenshot(app, named: "Collapsed four-line voice note preview")
    }

    func testLongVoiceNoteActiveStateAndDiscardConfirmation() {
        let app = launchApp([UITestArgs.longVoiceNote])

        XCTAssertTrue(app.staticTexts["Long Voice Note"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["longVoiceNote.stopButton"].exists)
        XCTAssertTrue(app.staticTexts["Audio saved locally"].exists)
        attachScreenshot(app, named: "Long Voice Note active state")

        app.buttons["Discard voice note"].tap()
        XCTAssertTrue(app.buttons["Discard Voice Note"].waitForExistence(timeout: 3))
    }

    func testCompletedLongVoiceNoteHidesProgressChecklist() {
        let app = launchApp([UITestArgs.completedLongVoiceNote])

        XCTAssertTrue(app.staticTexts["Long Voice Note"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Completed long voice note transcript."].exists)
        XCTAssertFalse(app.staticTexts["Voice note ready"].exists)
        XCTAssertFalse(app.staticTexts["Audio saved"].exists)
        XCTAssertFalse(app.staticTexts["Transcribing"].exists)
    }

    /// Deterministic (CI-safe) copy + share coverage driven by the seeded
    /// completed-dictation fixture. The fixture seeds one completed quick
    /// dictation (transcript "Completed dictation transcript for copy and
    /// share.") with retained audio, so the history row is openable into the
    /// audio-detail screen (ShareLink).
    func testCompletedDictationCopyAndShareFixture() {
        let app = launchApp([UITestArgs.completedDictation])

        // The seeded transcript renders on the main voice-notes screen inside
        // the DictationView ScrollView/LazyVStack below the recorder panel, so
        // scroll it into view to make it hittable before interacting with it.
        let transcript = app.staticTexts["Completed dictation transcript for copy and share."]
        XCTAssertTrue(scrollToElement(transcript, in: app))
        XCTAssertTrue(transcript.waitForExistence(timeout: 8))

        // COPY on the MAIN screen: tap the directly-tappable history-row copy
        // control and immediately assert the "Copied" status appears in the
        // history header. `dictation.clipboardStatus` auto-clears after ~1.2s,
        // so it must be asserted right after tapping (never from the detail
        // screen, which does not render it).
        let copyButton = app.buttons["dictation.copyButton"]
        XCTAssertTrue(copyButton.waitForExistence(timeout: 5))
        copyButton.tap()

        let clipboardStatus = app.descendants(matching: .any)["dictation.clipboardStatus"]
        XCTAssertTrue(clipboardStatus.waitForExistence(timeout: 2))

        // SHARE in DETAIL: open the seeded history row by its dynamic
        // `dictation.historyRow.<uuid>` identifier. The uuid is generated at
        // runtime, so match any element whose identifier begins with the stable
        // prefix rather than reconstructing the full string.
        let historyRow = firstElement(
            matchingIdentifierPrefix: "dictation.historyRow.", in: app
        )
        XCTAssertTrue(historyRow.waitForExistence(timeout: 5))
        historyRow.tap()

        // The audio-detail screen exposes the ShareLink. Assert it exists and is
        // hittable, but do NOT tap it (that would open the system share sheet).
        let shareButton = app.buttons["dictation.shareButton"]
        XCTAssertTrue(shareButton.waitForExistence(timeout: 5))
        XCTAssertTrue(shareButton.isHittable)
    }

    /// Best-effort real-record coverage. Asserts only deterministic UI state
    /// transitions (never transcript text) and tolerates both the microphone
    /// permission grant and deny branches on the runner.
    func testRealRecordTogglesRecordingStateAndDiscard() {
        let app = launchApp()
        addMicPermissionMonitor(on: app)

        // The primary button sits inside the DictationView ScrollView/LazyVStack
        // below the header + stats, so scroll it into view first to ensure it is
        // hittable before tapping.
        let primaryButton = app.buttons["dictation.primaryButton"]
        XCTAssertTrue(scrollToElement(primaryButton, in: app))
        XCTAssertTrue(primaryButton.waitForExistence(timeout: 8))
        primaryButton.tap()

        // Trigger the interruption monitor (and fall back to springboard) so a
        // pending microphone permission alert is answered.
        app.tap()
        grantMicPermissionViaSpringboard()

        // The cancel/discard control ("Discard Recording") is only present while
        // recording, so its appearance signals the grant branch.
        let cancelButton = app.buttons["dictation.cancelButton"]
        if cancelButton.waitForExistence(timeout: 8) {
            // GRANT branch: recording state is active. Tapping the discard
            // control immediately cancels the recording (there is no secondary
            // confirmation dialog for quick dictation), so the recording UI must
            // disappear.
            cancelButton.tap()
            XCTAssertTrue(
                cancelButton.waitForNonExistence(timeout: 8),
                "Recording UI should disappear after discarding"
            )
            XCTAssertTrue(primaryButton.waitForExistence(timeout: 5))
        } else {
            // DENY branch: no recording started. The app must remain in a
            // graceful idle state with the primary button still available.
            XCTAssertTrue(primaryButton.waitForExistence(timeout: 5))
            XCTAssertFalse(cancelButton.exists)
        }
    }
}
