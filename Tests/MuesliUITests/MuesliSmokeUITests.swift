import XCTest

@MainActor
final class MuesliSmokeUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--muesli-ui-testing"]
        app.launch()
        return app
    }

    func testMainShellShowsVoiceNotesSmokeState() {
        let app = launchApp()

        XCTAssertTrue(app.staticTexts["muesli"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Voice Note"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Start Voice Note"].exists)
        XCTAssertTrue(app.staticTexts["Recent Voice Notes"].exists)
    }

    func testTabSwitcherNavigatesToMeetings() {
        let app = launchApp()

        XCTAssertTrue(app.buttons["tab.meetings"].waitForExistence(timeout: 8))
        app.buttons["tab.meetings"].tap()

        XCTAssertTrue(app.staticTexts["Meetings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Start a new meeting"].waitForExistence(timeout: 5))
    }

    func testSettingsPrioritizeCoreWorkflowsAndAboutListsOpenSourceLibraries() {
        let app = launchApp()

        XCTAssertTrue(app.buttons["tab.settings"].waitForExistence(timeout: 8))
        app.buttons["tab.settings"].tap()

        XCTAssertTrue(app.staticTexts["Voice Notes"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Meetings"].exists)
        XCTAssertFalse(app.staticTexts["Status"].exists)

        let about = app.staticTexts["About"]
        for _ in 0..<5 where !about.exists {
            app.swipeUp()
        }
        XCTAssertTrue(about.exists)
        about.tap()

        XCTAssertTrue(app.staticTexts["About"].waitForExistence(timeout: 5))
        let openSourceHeader = app.staticTexts["OPEN SOURCE LIBRARIES"]
        for _ in 0..<4 where !openSourceHeader.exists {
            app.swipeUp()
        }
        XCTAssertTrue(openSourceHeader.exists)
        XCTAssertTrue(app.staticTexts["FluidAudio"].exists)
        XCTAssertTrue(app.staticTexts["WhisperKit"].exists)
        XCTAssertTrue(app.staticTexts["TelemetryDeck Swift SDK"].exists)
        XCTAssertTrue(app.staticTexts["SQLite"].exists)
    }

    func testModelsSettingsPrepareAutomaticallyWithoutPersistentPrepareButton() {
        let app = launchApp()

        XCTAssertTrue(app.buttons["tab.settings"].waitForExistence(timeout: 8))
        app.buttons["tab.settings"].tap()

        let models = app.staticTexts["Models"]
        for _ in 0..<3 where !models.exists {
            app.swipeUp()
        }
        XCTAssertTrue(models.exists)
        models.tap()

        XCTAssertTrue(app.staticTexts["Choose model"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Prepare Model"].exists)
        XCTAssertTrue(app.staticTexts["Downloaded and ready"].exists)

        let removeModel = app.buttons["model.remove.parakeet-tdt-ctc-110m"]
        for _ in 0..<4 where !removeModel.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(removeModel.isHittable)
        XCTAssertTrue(removeModel.isEnabled)
        app.swipeUp()
        XCTAssertTrue(removeModel.isHittable)
        removeModel.tap()

        XCTAssertTrue(app.buttons["Remove Download"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Cancel"].exists)
        app.buttons["Cancel"].tap()
    }

    func testVoiceNotePreviewExpandsAndShowsMetadataBadges() {
        let app = XCUIApplication()
        app.launchArguments = ["--muesli-ui-testing", "--muesli-mock-dictations"]
        app.launch()

        let readMore = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'dictation.readMore.'")
        ).firstMatch
        XCTAssertTrue(readMore.waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any)["voiceNote.badge.notes"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["voiceNote.badge.longForm"].firstMatch.exists)

        readMore.tap()

        XCTAssertTrue(app.buttons[readMore.identifier].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons[readMore.identifier].label, "Show less")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Expanded voice note preview with metadata badges"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        app.buttons[readMore.identifier].tap()
        XCTAssertEqual(app.buttons[readMore.identifier].label, "Read more")
        let collapsedScreenshot = XCTAttachment(screenshot: app.screenshot())
        collapsedScreenshot.name = "Collapsed four-line voice note preview"
        collapsedScreenshot.lifetime = .keepAlways
        add(collapsedScreenshot)
    }

    func testMissingDurableMeetingSuppressesPhantomLiveRuntime() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--muesli-ui-testing",
            "--muesli-ui-testing-missing-active-meeting-history",
        ]
        app.launch()

        XCTAssertTrue(app.buttons["tab.meetings"].waitForExistence(timeout: 8))
        app.buttons["tab.meetings"].tap()

        XCTAssertTrue(app.staticTexts["Start a new meeting"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Live meeting"].exists)
        XCTAssertFalse(app.buttons["Return to Meeting"].exists)
    }

    func testInterruptedPersistedMeetingIsPresentedAsRecoveryNotLiveCapture() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--muesli-ui-testing",
            "--muesli-ui-testing-interrupted-meeting-recovery",
        ]
        app.launch()

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
        let app = XCUIApplication()
        app.launchArguments = [
            "--muesli-ui-testing",
            "--muesli-ui-testing-processing-meeting",
        ]
        app.launch()

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
        let app = XCUIApplication()
        app.launchArguments = [
            "--muesli-ui-testing",
            "--muesli-ui-testing-processing-meeting-summary",
        ]
        app.launch()

        XCTAssertTrue(app.buttons["tab.meetings"].waitForExistence(timeout: 8))
        app.buttons["tab.meetings"].tap()
        XCTAssertTrue(app.buttons["Return to Meeting"].waitForExistence(timeout: 5))
        app.buttons["Return to Meeting"].tap()

        XCTAssertTrue(app.staticTexts["Raw transcript should no longer be selected after processing."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["The generated meeting summary is selected by default."].waitForExistence(timeout: 25))
        XCTAssertFalse(app.staticTexts["Raw transcript should no longer be selected after processing."].exists)
    }

    func testLiveMeetingDisplaysCompletedTranscriptChunksWithoutLeavingRecording() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--muesli-ui-testing",
            "--muesli-ui-testing-live-meeting-transcript",
        ]
        app.launch()

        XCTAssertTrue(app.buttons["tab.meetings"].waitForExistence(timeout: 8))
        app.buttons["tab.meetings"].tap()
        XCTAssertTrue(app.staticTexts["Live meeting"].waitForExistence(timeout: 5))
        app.buttons["Return to Meeting"].tap()

        XCTAssertTrue(app.staticTexts["Live Transcript"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["This transcript appeared while the meeting was still recording."].exists)
        XCTAssertTrue(app.buttons["meetingDetail.stopButton"].exists)
    }

    func testLongVoiceNoteActiveStateAndDiscardConfirmation() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--muesli-ui-testing",
            "--muesli-ui-testing-long-voice-note",
        ]
        app.launch()

        XCTAssertTrue(app.staticTexts["Long Voice Note"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["longVoiceNote.stopButton"].exists)
        XCTAssertTrue(app.staticTexts["Audio saved locally"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Long Voice Note active state"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        app.buttons["Discard voice note"].tap()
        XCTAssertTrue(app.buttons["Discard Voice Note"].waitForExistence(timeout: 3))
    }

    func testCompletedLongVoiceNoteHidesProgressChecklist() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--muesli-ui-testing",
            "--muesli-ui-testing-completed-long-voice-note",
        ]
        app.launch()

        XCTAssertTrue(app.staticTexts["Long Voice Note"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Completed long voice note transcript."].exists)
        XCTAssertFalse(app.staticTexts["Voice note ready"].exists)
        XCTAssertFalse(app.staticTexts["Audio saved"].exists)
        XCTAssertFalse(app.staticTexts["Transcribing"].exists)
    }
}
