import XCTest
@testable import Muesli

final class LiveActivityWaveformTests: XCTestCase {
    func testMetersAreCoalescedAndReturnToQuietWithoutEndlessSilenceUpdates() {
        var sampler = MuesliLiveActivityWaveformSampler()
        var updates: [(Double, [Double])] = []
        for tick in 0...60 {
            let time = Double(tick) * 0.05
            if let samples = sampler.sample(time < 1 ? 1 : 0, at: time) {
                updates.append((time, samples))
            }
        }
        XCTAssertEqual(updates.first?.0, 0.5)
        XCTAssertEqual(updates.first?.1, [1, 1, 1, 1, 1])
        XCTAssertEqual(updates.last?.1, [0, 0, 0, 0, 0])
        XCTAssertLessThanOrEqual(updates.count, 4)
        for pair in zip(updates, updates.dropFirst()) {
            XCTAssertGreaterThanOrEqual(pair.1.0 - pair.0.0, 0.499)
        }
    }

    func testMeterKeepsBriefPeaksBetweenSystemUpdates() {
        var sampler = MuesliLiveActivityWaveformSampler()
        var result: [Double]?
        for tick in 0...10 {
            result = sampler.sample(tick == 1 ? 1 : 0, at: Double(tick) * 0.05) ?? result
        }
        XCTAssertEqual(result, [1, 0, 0, 0, 0])
    }

    func testMalformedOrMissingEnvelopesStayFiniteAndBounded() {
        XCTAssertEqual(MuesliLiveActivityWaveform.bars(nil), [0, 0, 0, 0, 0])
        XCTAssertEqual(MuesliLiveActivityWaveform.bars([.nan, .infinity, -1, 0.5, 8]), [0, 0, 0, 0.5, 1])
        XCTAssertEqual(MuesliLiveActivityWaveform.bars([0.5]), [0, 0, 0, 0, 0.5])
        XCTAssertEqual(MuesliLiveActivityWaveform.bars([1, 0, 0, 0, 0, 0]), [0, 0, 0, 0, 0])
    }

    func testLongVoiceNotePromotionKeepsShowingMicrophoneInput() {
        for phase in ["Listening", "Recording", "Long voice note", "Notepad"] {
            let state = MuesliLiveActivityAttributes.ContentState(
                title: "Dictation", phase: phase, detail: "Recording", startedAt: .now, accent: "blue"
            )
            XCTAssertTrue(state.isCapturingAudio)
        }
    }

    func testLegacyActivityDecodesWithoutWaveformAndProcessingDoesNotShowInput() throws {
        let json = #"{"title":"Dictation","phase":"Listening","detail":"Recording","startedAt":0,"accent":"blue"}"#
        var state = try JSONDecoder().decode(MuesliLiveActivityAttributes.ContentState.self, from: Data(json.utf8))
        XCTAssertNil(state.waveform)
        XCTAssertNil(state.copyURL)
        XCTAssertTrue(state.isCapturingAudio)
        for phase in ["Transcribing", "Ended", "Failed", "Cancelled", "Ready"] {
            state.phase = phase
            XCTAssertFalse(state.isCapturingAudio)
        }
        let attributes = #"{"sessionID":"old","kind":"Keyboard Dictation"}"#
        let decoded = try JSONDecoder().decode(MuesliLiveActivityAttributes.self, from: Data(attributes.utf8))
        XCTAssertNil(decoded.showsDictationWaveform)
    }
}
