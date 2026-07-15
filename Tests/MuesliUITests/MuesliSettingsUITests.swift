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

    /// Navigates into the About and Models settings sections and back via the
    /// section rows + back button, asserting each detail screen renders its
    /// real content. `settings.sectionRow.<rawValue>` uses `SettingsSection`
    /// raw values (input/meetings/dictionary/models/aiSummaries/syncPrivacy/
    /// appearance/about).
    func testSettingsSectionNavigationAndBack() {
        let app = launchApp()

        XCTAssertTrue(app.buttons["tab.settings"].waitForExistence(timeout: 8))
        app.buttons["tab.settings"].tap()

        // About section (last row in the list — may require scrolling).
        let aboutRow = app.buttons["settings.sectionRow.about"]
        XCTAssertTrue(scrollToElement(aboutRow, in: app, maxSwipes: 6))
        aboutRow.tap()

        // About content: the open-source acknowledgements + source link.
        XCTAssertTrue(app.staticTexts["OPEN SOURCE LIBRARIES"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Source code"].exists)

        // Back to the section list.
        let backButton = app.buttons["settings.backButton"]
        XCTAssertTrue(backButton.waitForExistence(timeout: 3))
        backButton.tap()

        // Models section.
        let modelsRow = app.buttons["settings.sectionRow.models"]
        XCTAssertTrue(scrollToElement(modelsRow, in: app, maxSwipes: 6))
        modelsRow.tap()

        // Models content: the model picker header.
        XCTAssertTrue(app.staticTexts["Choose model"].waitForExistence(timeout: 5))

        // Back to the section list once more.
        XCTAssertTrue(backButton.waitForExistence(timeout: 3))
        backButton.tap()
        XCTAssertTrue(app.buttons["settings.sectionRow.about"].waitForExistence(timeout: 5))
    }

    /// Exercises dictionary CRUD from the seeded fixture: assert the 2 seeded
    /// rows + count, ADD a new entry (count increments / new row appears), then
    /// DELETE a seeded row (count decrements / row gone). There is no in-place
    /// edit affordance in the UI, so add + delete together cover the CRUD
    /// surface. The count label format is "<N> saved" (`dictionary.customWordsCount`).
    func testDictionaryAddEditDelete() {
        let app = launchApp([UITestArgs.dictionaryEntries])

        XCTAssertTrue(app.buttons["tab.settings"].waitForExistence(timeout: 8))
        app.buttons["tab.settings"].tap()

        let dictionaryRow = app.buttons["settings.sectionRow.dictionary"]
        XCTAssertTrue(scrollToElement(dictionaryRow, in: app, maxSwipes: 6))
        dictionaryRow.tap()

        // Seeded fixture: "Muesli"->nil and "GPT"->"ChatGPT" => 2 entries.
        let count = app.staticTexts["dictionary.customWordsCount"]
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertEqual(count.label, "2 saved")
        XCTAssertTrue(app.staticTexts["Muesli"].exists)
        XCTAssertTrue(app.staticTexts["GPT"].exists)

        // ADD: type a new word + replacement and tap Add.
        let wordField = app.textFields["dictionary.wordField"]
        XCTAssertTrue(scrollToElement(wordField, in: app, maxSwipes: 4))
        wordField.tap()
        wordField.typeText("Vorflux")

        let replacementField = app.textFields["dictionary.replacementField"]
        replacementField.tap()
        replacementField.typeText("Vorflux AI")

        let addButton = app.buttons["dictionary.addButton"]
        XCTAssertTrue(addButton.isEnabled)
        addButton.tap()

        // Count increments to 3 and the new row appears.
        XCTAssertTrue(waitForLabel("3 saved", of: count, timeout: 5))
        XCTAssertTrue(app.staticTexts["Vorflux"].waitForExistence(timeout: 3))

        // DELETE: tap a delete button on a seeded row. The button's id is
        // "dictionary.deleteButton.<uuid>", so query it via a BEGINSWITH
        // predicate on the dynamic identifier.
        let deletePredicate = NSPredicate(format: "identifier BEGINSWITH %@", "dictionary.deleteButton.")
        let deleteButton = app.buttons.matching(deletePredicate).firstMatch
        XCTAssertTrue(scrollToElement(deleteButton, in: app, maxSwipes: 4))
        deleteButton.tap()

        // Count decrements back to 2.
        XCTAssertTrue(waitForLabel("2 saved", of: count, timeout: 5))
    }

    /// Verifies the in-app keyboard setup surfaces: the "Voice Notes" section
    /// (`settings.sectionRow.input`) renders the keyboard extension row and a
    /// session-mode toggle whose persisted state flips when toggled.
    ///
    /// KNOWN GAP: the keyboard EXTENSION UI — the system keyboard rendered
    /// inside another app's text field — is NOT reliably XCUITest-able. It runs
    /// cross-process, and driving it depends on Full Access being granted and
    /// the extension being enabled in Springboard/iOS Settings, neither of
    /// which XCUITest can arrange deterministically. Coverage is therefore
    /// limited to the containing app's keyboard setup row + the session-mode
    /// toggle exercised here.
    func testKeyboardHandoffSurfacesInAppOnly() {
        let app = launchApp()

        XCTAssertTrue(app.buttons["tab.settings"].waitForExistence(timeout: 8))
        app.buttons["tab.settings"].tap()

        // "Voice Notes" section hosts the keyboard setup rows.
        let inputRow = app.buttons["settings.sectionRow.input"]
        XCTAssertTrue(scrollToElement(inputRow, in: app, maxSwipes: 6))
        inputRow.tap()

        // Keyboard Extension status row is present.
        XCTAssertTrue(app.staticTexts["Keyboard Extension"].waitForExistence(timeout: 5))

        // Session-mode toggle flips its persisted switch value on tap.
        let toggle = app.switches["settings.keyboardSessionToggle"]
        XCTAssertTrue(scrollToElement(toggle, in: app, maxSwipes: 4))
        let initialValue = (toggle.value as? String) ?? ""
        toggle.tap()
        XCTAssertTrue(waitForValueChange(from: initialValue, of: toggle, timeout: 5))
        let toggledValue = (toggle.value as? String) ?? ""
        XCTAssertNotEqual(toggledValue, initialValue)

        // Toggle back and assert it returns to the initial state.
        toggle.tap()
        XCTAssertTrue(waitForValueChange(from: toggledValue, of: toggle, timeout: 5))
        XCTAssertEqual((toggle.value as? String) ?? "", initialValue)
    }

    // MARK: - Helpers

    /// Polls until `element.label` equals `expected` or the timeout elapses.
    private func waitForLabel(_ expected: String, of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "label == %@", expected)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Polls until `element.value` differs from `previous` or the timeout elapses.
    private func waitForValueChange(from previous: String, of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "value != %@", previous)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
