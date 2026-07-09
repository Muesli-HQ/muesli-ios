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

    func testLongVoiceNoteAutomaticallyPresentsAfterInjectedThreshold() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--muesli-ui-testing",
            "--muesli-long-note-threshold-seconds=1",
        ]
        addUIInterruptionMonitor(withDescription: "Microphone permission") { alert in
            let allowButton = alert.buttons["Allow"]
            if allowButton.exists {
                allowButton.tap()
                return true
            }
            return false
        }
        app.launch()

        let recordButton = app.buttons["Start Voice Note"].firstMatch
        XCTAssertTrue(recordButton.waitForExistence(timeout: 8))
        recordButton.tap()
        app.tap()

        XCTAssertTrue(app.staticTexts["Long Voice Note"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["longVoiceNote.stopButton"].exists)
        XCTAssertTrue(
            app.staticTexts["Audio saved locally"].exists
                || app.staticTexts["Securing audio"].exists
        )
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Long Voice Note active state"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        app.buttons["Discard voice note"].tap()
        XCTAssertTrue(app.buttons["Discard Voice Note"].waitForExistence(timeout: 3))
        app.buttons["Discard Voice Note"].tap()
    }
}
