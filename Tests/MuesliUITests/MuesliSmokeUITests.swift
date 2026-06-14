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

    func testMainShellShowsDictationSmokeState() {
        let app = launchApp()

        XCTAssertTrue(app.staticTexts["muesli"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Dictation"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Start Dictation"].exists)
        XCTAssertTrue(app.staticTexts["Recent Dictations"].exists)
    }

    func testTabSwitcherNavigatesToMeetings() {
        let app = launchApp()

        XCTAssertTrue(app.buttons["tab.meetings"].waitForExistence(timeout: 8))
        app.buttons["tab.meetings"].tap()

        XCTAssertTrue(app.staticTexts["Meetings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Meeting Recorder"].exists)
        XCTAssertTrue(app.buttons["Start Meeting"].exists)
    }
}
