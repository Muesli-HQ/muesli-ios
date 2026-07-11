import SwiftUI
import XCTest
@testable import Muesli

@MainActor
final class TranscriptOverflowDetectorTests: XCTestCase {
    func testShortTranscriptDoesNotOverflow() {
        XCTAssertFalse(
            TranscriptOverflowDetector.isTruncated(
                "A short voice note.",
                width: 240,
                lineLimit: 4,
                sizeCategory: .large
            )
        )
    }

    func testFifthExplicitLineOverflows() {
        XCTAssertTrue(
            TranscriptOverflowDetector.isTruncated(
                "One\nTwo\nThree\nFour\nFive",
                width: 240,
                lineLimit: 4,
                sizeCategory: .large
            )
        )
    }

    func testFourExplicitLinesFit() {
        XCTAssertFalse(
            TranscriptOverflowDetector.isTruncated(
                "One\nTwo\nThree\nFour",
                width: 240,
                lineLimit: 4,
                sizeCategory: .large
            )
        )
    }

    func testLongTranscriptOverflowsWithoutFullHeightLayout() {
        let transcript = Array(repeating: "A deliberately long transcript segment", count: 2_000)
            .joined(separator: " ")

        XCTAssertTrue(
            TranscriptOverflowDetector.isTruncated(
                transcript,
                width: 240,
                lineLimit: 4,
                sizeCategory: .large
            )
        )
    }
}
