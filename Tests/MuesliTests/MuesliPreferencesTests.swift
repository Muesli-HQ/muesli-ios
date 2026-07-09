import XCTest
@testable import Muesli

final class MuesliPreferencesTests: XCTestCase {
    func testOpenRouterModelReturnsCustomStoredValue() {
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

        XCTAssertEqual(MuesliPreferences.openRouterModel, "custom/open-router-model-from-debug-tooling")
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

    func testSummaryModelTelemetryIdentifierPreservesPreset() throws {
        let preset = try XCTUnwrap(SummaryModelPreset.openRouterModels.last)

        XCTAssertEqual(
            SummaryModelPreset.telemetryIdentifier(for: preset.id, backend: .openRouter),
            preset.id
        )
    }

    func testSummaryModelTelemetryIdentifierBucketsCustomModel() {
        XCTAssertEqual(
            SummaryModelPreset.telemetryIdentifier(
                for: "custom/open-router-model-from-debug-tooling",
                backend: .openRouter
            ),
            "custom"
        )
    }

    func testSummaryModelTelemetryIdentifierBucketsEmptyModel() {
        XCTAssertEqual(
            SummaryModelPreset.telemetryIdentifier(for: "  \n", backend: .openRouter),
            "unknown"
        )
    }
}
