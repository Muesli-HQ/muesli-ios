import XCTest
@testable import Muesli

final class QuietSplitTests: XCTestCase {
    func testShortAudioIsOnePiece() {
        let samples = [Float](repeating: 0.5, count: 14 * 16_000)
        XCTAssertEqual(QuietSplit.ranges(for: samples), [0..<samples.count])
    }

    func testLongAudioIsCutAtThePauseBeforeTheLimit() {
        // 20 s of loud audio with a pause from 12.0 s to 12.3 s.
        var samples = [Float](repeating: 0.5, count: 20 * 16_000)
        for index in (12 * 16_000)..<(12 * 16_000 + 4_800) { samples[index] = 0 }

        let pieces = QuietSplit.ranges(for: samples)

        XCTAssertEqual(pieces.count, 2)
        let cut = pieces[0].upperBound
        XCTAssertTrue((12 * 16_000)..<(12 * 16_000 + 4_800) ~= cut, "cut at \(cut) is not in the pause")
        XCTAssertEqual(pieces[1], cut..<samples.count)
    }

    func testEveryPieceFitsTheSinglePassLimitAndNothingIsLost() {
        let samples = (0..<(95 * 16_000)).map { Float(sin(Double($0) / 37)) }
        let pieces = QuietSplit.ranges(for: samples)

        XCTAssertTrue(pieces.allSatisfy { $0.count <= QuietSplit.maxPieceSamples })
        XCTAssertEqual(pieces.first?.lowerBound, 0)
        XCTAssertEqual(pieces.last?.upperBound, samples.count)
        for (earlier, later) in zip(pieces, pieces.dropFirst()) {
            XCTAssertEqual(earlier.upperBound, later.lowerBound)
        }
    }
}
