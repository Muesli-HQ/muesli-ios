import XCTest

@testable import Muesli

final class MeetingChunkTranscriptMergerTests: XCTestCase {
    func testMergeSortsChunksAndOffsetsTokenTiming() {
        let later = MeetingChunkTranscription(
            chunk: MeetingAudioChunk(
                index: 1,
                url: URL(fileURLWithPath: "/tmp/chunk-1.wav"),
                startTime: 12,
                duration: 4
            ),
            result: DetailedTranscriptionResult(
                text: "second chunk",
                duration: 4,
                tokens: [
                    TimedTranscriptToken(token: "second", startTime: 0.5, endTime: 1.0, confidence: 0.9)
                ]
            )
        )
        let earlier = MeetingChunkTranscription(
            chunk: MeetingAudioChunk(
                index: 0,
                url: URL(fileURLWithPath: "/tmp/chunk-0.wav"),
                startTime: 3,
                duration: 5
            ),
            result: DetailedTranscriptionResult(
                text: "first chunk",
                duration: 5,
                tokens: [
                    TimedTranscriptToken(token: "first", startTime: 1.0, endTime: 1.5, confidence: 0.95)
                ]
            )
        )

        let merged = MeetingChunkTranscriptMerger.merge([later, earlier])

        XCTAssertEqual(merged.text, "first chunk second chunk")
        XCTAssertEqual(merged.duration, 16)
        XCTAssertEqual(merged.tokens.map(\.token), ["first", "second"])
        XCTAssertEqual(merged.tokens[0].startTime, 4)
        XCTAssertEqual(merged.tokens[0].endTime, 4.5)
        XCTAssertEqual(merged.tokens[1].startTime, 12.5)
        XCTAssertEqual(merged.tokens[1].endTime, 13)
    }
}
