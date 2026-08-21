import XCTest
@testable import Muesli

final class AppTelemetryTests: XCTestCase {
    func testTelemetryDefaultsToEnabledWhenConfigurationIsAbsent() {
        XCTAssertTrue(AppTelemetryConfiguration.isEnabled(nil))
    }

    func testTelemetryRecognizesExplicitTruthyValues() {
        XCTAssertTrue(AppTelemetryConfiguration.isEnabled(true))
        XCTAssertTrue(AppTelemetryConfiguration.isEnabled("YES"))
        XCTAssertTrue(AppTelemetryConfiguration.isEnabled(" true "))
        XCTAssertTrue(AppTelemetryConfiguration.isEnabled("1"))
    }

    func testTelemetryFailsClosedForFalseAndMalformedValues() {
        XCTAssertFalse(AppTelemetryConfiguration.isEnabled(false))
        XCTAssertFalse(AppTelemetryConfiguration.isEnabled("NO"))
        XCTAssertFalse(AppTelemetryConfiguration.isEnabled("false"))
        XCTAssertFalse(AppTelemetryConfiguration.isEnabled("0"))
        XCTAssertFalse(AppTelemetryConfiguration.isEnabled("$(MUESLI_TELEMETRY_ENABLED)"))
        XCTAssertFalse(AppTelemetryConfiguration.isEnabled("typo"))
        XCTAssertFalse(AppTelemetryConfiguration.isEnabled(1))
    }

    func testParameterKeysAreLowercasedSanitizedAndTruncated() {
        let rawKey = "Error Type / With Spaces / And Symbols " + String(repeating: "x", count: 80)

        let normalized = AppTelemetryParameterSanitizer.normalizedKey(rawKey)

        XCTAssertEqual(normalized.count, AppTelemetryParameterSanitizer.maxKeyLength)
        XCTAssertTrue(normalized.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "_" })
        XCTAssertTrue(normalized.hasPrefix("error_type___with_spaces___and_symbols"))
    }

    func testParameterValuesAreTrimmedAndTruncated() {
        let rawValue = "  " + String(repeating: "a", count: 120) + "  "

        let normalized = AppTelemetryParameterSanitizer.normalizedValue(rawValue)

        XCTAssertEqual(normalized.count, AppTelemetryParameterSanitizer.maxValueLength)
        XCTAssertFalse(normalized.hasPrefix(" "))
        XCTAssertFalse(normalized.hasSuffix(" "))
    }

    func testEmptyParameterValuesUseUnknown() {
        XCTAssertEqual(AppTelemetryParameterSanitizer.normalizedKey(""), "unknown")
        XCTAssertEqual(AppTelemetryParameterSanitizer.normalizedValue("   "), "unknown")
    }

    func testCustomParametersCannotClobberReservedFailureKeys() {
        let normalized = AppTelemetryParameterSanitizer.normalizedCustomParameters([
            "timeout": "false",
            "error_type": "UserSupplied",
            "safe custom key": "value",
        ])

        XCTAssertNil(normalized["timeout"])
        XCTAssertNil(normalized["error_type"])
        XCTAssertEqual(normalized["custom_timeout"], "false")
        XCTAssertEqual(normalized["custom_error_type"], "UserSupplied")
        XCTAssertEqual(normalized["safe_custom_key"], "value")
    }
}
