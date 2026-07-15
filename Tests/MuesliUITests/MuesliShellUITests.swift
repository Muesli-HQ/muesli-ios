import XCTest

@MainActor
final class MuesliShellUITests: MuesliUITestCase {
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
        scrollToElement(about, in: app, maxSwipes: 5)
        XCTAssertTrue(about.exists)
        about.tap()

        XCTAssertTrue(app.staticTexts["About"].waitForExistence(timeout: 5))
        let openSourceHeader = app.staticTexts["OPEN SOURCE LIBRARIES"]
        scrollToElement(openSourceHeader, in: app, maxSwipes: 4)
        XCTAssertTrue(openSourceHeader.exists)
        XCTAssertTrue(app.staticTexts["FluidAudio"].exists)
        XCTAssertTrue(app.staticTexts["WhisperKit"].exists)
        XCTAssertTrue(app.staticTexts["TelemetryDeck Swift SDK"].exists)
        XCTAssertTrue(app.staticTexts["SQLite"].exists)
    }
}
