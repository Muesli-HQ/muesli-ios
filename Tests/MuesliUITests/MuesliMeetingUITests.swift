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
}
