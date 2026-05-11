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

    func testPendingCommandRoundTripsAndClears() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SharedStore(containerURL: directory)
        let requestID = UUID()
        let command = DictationCommand(
            requestID: requestID,
            action: .stop,
            createdAt: Date(timeIntervalSince1970: 300)
        )

        try store.saveCommand(command)

        XCTAssertEqual(try store.pendingCommand(), command)

        try store.clearPendingCommand()

        XCTAssertNil(try store.pendingCommand())
    }

    func testSavingPendingRequestDoesNotOverwriteStatus() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SharedStore(containerURL: directory)
        let activeRequestID = UUID()

        try store.saveStatus(.init(requestID: activeRequestID, phase: .recording))
        try store.saveRequest(.init())

        XCTAssertEqual(try store.status().requestID, activeRequestID)
        XCTAssertEqual(try store.status().phase, .recording)
    }

    func testRecordingSessionsPersistSortedAndReplaceByID() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SharedStore(containerURL: directory)
        let sessionID = UUID()
        let older = RecordingSession(
            id: sessionID,
            kind: .meeting,
            createdAt: Date(timeIntervalSince1970: 100),
            phase: .recording
        )
        var replacement = older
        replacement.phase = .transcriptionQueued
        let newer = RecordingSession(
            kind: .quickDictation,
            createdAt: Date(timeIntervalSince1970: 200),
            phase: .completed
        )

        try store.saveSession(older)
        try store.saveSession(replacement)
        try store.saveSession(newer)

        let sessions = try store.recordingSessions()
        XCTAssertEqual(sessions.map(\.id), [newer.id, sessionID])
        XCTAssertEqual(try store.recordingSession(id: sessionID)?.phase, .transcriptionQueued)
    }

    func testTranscriptReplacesExistingTranscriptForSession() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SharedStore(containerURL: directory)
        let sessionID = UUID()

        try store.saveTranscript(.init(
            sessionID: sessionID,
            text: "first",
            createdAt: Date(timeIntervalSince1970: 100),
            engineIdentifier: "test"
        ))
        try store.saveTranscript(.init(
            sessionID: sessionID,
            text: "replacement",
            createdAt: Date(timeIntervalSince1970: 200),
            engineIdentifier: "test"
        ))

        XCTAssertEqual(try store.transcripts().map(\.text), ["replacement"])
        XCTAssertEqual(try store.transcript(for: sessionID)?.text, "replacement")
    }
}
