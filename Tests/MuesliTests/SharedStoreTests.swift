import XCTest
import SQLite3
@testable import Muesli

final class SharedStoreTests: XCTestCase {
    func testFreshSQLiteStoreCreatesV2Schema() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SharedStore(containerURL: directory)
        XCTAssertEqual(try store.resultsHistory(), [])

        XCTAssertEqual(try sqliteInt("PRAGMA user_version", in: directory), 2)
        XCTAssertTrue(try sqliteColumnNames(table: "result_history", in: directory).isSuperset(of: [
            "session_id",
            "text",
            "engine_identifier",
            "updated_at",
            "deleted_at",
            "cloud_record_name",
            "cloud_change_tag",
            "last_synced_at",
            "sync_dirty"
        ]))
        XCTAssertTrue(try sqliteColumnNames(table: "recording_sessions", in: directory).contains("audio_file_name"))
        XCTAssertTrue(try sqliteColumnNames(table: "transcripts", in: directory).contains("summary_model"))
        XCTAssertTrue(try sqliteColumnNames(table: "custom_words", in: directory).contains("matching_threshold"))
    }

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
        XCTAssertEqual(try sqliteString("SELECT text FROM result_history LIMIT 1", in: directory), "migrated dictation")
        XCTAssertEqual(try sqliteString("SELECT engine_identifier FROM result_history LIMIT 1", in: directory), "parakeet-v3")
        XCTAssertEqual(try sqliteString("SELECT replacement FROM custom_words LIMIT 1", in: directory), "Muesli")
        XCTAssertEqual(try sqliteInt("PRAGMA user_version", in: directory), 2)
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

    func testKeyboardHandoffStatePersistsAndClears() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SharedStore(containerURL: directory)
        let requestID = UUID()
        let started = KeyboardHandoffState(
            requestID: requestID,
            phase: .startRequested,
            message: "Starting"
        )
        let acknowledged = started.advanced(
            to: .startAcknowledged,
            message: "Starting",
            recoveryAttemptCount: 1
        )

        XCTAssertEqual(try store.keyboardHandoffState(), .idle)

        try store.saveKeyboardHandoffState(started)
        XCTAssertEqual(try store.keyboardHandoffState(), started)

        try store.saveKeyboardHandoffState(acknowledged)
        let retrieved = try store.keyboardHandoffState()
        XCTAssertEqual(retrieved.requestID, requestID)
        XCTAssertEqual(retrieved.phase, .startAcknowledged)
        XCTAssertEqual(retrieved.message, "Starting")
        XCTAssertEqual(retrieved.recoveryAttemptCount, 1)

        try store.clearKeyboardHandoffState()
        XCTAssertEqual(try store.keyboardHandoffState(), .idle)
    }

    func testKeyboardHandoffRecoveryPolicyRetriesStaleStartOnce() throws {
        let requestID = UUID()
        let now = Date(timeIntervalSince1970: 1_000)
        let staleStart = KeyboardHandoffState(
            requestID: requestID,
            phase: .startRequested,
            message: "Starting",
            recoveryAttemptCount: 0,
            createdAt: now.addingTimeInterval(-11),
            updatedAt: now.addingTimeInterval(-11)
        )

        let action = KeyboardHandoffRecoveryPolicy.keyboardDefaults.action(
            for: staleStart,
            latestRuntimeStatus: nil,
            canUseRuntimeStart: true,
            now: now
        )

        guard case let .retry(retryAction, retryingState) = action else {
            return XCTFail("Expected stale start to retry once")
        }
        XCTAssertEqual(retryAction, .start)
        XCTAssertEqual(retryingState.phase, .startRequested)
        XCTAssertEqual(retryingState.message, "Retrying start")
        XCTAssertEqual(retryingState.recoveryAttemptCount, 1)
    }

    func testKeyboardHandoffRecoveryPolicyRecoversStaleStartAfterRetry() throws {
        let requestID = UUID()
        let now = Date(timeIntervalSince1970: 1_000)
        let staleStart = KeyboardHandoffState(
            requestID: requestID,
            phase: .startRequested,
            message: "Retrying start",
            recoveryAttemptCount: 1,
            createdAt: now.addingTimeInterval(-20),
            updatedAt: now.addingTimeInterval(-20)
        )

        let action = KeyboardHandoffRecoveryPolicy.keyboardDefaults.action(
            for: staleStart,
            latestRuntimeStatus: nil,
            canUseRuntimeStart: true,
            now: now
        )

        guard case let .recover(recoveryState) = action else {
            return XCTFail("Expected stale retried start to request recovery")
        }
        XCTAssertEqual(recoveryState.phase, .recoveryRequested)
        XCTAssertEqual(recoveryState.message, "Open Muesli to start")
        XCTAssertEqual(recoveryState.recoveryAttemptCount, 1)
    }

    func testKeyboardHandoffRecoveryPolicyRecoversStaleRecordingWithoutRetry() throws {
        let requestID = UUID()
        let now = Date(timeIntervalSince1970: 1_000)
        let staleRecording = KeyboardHandoffState(
            requestID: requestID,
            phase: .recordingStarted,
            message: "Listening",
            createdAt: now.addingTimeInterval(-46),
            updatedAt: now.addingTimeInterval(-46)
        )

        let action = KeyboardHandoffRecoveryPolicy.keyboardDefaults.action(
            for: staleRecording,
            latestRuntimeStatus: nil,
            canUseRuntimeStart: true,
            now: now
        )

        guard case let .recover(recoveryState) = action else {
            return XCTFail("Expected stale recording to request recovery")
        }
        XCTAssertEqual(recoveryState.phase, .recoveryRequested)
        XCTAssertEqual(recoveryState.message, "Open Muesli to continue")
        XCTAssertEqual(recoveryState.recoveryAttemptCount, 1)
    }

    func testKeyboardHandoffRecoveryPolicyIgnoresFreshActiveRuntimeStatus() throws {
        let requestID = UUID()
        let now = Date(timeIntervalSince1970: 1_000)
        let staleRecording = KeyboardHandoffState(
            requestID: requestID,
            phase: .recordingStarted,
            message: "Listening",
            createdAt: now.addingTimeInterval(-60),
            updatedAt: now.addingTimeInterval(-60)
        )
        let freshRuntimeStatus = KeyboardRuntimeStatus(
            isActive: true,
            activeRequestID: requestID,
            phase: .recording,
            message: "Listening",
            supportsBackgroundStart: true,
            updatedAt: now.addingTimeInterval(-2)
        )

        let action = KeyboardHandoffRecoveryPolicy.keyboardDefaults.action(
            for: staleRecording,
            latestRuntimeStatus: freshRuntimeStatus,
            canUseRuntimeStart: true,
            now: now
        )

        XCTAssertEqual(action, .none)
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

    func testResultsHistoryIsNotPruned() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SharedStore(containerURL: directory)
        for index in 0..<205 {
            try store.saveResult(.init(
                requestID: UUID(),
                text: "dictation \(index)",
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                engineIdentifier: "test"
            ))
        }

        XCTAssertEqual(try store.resultsHistory().count, 205)
        XCTAssertEqual(try sqliteInt("SELECT COUNT(*) FROM result_history", in: directory), 205)
    }

    func testResultWritesPopulateNormalizedSyncColumns() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SharedStore(containerURL: directory)
        let result = DictationResult(
            id: UUID(),
            requestID: UUID(),
            sessionID: UUID(),
            text: "sync me",
            createdAt: Date(timeIntervalSince1970: 123),
            engineIdentifier: "parakeet-v3"
        )

        try store.saveResult(result)

        XCTAssertEqual(try sqliteString("SELECT session_id FROM result_history LIMIT 1", in: directory), result.sessionID?.uuidString)
        XCTAssertEqual(try sqliteString("SELECT text FROM result_history LIMIT 1", in: directory), "sync me")
        XCTAssertEqual(try sqliteString("SELECT engine_identifier FROM result_history LIMIT 1", in: directory), "parakeet-v3")
        XCTAssertEqual(try sqliteString("SELECT cloud_record_name FROM result_history LIMIT 1", in: directory), result.id.uuidString)
        XCTAssertEqual(try sqliteInt("SELECT sync_dirty FROM result_history LIMIT 1", in: directory), 1)
        XCTAssertGreaterThan(try sqliteDouble("SELECT updated_at FROM result_history LIMIT 1", in: directory), 0)
    }

    func testSyncedDictationPreservesLocalSessionLink() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SharedStore(containerURL: directory)
        let resultID = UUID()
        let requestID = UUID()
        let sessionID = UUID()
        let result = DictationResult(
            id: resultID,
            requestID: requestID,
            sessionID: sessionID,
            text: "local text",
            createdAt: Date(timeIntervalSince1970: 100),
            engineIdentifier: "parakeet-v3"
        )
        try store.saveResult(result)

        try store.upsertSyncedTextRecord(SyncTextRecord(
            id: resultID.uuidString,
            kind: .dictation,
            title: nil,
            text: "synced text",
            speakerTranscript: nil,
            summaryText: nil,
            manualNotes: nil,
            source: "ios",
            engineIdentifier: "parakeet-v3",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSinceNow: 60),
            startedAt: nil,
            endedAt: nil,
            durationSeconds: 0,
            wordCount: 2,
            isDeleted: false,
            cloudChangeTag: "server-tag"
        ))

        let synced = try XCTUnwrap(store.resultsHistory().first)
        XCTAssertEqual(synced.id, resultID)
        XCTAssertEqual(synced.requestID, requestID)
        XCTAssertEqual(synced.sessionID, sessionID)
        XCTAssertEqual(synced.text, "synced text")
        XCTAssertEqual(try sqliteString("SELECT session_id FROM result_history LIMIT 1", in: directory), sessionID.uuidString)
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

    func testKeyboardLiveTranscriptRoundTripsAndClears() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SharedStore(containerURL: directory)
        let requestID = UUID()
        let transcript = KeyboardLiveTranscript(
            requestID: requestID,
            text: "partial dictation",
            updatedAt: Date(timeIntervalSince1970: 700)
        )

        try store.saveKeyboardLiveTranscript(transcript)

        XCTAssertEqual(try store.keyboardLiveTranscript(), transcript)

        try store.clearKeyboardLiveTranscript()

        XCTAssertNil(try store.keyboardLiveTranscript())
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

    func testRecordingSessionsAreNotPruned() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SharedStore(containerURL: directory)
        for index in 0..<505 {
            try store.saveSession(.init(
                kind: .meeting,
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                phase: .completed
            ))
        }

        XCTAssertEqual(try store.recordingSessions().count, 505)
        XCTAssertEqual(try sqliteInt("SELECT COUNT(*) FROM recording_sessions", in: directory), 505)
    }

    func testSessionAndTranscriptWritesPopulateNormalizedSyncColumns() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SharedStore(containerURL: directory)
        let session = RecordingSession(
            id: UUID(),
            requestID: UUID(),
            kind: .meeting,
            title: "Team sync",
            createdAt: Date(timeIntervalSince1970: 100),
            startedAt: Date(timeIntervalSince1970: 90),
            endedAt: Date(timeIntervalSince1970: 120),
            phase: .completed,
            audioFileName: "meeting.wav",
            keepsAudioRecording: true,
            transcriptID: UUID(),
            engineIdentifier: "parakeet-v3"
        )
        let transcript = Transcript(
            id: try XCTUnwrap(session.transcriptID),
            sessionID: session.id,
            text: "hello",
            createdAt: Date(timeIntervalSince1970: 121),
            engineIdentifier: "parakeet-v3",
            speakerTranscript: "Speaker 1: hello",
            summaryText: "A greeting.",
            diarizationState: .completed,
            summaryState: .completed,
            summaryBackend: "chatgpt",
            summaryModel: "gpt-5.4-mini"
        )

        try store.saveSession(session)
        try store.saveTranscript(transcript)

        XCTAssertEqual(try sqliteString("SELECT title FROM recording_sessions LIMIT 1", in: directory), "Team sync")
        XCTAssertEqual(try sqliteString("SELECT audio_file_name FROM recording_sessions LIMIT 1", in: directory), "meeting.wav")
        XCTAssertEqual(try sqliteInt("SELECT keeps_audio_recording FROM recording_sessions LIMIT 1", in: directory), 1)
        XCTAssertEqual(try sqliteString("SELECT cloud_record_name FROM recording_sessions LIMIT 1", in: directory), session.id.uuidString)
        XCTAssertEqual(try sqliteInt("SELECT sync_dirty FROM recording_sessions LIMIT 1", in: directory), 1)

        XCTAssertEqual(try sqliteString("SELECT text FROM transcripts LIMIT 1", in: directory), "hello")
        XCTAssertEqual(try sqliteString("SELECT speaker_transcript FROM transcripts LIMIT 1", in: directory), "Speaker 1: hello")
        XCTAssertEqual(try sqliteString("SELECT summary_text FROM transcripts LIMIT 1", in: directory), "A greeting.")
        XCTAssertEqual(try sqliteString("SELECT summary_model FROM transcripts LIMIT 1", in: directory), "gpt-5.4-mini")
        XCTAssertEqual(try sqliteString("SELECT cloud_record_name FROM transcripts LIMIT 1", in: directory), transcript.id.uuidString)
        XCTAssertEqual(try sqliteInt("SELECT sync_dirty FROM transcripts LIMIT 1", in: directory), 1)
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

    func testDictationAudioFileNameUsesTimestamp() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SharedStore(containerURL: directory)
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = .current
        components.year = 2026
        components.month = 6
        components.day = 21
        components.hour = 9
        components.minute = 7
        components.second = 5
        let date = try XCTUnwrap(components.date)

        let url = try store.newDictationAudioFileURL(startedAt: date)

        XCTAssertEqual(url.lastPathComponent, "dictation-20260621-090705.wav")
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
        XCTAssertEqual(try sqliteInt("SELECT COUNT(*) FROM custom_words WHERE id = '\(entry.id.uuidString)'", in: directory), 1)
        XCTAssertNotNil(try sqliteOptionalDouble("SELECT deleted_at FROM custom_words WHERE id = '\(entry.id.uuidString)'", in: directory))
        XCTAssertEqual(try sqliteInt("SELECT sync_dirty FROM custom_words WHERE id = '\(entry.id.uuidString)'", in: directory), 1)
    }

    func testLegacyV1SQLiteRowsMigrateIntoNormalizedColumns() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let encoder = JSONEncoder()
        let result = DictationResult(
            id: UUID(),
            requestID: UUID(),
            sessionID: UUID(),
            text: "legacy sqlite dictation",
            createdAt: Date(timeIntervalSince1970: 10),
            engineIdentifier: "parakeet-v3"
        )
        let session = RecordingSession(
            id: UUID(),
            requestID: UUID(),
            kind: .meeting,
            title: "Legacy meeting",
            createdAt: Date(timeIntervalSince1970: 20),
            startedAt: Date(timeIntervalSince1970: 19),
            phase: .completed,
            audioFileName: "legacy.wav",
            keepsAudioRecording: true,
            engineIdentifier: "parakeet-v3"
        )
        let transcript = Transcript(
            id: UUID(),
            sessionID: session.id,
            text: "legacy transcript",
            createdAt: Date(timeIntervalSince1970: 30),
            engineIdentifier: "parakeet-v3",
            summaryText: "Legacy notes",
            summaryState: .completed,
            summaryBackend: "openrouter",
            summaryModel: "gpt-5.5"
        )
        let customWord = CustomWord(
            id: UUID(),
            word: "muesli",
            replacement: "Muesli",
            matchingThreshold: 0.9,
            createdAt: Date(timeIntervalSince1970: 40)
        )

        try createLegacyV1Database(
            in: directory,
            result: (result, try encoder.encode(result)),
            session: (session, try encoder.encode(session)),
            transcript: (transcript, try encoder.encode(transcript)),
            customWord: (customWord, try encoder.encode(customWord))
        )

        let store = SharedStore(containerURL: directory)

        XCTAssertEqual(try store.resultsHistory(), [result])
        XCTAssertEqual(try store.recordingSessions(), [session])
        XCTAssertEqual(try store.transcript(for: session.id), transcript)
        XCTAssertEqual(try store.customWords(), [customWord])
        XCTAssertEqual(try sqliteInt("PRAGMA user_version", in: directory), 2)
        XCTAssertEqual(try sqliteString("SELECT text FROM result_history LIMIT 1", in: directory), "legacy sqlite dictation")
        XCTAssertEqual(try sqliteString("SELECT audio_file_name FROM recording_sessions LIMIT 1", in: directory), "legacy.wav")
        XCTAssertEqual(try sqliteString("SELECT summary_text FROM transcripts LIMIT 1", in: directory), "Legacy notes")
        XCTAssertEqual(try sqliteDouble("SELECT matching_threshold FROM custom_words LIMIT 1", in: directory), 0.9, accuracy: 0.001)
    }
}

private extension SharedStoreTests {
    func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func sqliteColumnNames(table: String, in directory: URL) throws -> Set<String> {
        Set(try sqliteStrings("PRAGMA table_info(\(table))", column: 1, in: directory))
    }

    func sqliteInt(_ sql: String, in directory: URL) throws -> Int {
        Int(try sqliteDouble(sql, in: directory))
    }

    func sqliteDouble(_ sql: String, in directory: URL) throws -> Double {
        try sqliteScalar(sql, in: directory) { statement in
            sqlite3_column_double(statement, 0)
        }
    }

    func sqliteOptionalDouble(_ sql: String, in directory: URL) throws -> Double? {
        try sqliteScalar(sql, in: directory) { statement in
            guard sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
            return sqlite3_column_double(statement, 0)
        }
    }

    func sqliteString(_ sql: String, in directory: URL) throws -> String? {
        try sqliteScalar(sql, in: directory) { statement in
            guard sqlite3_column_type(statement, 0) != SQLITE_NULL,
                  let text = sqlite3_column_text(statement, 0) else {
                return nil
            }
            return String(cString: text)
        }
    }

    func sqliteStrings(_ sql: String, column: Int32, in directory: URL) throws -> [String] {
        let database = try openSQLiteDatabase(in: directory)
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw SQLiteTestError.prepare(sqliteError(database))
        }
        defer { sqlite3_finalize(statement) }

        var rows: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, column) else { continue }
            rows.append(String(cString: text))
        }
        return rows
    }

    func sqliteScalar<T>(_ sql: String, in directory: URL, read: (OpaquePointer) throws -> T) throws -> T {
        let database = try openSQLiteDatabase(in: directory)
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw SQLiteTestError.prepare(sqliteError(database))
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw SQLiteTestError.missingRow
        }
        return try read(statement)
    }

    func openSQLiteDatabase(in directory: URL) throws -> OpaquePointer {
        var database: OpaquePointer?
        let url = directory.appendingPathComponent("Muesli.sqlite")
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let database else {
            throw SQLiteTestError.open("Could not open SQLite test database")
        }
        return database
    }

    func createLegacyV1Database(
        in directory: URL,
        result: (model: DictationResult, payload: Data),
        session: (model: RecordingSession, payload: Data),
        transcript: (model: Transcript, payload: Data),
        customWord: (model: CustomWord, payload: Data)
    ) throws {
        var database: OpaquePointer?
        let url = directory.appendingPathComponent("Muesli.sqlite")
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let database else {
            throw SQLiteTestError.open("Could not create SQLite test database")
        }
        defer { sqlite3_close(database) }

        try sqliteExec(
            """
            CREATE TABLE key_values (
                key TEXT PRIMARY KEY NOT NULL,
                payload BLOB NOT NULL,
                updated_at REAL NOT NULL
            );
            CREATE TABLE result_pickups (
                request_id TEXT PRIMARY KEY NOT NULL,
                payload BLOB NOT NULL,
                updated_at REAL NOT NULL
            );
            CREATE TABLE result_history (
                id TEXT NOT NULL,
                request_id TEXT PRIMARY KEY NOT NULL,
                created_at REAL NOT NULL,
                payload BLOB NOT NULL
            );
            CREATE TABLE recording_sessions (
                id TEXT PRIMARY KEY NOT NULL,
                request_id TEXT UNIQUE,
                kind TEXT NOT NULL,
                phase TEXT NOT NULL,
                created_at REAL NOT NULL,
                payload BLOB NOT NULL
            );
            CREATE TABLE transcripts (
                id TEXT PRIMARY KEY NOT NULL,
                session_id TEXT UNIQUE NOT NULL,
                created_at REAL NOT NULL,
                engine_identifier TEXT NOT NULL,
                payload BLOB NOT NULL
            );
            CREATE TABLE custom_words (
                id TEXT PRIMARY KEY NOT NULL,
                word TEXT NOT NULL,
                created_at REAL NOT NULL,
                is_enabled INTEGER NOT NULL,
                payload BLOB NOT NULL
            );
            PRAGMA user_version = 1;
            """,
            database
        )

        try sqliteInsertBlob(
            """
            INSERT INTO result_history (id, request_id, created_at, payload)
            VALUES (?, ?, ?, ?)
            """,
            database,
            values: [
                .text(result.model.id.uuidString),
                .text(result.model.requestID.uuidString),
                .double(result.model.createdAt.timeIntervalSince1970),
                .blob(result.payload)
            ]
        )
        try sqliteInsertBlob(
            """
            INSERT INTO recording_sessions (id, request_id, kind, phase, created_at, payload)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            database,
            values: [
                .text(session.model.id.uuidString),
                .text(session.model.requestID?.uuidString),
                .text(session.model.kind.rawValue),
                .text(session.model.phase.rawValue),
                .double(session.model.createdAt.timeIntervalSince1970),
                .blob(session.payload)
            ]
        )
        try sqliteInsertBlob(
            """
            INSERT INTO transcripts (id, session_id, created_at, engine_identifier, payload)
            VALUES (?, ?, ?, ?, ?)
            """,
            database,
            values: [
                .text(transcript.model.id.uuidString),
                .text(transcript.model.sessionID.uuidString),
                .double(transcript.model.createdAt.timeIntervalSince1970),
                .text(transcript.model.engineIdentifier),
                .blob(transcript.payload)
            ]
        )
        try sqliteInsertBlob(
            """
            INSERT INTO custom_words (id, word, created_at, is_enabled, payload)
            VALUES (?, ?, ?, ?, ?)
            """,
            database,
            values: [
                .text(customWord.model.id.uuidString),
                .text(customWord.model.word),
                .double(customWord.model.createdAt.timeIntervalSince1970),
                .int(customWord.model.isEnabled ? 1 : 0),
                .blob(customWord.payload)
            ]
        )
    }

    func sqliteExec(_ sql: String, _ database: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? sqliteError(database)
            sqlite3_free(errorMessage)
            throw SQLiteTestError.exec(message)
        }
    }

    func sqliteInsertBlob(_ sql: String, _ database: OpaquePointer, values: [SQLiteValue]) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw SQLiteTestError.prepare(sqliteError(database))
        }
        defer { sqlite3_finalize(statement) }

        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            let result: Int32
            switch value {
            case .text(let string):
                if let string {
                    result = sqlite3_bind_text(statement, position, string, -1, sqliteTransient)
                } else {
                    result = sqlite3_bind_null(statement, position)
                }
            case .double(let double):
                result = sqlite3_bind_double(statement, position, double)
            case .int(let int):
                result = sqlite3_bind_int64(statement, position, sqlite3_int64(int))
            case .blob(let data):
                result = data.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, position, buffer.baseAddress, Int32(data.count), sqliteTransient)
                }
            }
            guard result == SQLITE_OK else {
                throw SQLiteTestError.bind(sqliteError(database))
            }
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteTestError.exec(sqliteError(database))
        }
    }

    func sqliteError(_ database: OpaquePointer) -> String {
        sqlite3_errmsg(database).map { String(cString: $0) } ?? "unknown SQLite error"
    }
}

private enum SQLiteValue {
    case text(String?)
    case double(Double)
    case int(Int)
    case blob(Data)
}

private enum SQLiteTestError: Error {
    case open(String)
    case prepare(String)
    case bind(String)
    case exec(String)
    case missingRow
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
