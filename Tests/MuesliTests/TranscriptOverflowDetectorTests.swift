import SwiftUI
import XCTest
@testable import Muesli

@MainActor
final class TranscriptOverflowDetectorTests: XCTestCase {
    func testNunitoMeasurementAtWrapBoundaryAcrossTextSizes() throws {
        let text = "Minimum microphone waveform verification"
        for (category, uiCategory): (ContentSizeCategory, UIContentSizeCategory) in [( .large, .large), (.extraExtraExtraLarge, .extraExtraExtraLarge), (.accessibilityExtraExtraExtraLarge, .accessibilityExtraExtraExtraLarge)] {
            let traits = UITraitCollection(preferredContentSizeCategory: uiCategory)
            let base = try XCTUnwrap(UIFont(name: "NunitoSans-Regular", size: 17))
            let expectedFont = UIFontMetrics(forTextStyle: .body).scaledFont(for: base, compatibleWith: traits)
            let measuredFont = MuesliTheme.transcriptUIFont(compatibleWith: traits)
            XCTAssertEqual(measuredFont.fontName, expectedFont.fontName)
            XCTAssertEqual(measuredFont.pointSize, expectedFont.pointSize, accuracy: 0.01)
            let width = (text as NSString).size(withAttributes: [.font: expectedFont]).width
            XCTAssertFalse(TranscriptOverflowDetector.isTruncated(text, width: width + 1, lineLimit: 1, sizeCategory: category))
            XCTAssertTrue(TranscriptOverflowDetector.isTruncated(text, width: width - 1, lineLimit: 1, sizeCategory: category))
        }
    }

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
