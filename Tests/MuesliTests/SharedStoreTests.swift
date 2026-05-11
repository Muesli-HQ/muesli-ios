import XCTest
@testable import Muesli

final class SharedStoreTests: XCTestCase {
    func testResultsHistoryPersistsSortedResultsAfterOneOffResultIsCleared() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SharedStore(containerURL: directory)
        let olderRequestID = UUID()
        let newerRequestID = UUID()
        let older = DictationResult(
            requestID: olderRequestID,
            text: "older dictation",
            createdAt: Date(timeIntervalSince1970: 100),
            engineIdentifier: "test"
        )
        let newer = DictationResult(
            requestID: newerRequestID,
            text: "newer dictation",
            createdAt: Date(timeIntervalSince1970: 200),
            engineIdentifier: "test"
        )

        try store.saveResult(older)
        try store.saveResult(newer)
        try store.clearResult(for: newerRequestID)

        XCTAssertNil(try store.result(for: newerRequestID))
        XCTAssertEqual(try store.resultsHistory().map(\.text), ["newer dictation", "older dictation"])
    }

    func testResultsHistoryReplacesResultForSameRequest() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SharedStore(containerURL: directory)
        let requestID = UUID()

        try store.saveResult(.init(
            requestID: requestID,
            text: "first",
            createdAt: Date(timeIntervalSince1970: 100),
            engineIdentifier: "test"
        ))
        try store.saveResult(.init(
            requestID: requestID,
            text: "replacement",
            createdAt: Date(timeIntervalSince1970: 200),
            engineIdentifier: "test"
        ))

        XCTAssertEqual(try store.resultsHistory().map(\.text), ["replacement"])
    }
}
