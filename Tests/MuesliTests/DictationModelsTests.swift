import XCTest

final class DictationModelsTests: XCTestCase {
    func testDictationResultRoundTripsThroughJSON() throws {
        let requestID = UUID()
        let result = DictationResult(
            requestID: requestID,
            text: "Hello from Muesli",
            engineIdentifier: "test-engine"
        )

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(DictationResult.self, from: data)

        XCTAssertEqual(decoded.requestID, requestID)
        XCTAssertEqual(decoded.text, "Hello from Muesli")
        XCTAssertEqual(decoded.engineIdentifier, "test-engine")
    }

    func testFillerWordFilterRemovesCommonDisfluencies() {
        let filtered = FillerWordFilter.apply("um you know, muesli is kind of working")

        XCTAssertEqual(filtered, "Muesli is working")
    }

    func testCustomWordMatcherAppliesPhraseReplacement() {
        let corrected = CustomWordMatcher.apply(
            text: "I use musely on iOS",
            customWords: [
                CustomWord(word: "muesli", replacement: "muesli")
            ]
        )

        XCTAssertEqual(corrected, "I use muesli on iOS")
    }

    func testCustomWordMatcherPreservesPhrasePunctuation() {
        let corrected = CustomWordMatcher.apply(
            text: "This uses parakeet v three.",
            customWords: [
                CustomWord(word: "parakeet v three", replacement: "Parakeet v3")
            ]
        )

        XCTAssertEqual(corrected, "This uses Parakeet v3.")
    }
}
