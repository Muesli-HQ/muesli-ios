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
}
