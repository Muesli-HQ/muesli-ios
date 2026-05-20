import XCTest
@testable import Muesli

final class SharedStoreTests: XCTestCase {
    func testLegacyJSONFilesMigrateIntoSQLiteStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        let requestID = UUID()
        let result = DictationResult(
            requestID: requestID,
            text: "migrated dictation",
            createdAt: Date(timeIntervalSince1970: 200),
            engineIdentifier: "parakeet-v3"
        )
        let command = DictationCommand(
            requestID: requestID,
            action: .stop,
            createdAt: Date(timeIntervalSince1970: 250)
        )
        let customWord = CustomWord(
            word: "muesli",
            replacement: "Muesli",
            createdAt: Date(timeIntervalSince1970: 300)
        )

        try encoder.encode([result]).write(
            to: directory.appendingPathComponent("dictation-history.json")
        )
        try encoder.encode(result).write(
            to: directory.appendingPathComponent("result-\(requestID.uuidString).json")
        )
        try encoder.encode(command).write(
            to: directory.appendingPathComponent("pending-command.json")
        )
        try encoder.encode([customWord]).write(
            to: directory.appendingPathComponent("custom-words.json")
        )

        let store = SharedStore(containerURL: directory)

        XCTAssertEqual(try store.resultsHistory(), [result])
        XCTAssertEqual(try store.result(for: requestID), result)
        XCTAssertEqual(try store.pendingCommand(), command)
        XCTAssertEqual(try store.customWords(), [customWord])
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Muesli.sqlite").path))
    }

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

    func testKeyboardRuntimeStatusRoundTripsAndClears() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SharedStore(containerURL: directory)
        let requestID = UUID()
        let status = KeyboardRuntimeStatus(
            isActive: true,
            activeRequestID: requestID,
            phase: .recording,
            message: "Listening",
            updatedAt: Date(timeIntervalSince1970: 500)
        )

        try store.saveKeyboardRuntimeStatus(status)

        XCTAssertEqual(try store.keyboardRuntimeStatus(), status)

        try store.clearKeyboardRuntimeStatus()

        XCTAssertNil(try store.keyboardRuntimeStatus())
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

    func testRecordingSessionDecodesLegacyPayloadWithoutAudioRetentionFlag() throws {
        let session = RecordingSession(
            kind: .meeting,
            createdAt: Date(timeIntervalSince1970: 100),
            phase: .completed,
            audioFileName: "session.wav"
        )
        let data = try JSONEncoder().encode(session)
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        payload.removeValue(forKey: "keepsAudioRecording")
        let legacyData = try JSONSerialization.data(withJSONObject: payload)

        let decoded = try JSONDecoder().decode(RecordingSession.self, from: legacyData)

        XCTAssertFalse(decoded.keepsAudioRecording)
        XCTAssertEqual(decoded.audioFileName, "session.wav")
    }

    func testDeleteAudioFileRemovesRecordingFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SharedStore(containerURL: directory)
        let url = try store.audioFileURL(fileName: "session.wav")
        try Data("audio".utf8).write(to: url)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        try store.deleteAudioFile(fileName: "session.wav")

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
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

    func testTranscriptDecodesLegacyPayloadWithoutMeetingProcessingFields() throws {
        let transcript = Transcript(
            sessionID: UUID(),
            text: "legacy transcript",
            createdAt: Date(timeIntervalSince1970: 100),
            engineIdentifier: "test"
        )
        let data = try JSONEncoder().encode(transcript)
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        payload.removeValue(forKey: "speakerTranscript")
        payload.removeValue(forKey: "summaryText")
        payload.removeValue(forKey: "diarizationState")
        payload.removeValue(forKey: "summaryState")
        let legacyData = try JSONSerialization.data(withJSONObject: payload)

        let decoded = try JSONDecoder().decode(Transcript.self, from: legacyData)

        XCTAssertEqual(decoded.text, "legacy transcript")
        XCTAssertEqual(decoded.diarizationState, .notStarted)
        XCTAssertEqual(decoded.summaryState, .notStarted)
        XCTAssertNil(decoded.summaryText)
    }

    func testCustomWordsPersistAndRemove() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SharedStore(containerURL: directory)
        let entry = CustomWord(
            word: "Parakeet v3",
            replacement: "Parakeet v3",
            createdAt: Date(timeIntervalSince1970: 700)
        )

        try store.saveCustomWords([])
        try store.addCustomWord(entry)

        XCTAssertEqual(try store.customWords(), [entry])

        try store.removeCustomWord(id: entry.id)

        XCTAssertEqual(try store.customWords(), [])
    }
}
