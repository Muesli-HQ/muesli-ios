import XCTest

final class DictationModelsTests: XCTestCase {
    func testDictationResultRoundTripsThroughJSON() throws {
        let requestID = UUID()
        let result = DictationResult(
            requestID: requestID,
            text: "Hello from Muesli",
            engineIdentifier: "test-engine",
            source: "macos"
        )

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(DictationResult.self, from: data)

        XCTAssertEqual(decoded.requestID, requestID)
        XCTAssertEqual(decoded.text, "Hello from Muesli")
        XCTAssertEqual(decoded.engineIdentifier, "test-engine")
        XCTAssertEqual(decoded.source, "macos")
    }

    func testDictationResultDecodesWithoutSource() throws {
        let requestID = UUID()
        let data = """
        {
          "id": "\(UUID().uuidString)",
          "requestID": "\(requestID.uuidString)",
          "text": "Legacy dictation",
          "createdAt": 740000000,
          "engineIdentifier": "icloud"
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(DictationResult.self, from: data)

        XCTAssertEqual(decoded.requestID, requestID)
        XCTAssertEqual(decoded.text, "Legacy dictation")
        XCTAssertNil(decoded.source)
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
