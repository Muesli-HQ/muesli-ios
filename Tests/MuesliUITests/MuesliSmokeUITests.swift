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
