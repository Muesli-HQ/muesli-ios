import XCTest

@MainActor
final class MuesliSettingsUITests: MuesliUITestCase {
    func testModelsSettingsPrepareAutomaticallyWithoutPersistentPrepareButton() {
        let app = launchApp()

        XCTAssertTrue(app.buttons["tab.settings"].waitForExistence(timeout: 8))
        app.buttons["tab.settings"].tap()

        let models = app.staticTexts["Models"]
        scrollToElement(models, in: app, maxSwipes: 3)
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
}
