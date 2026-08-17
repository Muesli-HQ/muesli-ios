import XCTest
@testable import Muesli

final class LaunchWarmupPresentationTests: XCTestCase {
    func testPulseStopsAtItsRestingPosition() {
        let startedAt = Date(timeIntervalSinceReferenceDate: 100)

        XCTAssertEqual(
            LaunchWarmupPulsePhase.progress(
                at: startedAt.addingTimeInterval(0.4),
                startedAt: startedAt,
                isAnimating: false
            ),
            0
        )
    }

    func testPulseStartsAtItsLeadingEdge() {
        let startedAt = Date(timeIntervalSinceReferenceDate: 100)

        XCTAssertEqual(
            LaunchWarmupPulsePhase.progress(
                at: startedAt,
                startedAt: startedAt,
                isAnimating: true
            ),
            0
        )
    }

    func testPulseUsesAReversingPhaseSinceActivation() {
        let startedAt = Date(timeIntervalSinceReferenceDate: 100)
        let halfCycle = LaunchWarmupPulsePhase.halfCycle

        XCTAssertEqual(
            LaunchWarmupPulsePhase.progress(
                at: startedAt.addingTimeInterval(halfCycle / 2),
                startedAt: startedAt,
                isAnimating: true
            ),
            0.5,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            LaunchWarmupPulsePhase.progress(
                at: startedAt.addingTimeInterval(halfCycle),
                startedAt: startedAt,
                isAnimating: true
            ),
            1,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            LaunchWarmupPulsePhase.progress(
                at: startedAt.addingTimeInterval(halfCycle * 1.5),
                startedAt: startedAt,
                isAnimating: true
            ),
            0.5,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            LaunchWarmupPulsePhase.progress(
                at: startedAt.addingTimeInterval(halfCycle * 2),
                startedAt: startedAt,
                isAnimating: true
            ),
            0,
            accuracy: 0.0001
        )
    }
}
