import XCTest

@MainActor
final class MuesliVoiceNoteUITests: MuesliUITestCase {
    func testVoiceNotePreviewExpandsAndShowsMetadataBadges() {
        let app = launchApp([UITestArgs.mockDictations])

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
        let app = launchApp([UITestArgs.longVoiceNote])

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
        let app = launchApp([UITestArgs.completedLongVoiceNote])

        XCTAssertTrue(app.staticTexts["Long Voice Note"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Completed long voice note transcript."].exists)
        XCTAssertFalse(app.staticTexts["Voice note ready"].exists)
        XCTAssertFalse(app.staticTexts["Audio saved"].exists)
        XCTAssertFalse(app.staticTexts["Transcribing"].exists)
    }
}
