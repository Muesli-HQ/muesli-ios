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
}

