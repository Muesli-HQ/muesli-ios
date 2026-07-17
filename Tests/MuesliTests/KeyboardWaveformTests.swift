import XCTest
@testable import Muesli

final class KeyboardWaveformTests: XCTestCase {
    func testStaleAppearanceCannotSettleANewerKeyboardPresentation() {
        var appearanceGuard = MuesliKeyboardAppearanceGuard()
        let firstAppearance = appearanceGuard.beginAppearance()

        XCTAssertTrue(appearanceGuard.acceptsDeferredWork(
            from: firstAppearance,
            isPresented: true,
            hasActivatedRuntime: true
        ))

        appearanceGuard.endAppearance()
        let secondAppearance = appearanceGuard.beginAppearance()

        XCTAssertFalse(appearanceGuard.acceptsDeferredWork(
            from: firstAppearance,
            isPresented: true,
            hasActivatedRuntime: true
        ))
        XCTAssertTrue(appearanceGuard.acceptsDeferredWork(
            from: secondAppearance,
            isPresented: true,
            hasActivatedRuntime: true
        ))
    }

    func testCurrentAppearanceStillRequiresPresentationAndRuntimeActivation() {
        var appearanceGuard = MuesliKeyboardAppearanceGuard()
        let appearance = appearanceGuard.beginAppearance()

        XCTAssertFalse(appearanceGuard.acceptsDeferredWork(
            from: appearance,
            isPresented: false,
            hasActivatedRuntime: true
        ))
        XCTAssertFalse(appearanceGuard.acceptsDeferredWork(
            from: appearance,
            isPresented: true,
            hasActivatedRuntime: false
        ))
    }

    func testKeyboardWaveformUsesMeteredLevelOnlyWhileRecording() {
        XCTAssertEqual(MuesliKeyboardWaveformPresentation.mode(for: .recording), .level)
        XCTAssertEqual(
            MuesliKeyboardWaveformPresentation.level(for: .recording, inputLevel: 0.62),
            0.62
        )

        for phase in [DictationPhase.requested, .transcribing, .idle] {
            XCTAssertEqual(MuesliKeyboardWaveformPresentation.mode(for: phase), .waiting)
            XCTAssertNil(MuesliKeyboardWaveformPresentation.level(for: phase, inputLevel: 0.62))
        }
    }

    func testWaveformLevelPublishingIsQuantizedAndThrottled() {
        var throttle = MuesliWaveformLevelThrottle()
        let start = Date(timeIntervalSinceReferenceDate: 1_000)

        XCTAssertEqual(throttle.valueToPublish(0.61, at: start), 0.6)
        XCTAssertNil(throttle.valueToPublish(0.62, at: start.addingTimeInterval(0.05)))
        XCTAssertNil(throttle.valueToPublish(0.66, at: start.addingTimeInterval(0.1)))
        XCTAssertEqual(throttle.valueToPublish(0.66, at: start.addingTimeInterval(0.17)), 0.65)
        XCTAssertNil(throttle.valueToPublish(0.66, at: start.addingTimeInterval(0.3)))
        XCTAssertEqual(throttle.valueToPublish(0.66, at: start.addingTimeInterval(0.93)), 0.65)
    }

    func testWaveformLevelPublishingClampsOutOfRangeValues() {
        var throttle = MuesliWaveformLevelThrottle()
        let start = Date(timeIntervalSinceReferenceDate: 2_000)

        XCTAssertEqual(throttle.valueToPublish(-1, at: start), 0)
        XCTAssertEqual(throttle.valueToPublish(2, at: start.addingTimeInterval(0.17)), 1)
    }

    func testInAppWaveformUsesInputAsItsOnlyLiveClock() {
        XCTAssertFalse(
            MuesliInlineWaveformRefreshDriver.inputLevel.usesTimeline(for: .level)
        )
        XCTAssertTrue(
            MuesliInlineWaveformRefreshDriver.inputLevel.usesTimeline(for: .waiting)
        )
        XCTAssertTrue(
            MuesliInlineWaveformRefreshDriver.timeline.usesTimeline(for: .level)
        )
    }
}
