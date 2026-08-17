import XCTest
@testable import Muesli

final class ICloudSyncStatusPresentationTests: XCTestCase {
    func testSyncGlyphRotationStopsAtRest() {
        let startedAt = Date(timeIntervalSinceReferenceDate: 100)

        XCTAssertEqual(
            ICloudSyncGlyphRotation.degrees(
                at: startedAt.addingTimeInterval(0.4),
                startedAt: startedAt,
                isAnimating: false
            ),
            0
        )
    }

    func testSyncGlyphRotationStartsAtRest() {
        let startedAt = Date(timeIntervalSinceReferenceDate: 100)

        XCTAssertEqual(
            ICloudSyncGlyphRotation.degrees(
                at: startedAt,
                startedAt: startedAt,
                isAnimating: true
            ),
            0
        )
    }

    func testSyncGlyphRotationUsesTimeSinceActivation() {
        let startedAt = Date(timeIntervalSinceReferenceDate: 100)
        let quarterTurn = ICloudSyncGlyphRotation.period / 4

        XCTAssertEqual(
            ICloudSyncGlyphRotation.degrees(
                at: startedAt.addingTimeInterval(quarterTurn),
                startedAt: startedAt,
                isAnimating: true
            ),
            90,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            ICloudSyncGlyphRotation.degrees(
                at: startedAt.addingTimeInterval(ICloudSyncGlyphRotation.period + quarterTurn),
                startedAt: startedAt,
                isAnimating: true
            ),
            90,
            accuracy: 0.0001
        )
    }
}
