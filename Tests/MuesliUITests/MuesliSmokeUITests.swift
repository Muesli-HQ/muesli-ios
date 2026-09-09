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
        XCTAssertTrue(app.buttons["Quick Note"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Notepad"].exists)
        XCTAssertTrue(app.staticTexts["Start Quick Note"].exists)
        XCTAssertTrue(app.staticTexts["Recent Voice Notes"].exists)
        XCTAssertTrue(app.buttons["Transcription model"].exists)
        XCTAssertFalse(app.staticTexts["Listening"].exists)

        app.buttons["Notepad"].tap()
        XCTAssertTrue(app.staticTexts["Start Notepad"].waitForExistence(timeout: 3))
    }

    func testSavedKeyboardVerificationSurvivesRelaunchAndCanBeReset() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--muesli-ui-testing", "--muesli-ui-testing-keyboard-permissions",
            "-muesli.onboarding.currentStep", "1",
            "-muesli.onboarding.keyboardEnabledConfirmed", "YES",
            "-muesli.onboarding.fullAccessConfirmed", "YES"
        ]
        app.launch()
        let status = app.staticTexts["Keyboard and Full Access verified. Choose Verify again to check your current settings."]
        XCTAssertTrue(status.waitForExistence(timeout: 8))
        app.terminate()
        app.launch()
        XCTAssertTrue(status.waitForExistence(timeout: 8))
        let verify = app.buttons["onboarding.verifyAgain"]
        for _ in 0..<5 where !verify.isHittable { app.swipeUp() }
        verify.tap()
        XCTAssertFalse(status.exists)
        XCTAssertTrue(app.staticTexts["The Continue button unlocks only after Muesli receives both proofs."].exists)
    }

    private func actionButtonApp(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--muesli-ui-testing", "--muesli-ui-testing-action-button-onboarding"] + arguments
        app.launch()
        return app
    }

    private func captureActionButton(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testShortcutWaveformInDynamicIsland() async throws {
        let app = XCUIApplication()
        app.launchArguments = ["--muesli-ui-testing", "--muesli-ui-testing-island-waveform", "--muesli-ui-testing-island-copy"]
        app.launch()
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        try await Task.sleep(for: .seconds(6))
        captureActionButton(springboard, name: "Dynamic Island speech input")
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.035)).press(forDuration: 1)
        XCTAssertTrue(springboard.staticTexts["Listening"].waitForExistence(timeout: 3))
        captureActionButton(springboard, name: "Dynamic Island expanded dictation")
        XCTAssertTrue(springboard.buttons["Stop keyboard dictation recording"].exists)
        try await Task.sleep(for: .seconds(6))
        captureActionButton(springboard, name: "Dynamic Island returned to quiet")
        XCTAssertTrue(springboard.staticTexts["Transcribing"].waitForExistence(timeout: 5))
        XCTAssertFalse(springboard.staticTexts["Listening"].exists)
        captureActionButton(springboard, name: "Dynamic Island processing after recording")
        XCTAssertFalse(springboard.buttons["Stop keyboard dictation recording"].exists)
        let copy = springboard.buttons["Open to copy"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 10))
        captureActionButton(springboard, name: "Dynamic Island transcript ready to copy")
        copy.tap()
        XCTAssertTrue(app.alerts["Copied to clipboard"].waitForExistence(timeout: 8))
        captureActionButton(app, name: "Dictation copied in foreground")
        app.alerts["Copied to clipboard"].buttons["OK"].tap()
    }

    func testSettingsOpensActionButtonConfiguration() {
        let app = launchApp()
        let settings = app.buttons["tab.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 8))
        settings.tap()

        let actionButton = app.staticTexts["Action Button"].firstMatch
        XCTAssertTrue(actionButton.waitForExistence(timeout: 5))
        XCTAssertTrue(actionButton.isHittable)
        captureActionButton(app, name: "Settings Action Button entry")
        actionButton.tap()

        // Settings resumes any saved setup step, including Prepare and Add.
        // Verify navigation into the actual setup screen instead of assuming
        // which step another test (or the user) previously left open.
        XCTAssertTrue(app.buttons["Close setup"].waitForExistence(timeout: 5))
        let primary = app.buttons["actionButton.primaryAction"]
        let assignment = app.buttons["actionButton.openSettings"]
        XCTAssertTrue(primary.waitForExistence(timeout: 3) || assignment.waitForExistence(timeout: 3))
        captureActionButton(app, name: "Action Button opened from Settings")
    }

    func testActionButtonAddStepExplainsImportBeforeAssignment() {
        let app = actionButtonApp(["--muesli-ui-testing-action-button-add"])
        let add = app.buttons["actionButton.primaryAction"]
        XCTAssertTrue(add.waitForExistence(timeout: 8))
        XCTAssertEqual(add.label, "Add to Shortcuts")
        XCTAssertFalse(app.buttons["actionButton.openSettings"].exists)
        captureActionButton(app, name: "Muesli guided import")
    }

    func testActionButtonClipboardSetupDoesNotRequireKeyboard() {
        let app = actionButtonApp()
        XCTAssertTrue(app.buttons["actionButton.mode.dictation"].waitForExistence(timeout: 8))
        app.buttons["actionButton.mode.dictation"].tap()
        app.buttons["actionButton.primaryAction"].tap()
        XCTAssertFalse(app.staticTexts["Verify the keyboard"].exists)
        XCTAssertFalse(app.textFields["onboarding.keyboardVerificationField"].exists)
        captureActionButton(app, name: "Muesli clipboard readiness")
    }

    func testActionButtonMeetingSetupDoesNotRequireKeyboard() {
        let app = actionButtonApp()
        XCTAssertTrue(app.buttons["actionButton.mode.meeting"].waitForExistence(timeout: 8))
        app.buttons["actionButton.mode.meeting"].tap()
        captureActionButton(app, name: "Muesli meeting choice")
        app.buttons["actionButton.primaryAction"].tap()
        XCTAssertTrue(app.staticTexts["Let Muesli listen."].exists)
        XCTAssertFalse(app.staticTexts["Verify the keyboard"].exists)
        XCTAssertFalse(app.segmentedControls["actionButton.delivery"].exists)
        captureActionButton(app, name: "Muesli meeting readiness")
    }

    func testActionButtonAssignmentUsesExactShortcutAndSettingsDestination() {
        let app = actionButtonApp(["--muesli-ui-testing-action-button-assignment", "--muesli-ui-testing-action-button-meeting"])
        XCTAssertTrue(app.buttons["actionButton.openSettings"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.buttons["actionButton.openSettings"].label, "Open Settings")
        XCTAssertTrue(app.staticTexts["Muesli Meeting Note"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["The button below opens Muesli’s settings. Go back to the main Settings list, then select Action Button."].exists)
        XCTAssertFalse(app.staticTexts["Your Action Button is ready"].exists)
        captureActionButton(app, name: "Muesli meeting assignment")
    }

    func testActionButtonAssignmentFinishesWithoutRecordingTest() {
        let app = actionButtonApp(["--muesli-ui-testing-action-button-returned"])
        let done = app.buttons["I’ve assigned it — Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["actionButton.testResult"].exists)
        done.tap()
        XCTAssertFalse(app.buttons["actionButton.openSettings"].exists)
    }

    func testActionButtonAssignmentKeepsSettingsAccessibleAtLargestTextSize() {
        let app = actionButtonApp([
            "--muesli-ui-testing-action-button-assignment",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ])
        let settings = app.buttons["actionButton.openSettings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 8))
        for _ in 0..<10 where !settings.isHittable { app.swipeUp() }
        XCTAssertTrue(settings.isHittable)
        XCTAssertTrue(app.buttons["Close setup"].isHittable)
        XCTAssertLessThanOrEqual(settings.frame.maxY, app.frame.maxY)
        captureActionButton(app, name: "Muesli assignment accessibility text size")
    }

    func testStartNotepadBeginsRecordingWithoutASecondMicTap() {
        addUIInterruptionMonitor(withDescription: "Microphone permission") { alert in
            let allowButton = alert.buttons["Allow"]
            guard allowButton.exists else { return false }
            allowButton.tap()
            return true
        }

        let app = XCUIApplication()
        app.launchArguments = [
            "--muesli-ui-testing",
            "--muesli-ui-testing-direct-start-notepad",
        ]
        app.launch()
        app.buttons["Notepad"].tap()
        let startNotepad = app.buttons.matching(NSPredicate(format: "label == %@", "Start Notepad")).firstMatch
        XCTAssertTrue(startNotepad.waitForExistence(timeout: 3))
        startNotepad.tap()

        XCTAssertTrue(app.textViews["notepad.editor"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["notepad.stopButton"].exists)
        let waveform = app.otherElements["notepad.waveform"]
        let stopBurst = app.buttons["notepad.stopButton"]
        XCTAssertTrue(waveform.exists)
        let discardBurst = app.buttons["notepad.discardBurstButton"]
        XCTAssertTrue(discardBurst.exists)
        XCTAssertLessThan(discardBurst.frame.maxX, waveform.frame.minX)
        XCTAssertLessThan(waveform.frame.maxX, stopBurst.frame.minX)
        XCTAssertEqual(stopBurst.frame.midY, discardBurst.frame.midY, accuracy: 1)
        XCTAssertEqual(
            waveform.frame.minX - discardBurst.frame.maxX,
            stopBurst.frame.minX - waveform.frame.maxX,
            accuracy: 1
        )
        XCTAssertFalse(app.staticTexts["notepad.recordingStatus"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Notepad direct-start active state"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        discardBurst.tap()
        XCTAssertTrue(app.textViews["notepad.editor"].exists)
        XCTAssertTrue(app.buttons["notepad.microphoneButton"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["notepad.stopButton"].exists)
    }

    func testActiveCapturePreviewReplacesModelControlWithWaveform() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--muesli-ui-testing",
            "--muesli-preview-waveform",
        ]
        app.launch()

        XCTAssertTrue(app.staticTexts["Listening"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["Transcription model"].exists)
    }

    func testActiveQuickNoteUsesDedicatedStopAndDiscardControls() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--muesli-ui-testing",
            "--muesli-ui-testing-active-quick-note",
            "--muesli-preview-waveform",
        ]
        app.launch()

        let discard = app.buttons["Discard Recording"]
        let stopMatches = app.buttons.matching(NSPredicate(format: "label == %@", "Stop Recording"))
        XCTAssertTrue(stopMatches.firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(discard.exists)
        guard let stop = stopMatches.allElementsBoundByIndex.min(by: {
            $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
        }) else {
            return XCTFail("Expected a dedicated Stop Recording button")
        }
        XCTAssertFalse(app.buttons["Transcription model"].exists)
        XCTAssertEqual(discard.frame.midY, stop.frame.midY, accuracy: 1)
        XCTAssertEqual(discard.frame.width, stop.frame.width, accuracy: 1)
        XCTAssertEqual(discard.frame.height, stop.frame.height, accuracy: 1)
        XCTAssertEqual(
            (discard.frame.midX + stop.frame.midX) / 2,
            app.otherElements["dictation.recorderPanel"].frame.midX,
            accuracy: 2
        )

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Active Quick Note with unobstructed elapsed timer"
        screenshot.lifetime = .keepAlways
        add(screenshot)
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
        let tabBar = app.buttons["tab.settings"]
        for _ in 0..<4 {
            if removeModel.exists,
               removeModel.isHittable,
               removeModel.frame.maxY < tabBar.frame.minY {
                break
            }
            app.swipeUp()
        }
        XCTAssertTrue(removeModel.isHittable)
        XCTAssertTrue(removeModel.isEnabled)
        XCTAssertLessThan(removeModel.frame.maxY, tabBar.frame.minY)
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
        let notesBadge = app.descendants(matching: .any)["voiceNote.badge.notes"].firstMatch
        let longFormBadge = app.descendants(matching: .any)["voiceNote.badge.longForm"].firstMatch
        let playAudio = app.buttons["voiceNote.playAudio"].firstMatch
        XCTAssertTrue(notesBadge.exists)
        XCTAssertTrue(longFormBadge.exists)
        XCTAssertTrue(playAudio.exists)

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

        let rawTranscript = app.staticTexts["Raw transcript should no longer be selected after processing."]
        XCTAssertTrue(rawTranscript.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["The generated meeting summary is selected by default."].waitForExistence(timeout: 25))
        XCTAssertTrue(rawTranscript.waitForNonExistence(timeout: 5))
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
        XCTAssertTrue(app.textViews["longVoiceNote.scratchpad"].exists)
        XCTAssertTrue(app.buttons["longVoiceNote.stopButton"].exists)
        XCTAssertTrue(app.staticTexts["Audio saved locally"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Long voice note active state"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        app.buttons["Discard voice note"].tap()
        XCTAssertTrue(app.buttons["Discard Voice Note"].waitForExistence(timeout: 3))
    }

    func testEmptyNotepadIsAnEditorWithAReusableMicrophone() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--muesli-ui-testing",
            "--muesli-ui-testing-empty-notepad",
        ]
        app.launch()

        XCTAssertTrue(app.textViews["notepad.editor"].waitForExistence(timeout: 8))
        let microphone = app.buttons["notepad.microphoneButton"]
        XCTAssertTrue(microphone.exists)
        XCTAssertEqual(microphone.frame.midX, app.windows.firstMatch.frame.midX, accuracy: 1)
        XCTAssertTrue(app.staticTexts["Tap the mic to start taking a note with Muesli"].exists)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Notepad idle microphone centered"
        screenshot.lifetime = .keepAlways
        add(screenshot)
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
