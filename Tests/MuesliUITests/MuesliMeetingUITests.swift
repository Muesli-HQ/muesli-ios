import XCTest

@MainActor
final class MuesliMeetingUITests: MuesliUITestCase {
    func testMissingDurableMeetingSuppressesPhantomLiveRuntime() {
        let app = launchApp([UITestArgs.missingActiveMeetingHistory])

        XCTAssertTrue(app.buttons["tab.meetings"].waitForExistence(timeout: 8))
        app.buttons["tab.meetings"].tap()

        XCTAssertTrue(app.staticTexts["Start a new meeting"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Live meeting"].exists)
        XCTAssertFalse(app.buttons["Return to Meeting"].exists)
    }

    func testInterruptedPersistedMeetingIsPresentedAsRecoveryNotLiveCapture() {
        let app = launchApp([UITestArgs.interruptedMeetingRecovery])

        XCTAssertTrue(app.buttons["tab.meetings"].waitForExistence(timeout: 8))
        app.buttons["tab.meetings"].tap()

        XCTAssertTrue(app.staticTexts["Meeting needs recovery"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Live meeting"].exists)
        app.buttons["Return to Meeting"].tap()
        XCTAssertTrue(app.staticTexts["Interrupted Meeting"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Recording interrupted"].exists)
        XCTAssertFalse(app.staticTexts["Listening"].exists)
        XCTAssertFalse(app.staticTexts["Audio is being captured locally"].exists)
        XCTAssertTrue(app.buttons["meetingDetail.stopButton"].exists)
    }

    func testProcessingMeetingDoesNotExposeCaptureControls() {
        let app = launchApp([UITestArgs.processingMeeting])

        XCTAssertTrue(app.buttons["tab.meetings"].waitForExistence(timeout: 8))
        app.buttons["tab.meetings"].tap()

        XCTAssertTrue(app.staticTexts["Meeting processing"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Live meeting"].exists)
        app.buttons["Return to Meeting"].tap()
        XCTAssertTrue(app.staticTexts["Processing Meeting"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Processing audio"].exists)
        XCTAssertFalse(app.buttons["meetingDetail.stopButton"].exists)
        XCTAssertFalse(app.buttons["meetingDetail.discardButton"].exists)
    }

    func testProcessedMeetingDefaultsFromRawTranscriptToGeneratedSummary() {
        let app = launchApp([UITestArgs.processingMeetingSummary])

        XCTAssertTrue(app.buttons["tab.meetings"].waitForExistence(timeout: 8))
        app.buttons["tab.meetings"].tap()
        XCTAssertTrue(app.buttons["Return to Meeting"].waitForExistence(timeout: 5))
        app.buttons["Return to Meeting"].tap()

        let rawTranscript = app.staticTexts["Raw transcript should no longer be selected after processing."]
        XCTAssertTrue(rawTranscript.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["The generated meeting summary is selected by default."].waitForExistence(timeout: 25))
        XCTAssertTrue(rawTranscript.waitForNonExistence(timeout: 5))
    }

    func testLiveMeetingDisplaysCompletedTranscriptChunksWithoutLeavingRecording() {
        let app = launchApp([UITestArgs.liveMeetingTranscript])

        XCTAssertTrue(app.buttons["tab.meetings"].waitForExistence(timeout: 8))
        app.buttons["tab.meetings"].tap()
        XCTAssertTrue(app.staticTexts["Live meeting"].waitForExistence(timeout: 5))
        app.buttons["Return to Meeting"].tap()

        XCTAssertTrue(app.staticTexts["Live Transcript"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["This transcript appeared while the meeting was still recording."].exists)
        XCTAssertTrue(app.buttons["meetingDetail.stopButton"].exists)
    }

    /// Best-effort REAL record flow (no fixtures): tap Start Meeting, grant the
    /// microphone permission alert if it appears, and assert the live capture UI
    /// surfaces and then ends when stopped. Tolerates the permission-deny branch
    /// on the CI runner: if the mic is denied no phantom live capture may appear.
    func testRealRecordMeetingStartShowsLiveUIAndStops() {
        let app = launchApp()

        XCTAssertTrue(app.buttons["tab.meetings"].waitForExistence(timeout: 8))
        app.buttons["tab.meetings"].tap()

        // Register the mic-permission interruption monitor before the alert can
        // appear so it can be auto-granted once we trigger a UI event.
        addMicPermissionMonitor(on: app)

        let startButton = app.buttons["meetings.primaryButton"]
        XCTAssertTrue(startButton.waitForExistence(timeout: 5))
        startButton.tap()

        // The interruption monitor only fires on the next UI event; also fall
        // back to the springboard grant in case the monitor does not fire.
        app.tap()
        grantMicPermissionViaSpringboard()

        let stopButton = app.buttons["meetingDetail.stopButton"]
        let returnButton = app.buttons["Return to Meeting"]

        // Live capture starts only if the mic is granted: the app navigates into
        // the meeting detail (stop control) and/or surfaces "Return to Meeting".
        let liveCaptureStarted = stopButton.waitForExistence(timeout: 12)
            || returnButton.waitForExistence(timeout: 2)

        if liveCaptureStarted {
            // If only the landing "Return to Meeting" surfaced, navigate into
            // the detail so we can exercise the real stop control.
            if !stopButton.exists, returnButton.exists {
                returnButton.tap()
            }
            XCTAssertTrue(stopButton.waitForExistence(timeout: 8))

            // Live capture UI: the active waveform and/or the "Listening" status
            // render while the meeting is being recorded.
            let waveform = app.descendants(matching: .any)
                .matching(identifier: "meeting.waveform").firstMatch
            XCTAssertTrue(waveform.exists || app.staticTexts["Listening"].exists)

            // Stop the meeting. The stop button calls the coordinator directly;
            // there is no confirmation dialog on this control.
            stopButton.tap()

            // Stopping ends live capture: the stop control disappears as the
            // session leaves the recording phase (into processing/completed).
            XCTAssertTrue(stopButton.waitForNonExistence(timeout: 12))
        } else {
            // Permission-deny branch: no phantom live capture may appear and the
            // app must stay responsive on the meetings landing without crashing.
            XCTAssertFalse(stopButton.exists)
            XCTAssertTrue(app.buttons["meetings.primaryButton"].exists
                || app.staticTexts["Start a new meeting"].exists)
        }
    }
}
