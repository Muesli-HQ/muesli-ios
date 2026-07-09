import XCTest
@testable import Muesli

final class MuesliPreferencesTests: XCTestCase {
    func testOpenRouterModelFallsBackWhenStoredValueIsNotAPreset() {
        let defaults = UserDefaults.standard
        let originalValue = defaults.object(forKey: MuesliPreferences.openRouterModelKey)
        defer {
            if let originalValue {
                defaults.set(originalValue, forKey: MuesliPreferences.openRouterModelKey)
            } else {
                defaults.removeObject(forKey: MuesliPreferences.openRouterModelKey)
            }
        }

        defaults.set("custom/open-router-model-from-debug-tooling", forKey: MuesliPreferences.openRouterModelKey)

        XCTAssertEqual(MuesliPreferences.openRouterModel, MeetingSummaryBackend.defaultOpenRouterModel)
    }

    func testOpenRouterModelReturnsStoredPreset() throws {
        let defaults = UserDefaults.standard
        let originalValue = defaults.object(forKey: MuesliPreferences.openRouterModelKey)
        defer {
            if let originalValue {
                defaults.set(originalValue, forKey: MuesliPreferences.openRouterModelKey)
            } else {
                defaults.removeObject(forKey: MuesliPreferences.openRouterModelKey)
            }
        }
        let preset = try XCTUnwrap(SummaryModelPreset.openRouterModels.last)

        defaults.set(preset.id, forKey: MuesliPreferences.openRouterModelKey)

        XCTAssertEqual(MuesliPreferences.openRouterModel, preset.id)
    }
}
