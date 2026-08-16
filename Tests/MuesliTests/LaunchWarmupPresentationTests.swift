import XCTest
@testable import Muesli

final class LaunchWarmupPresentationTests: XCTestCase {
    func testPulseStopsAtItsRestingPosition() {
        XCTAssertEqual(
            LaunchWarmupPulsePhase.progress(elapsed: 123.45, isAnimating: false),
            0
        )
    }

    func testPulseUsesAContinuousReversingTimePhase() {
        let halfCycle = LaunchWarmupPulsePhase.halfCycle

        XCTAssertEqual(
            LaunchWarmupPulsePhase.progress(elapsed: halfCycle / 2, isAnimating: true),
            0.5,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            LaunchWarmupPulsePhase.progress(elapsed: halfCycle, isAnimating: true),
            1,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            LaunchWarmupPulsePhase.progress(elapsed: halfCycle * 1.5, isAnimating: true),
            0.5,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            LaunchWarmupPulsePhase.progress(elapsed: halfCycle * 2, isAnimating: true),
            0,
            accuracy: 0.0001
        )
    }
}
