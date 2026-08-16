import XCTest
@testable import Muesli

final class ICloudSyncStatusPresentationTests: XCTestCase {
    func testSyncGlyphRotationStopsAtRest() {
        XCTAssertEqual(
            ICloudSyncGlyphRotation.degrees(elapsed: 123.45, isAnimating: false),
            0
        )
    }

    func testSyncGlyphRotationUsesAContinuousTimePhase() {
        let quarterTurn = ICloudSyncGlyphRotation.period / 4

        XCTAssertEqual(
            ICloudSyncGlyphRotation.degrees(elapsed: quarterTurn, isAnimating: true),
            90,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            ICloudSyncGlyphRotation.degrees(
                elapsed: ICloudSyncGlyphRotation.period + quarterTurn,
                isAnimating: true
            ),
            90,
            accuracy: 0.0001
        )
    }
}
