import XCTest
@testable import Muesli

final class MuesliPreferencesTests: XCTestCase {
    func testLongVoiceNoteThresholdClampsToSupportedRange() {
        XCTAssertEqual(MuesliPreferences.clampedLongVoiceNoteThreshold(5), 30)
        XCTAssertEqual(MuesliPreferences.clampedLongVoiceNoteThreshold(60), 60)
        XCTAssertEqual(MuesliPreferences.clampedLongVoiceNoteThreshold(9_999), 600)
    }

    func testLongVoiceNoteThresholdLabelsUseSharedFormatting() {
        XCTAssertEqual(MuesliPreferences.longVoiceNoteThresholdLabel(30), "30 sec")
        XCTAssertEqual(MuesliPreferences.longVoiceNoteThresholdLabel(60), "1 min")
        XCTAssertEqual(MuesliPreferences.longVoiceNoteThresholdLabel(90), "1m 30s")
        XCTAssertEqual(MuesliPreferences.longVoiceNoteThresholdLabel(120), "2 min")
    }

    func testLongVoiceNotePreferencesDefaultEnabledAtSixtySeconds() {
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: MuesliPreferences.longVoiceNoteModeEnabledKey)
        let threshold = defaults.object(forKey: MuesliPreferences.longVoiceNoteThresholdSecondsKey)
        defer {
            if let enabled { defaults.set(enabled, forKey: MuesliPreferences.longVoiceNoteModeEnabledKey) }
            else { defaults.removeObject(forKey: MuesliPreferences.longVoiceNoteModeEnabledKey) }
            if let threshold { defaults.set(threshold, forKey: MuesliPreferences.longVoiceNoteThresholdSecondsKey) }
            else { defaults.removeObject(forKey: MuesliPreferences.longVoiceNoteThresholdSecondsKey) }
        }
        defaults.removeObject(forKey: MuesliPreferences.longVoiceNoteModeEnabledKey)
        defaults.removeObject(forKey: MuesliPreferences.longVoiceNoteThresholdSecondsKey)

        XCTAssertTrue(MuesliPreferences.longVoiceNoteModeEnabled)
        XCTAssertEqual(MuesliPreferences.longVoiceNoteThresholdSeconds, 60)
    }

    func testMeetingLiveActivitiesDefaultEnabledAndPreserveExplicitOptOut() {
        let defaults = UserDefaults.standard
        let originalValue = defaults.object(forKey: MuesliPreferences.liveActivitiesForMeetingsKey)
        defer {
            if let originalValue {
                defaults.set(originalValue, forKey: MuesliPreferences.liveActivitiesForMeetingsKey)
            } else {
                defaults.removeObject(forKey: MuesliPreferences.liveActivitiesForMeetingsKey)
            }
        }

        defaults.removeObject(forKey: MuesliPreferences.liveActivitiesForMeetingsKey)
        XCTAssertTrue(MuesliPreferences.liveActivitiesForMeetingsEnabled)

        defaults.set(false, forKey: MuesliPreferences.liveActivitiesForMeetingsKey)
        XCTAssertFalse(MuesliPreferences.liveActivitiesForMeetingsEnabled)
    }

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
