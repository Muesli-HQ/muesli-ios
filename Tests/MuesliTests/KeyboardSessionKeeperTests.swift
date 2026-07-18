import AVFoundation
import XCTest

@testable import Muesli

final class KeyboardSessionKeeperTests: XCTestCase {
    func testDiscardAudioTapIsCallableFromNonMainActorContext() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024))
        let time = AVAudioTime(sampleTime: 0, atRate: 16_000)

        KeyboardSessionKeeper.discardAudioTap(buffer, when: time)
    }

    func testRecentAudioInputRequiresAnActiveRunningCapture() {
        let now = Date()
        let recent = now.addingTimeInterval(-0.25)

        XCTAssertFalse(RecentAudioInputHealth.isReceiving(
            hasActiveCapture: false,
            graphIsRunning: true,
            lastInputBufferAt: recent,
            now: now,
            maximumAge: 1.5
        ))
        XCTAssertFalse(RecentAudioInputHealth.isReceiving(
            hasActiveCapture: true,
            graphIsRunning: false,
            lastInputBufferAt: recent,
            now: now,
            maximumAge: 1.5
        ))
    }

    func testRecentAudioInputRejectsMissingStaleAndFutureBuffers() {
        let now = Date()

        XCTAssertFalse(RecentAudioInputHealth.isReceiving(
            hasActiveCapture: true,
            graphIsRunning: true,
            lastInputBufferAt: nil,
            now: now,
            maximumAge: 1.5
        ))
        XCTAssertFalse(RecentAudioInputHealth.isReceiving(
            hasActiveCapture: true,
            graphIsRunning: true,
            lastInputBufferAt: now.addingTimeInterval(-1.51),
            now: now,
            maximumAge: 1.5
        ))
        XCTAssertFalse(RecentAudioInputHealth.isReceiving(
            hasActiveCapture: true,
            graphIsRunning: true,
            lastInputBufferAt: now.addingTimeInterval(0.01),
            now: now,
            maximumAge: 1.5
        ))
    }

    func testRecentAudioInputAcceptsBufferAtFreshnessBoundary() {
        let now = Date()

        XCTAssertTrue(RecentAudioInputHealth.isReceiving(
            hasActiveCapture: true,
            graphIsRunning: true,
            lastInputBufferAt: now.addingTimeInterval(-1.5),
            now: now,
            maximumAge: 1.5
        ))
    }
}
