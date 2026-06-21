import Foundation
import SQLite3

enum SharedStoreError: Error, LocalizedError {
    case appGroupUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable(let identifier):
            "App Group container is unavailable for \(identifier)."
        }
    }
}

struct SharedStore: Sendable {
    private let appGroupIdentifier: String
    private let overrideContainerURL: URL?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        appGroupIdentifier: String = MuesliAppConstants.appGroupIdentifier,
        containerURL: URL? = nil
    ) {
        self.appGroupIdentifier = appGroupIdentifier
        self.overrideContainerURL = containerURL
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    func saveRequest(_ request: DictationRequest) throws {
        try database().saveValue(request, key: .pendingRequest)
    }

    func pendingRequest() throws -> DictationRequest? {
        try database().value(DictationRequest.self, key: .pendingRequest)
    }

    func clearPendingRequest() throws {
        try database().clearValue(key: .pendingRequest)
    }

    func saveCommand(_ command: DictationCommand) throws {
        try database().saveValue(command, key: .pendingCommand)
    }

    func pendingCommand() throws -> DictationCommand? {
        try database().value(DictationCommand.self, key: .pendingCommand)
    }

    func clearPendingCommand() throws {
        try database().clearValue(key: .pendingCommand)
    }

    func saveKeyboardHandoffState(_ state: KeyboardHandoffState) throws {
        try database().saveValue(state, key: .keyboardHandoffState)
    }

    func keyboardHandoffState() throws -> KeyboardHandoffState {
        try database().value(KeyboardHandoffState.self, key: .keyboardHandoffState) ?? .idle
    }

    func clearKeyboardHandoffState() throws {
        try database().clearValue(key: .keyboardHandoffState)
    }

    func saveStatus(_ status: DictationStatus) throws {
        try database().saveValue(status, key: .dictationStatus)
    }

    func status() throws -> DictationStatus {
        try database().value(DictationStatus.self, key: .dictationStatus) ?? .idle
    }

    func saveResult(_ result: DictationResult) throws {
        try database().saveResult(result)
    }

    func result(for requestID: UUID) throws -> DictationResult? {
        try database().result(for: requestID)
    }

    func resultsHistory() throws -> [DictationResult] {
        try database().resultsHistory()
    }

    func deleteResult(_ result: DictationResult) throws {
        try database().deleteResult(id: result.id, requestID: result.requestID)
    }

    func clearResult(for requestID: UUID) throws {
        try database().clearResult(for: requestID)
    }

    func saveKeyboardExtensionStatus(_ status: KeyboardExtensionStatus) throws {
        try database().saveValue(status, key: .keyboardExtensionStatus)
    }

    func keyboardExtensionStatus() throws -> KeyboardExtensionStatus? {
        try database().value(KeyboardExtensionStatus.self, key: .keyboardExtensionStatus)
    }

    func saveKeyboardRuntimeStatus(_ status: KeyboardRuntimeStatus) throws {
        try database().saveValue(status, key: .keyboardRuntimeStatus)
    }

    func keyboardRuntimeStatus() throws -> KeyboardRuntimeStatus? {
        try database().value(KeyboardRuntimeStatus.self, key: .keyboardRuntimeStatus)
    }

    func clearKeyboardRuntimeStatus() throws {
        try database().clearValue(key: .keyboardRuntimeStatus)
    }

    func saveKeyboardLiveTranscript(_ transcript: KeyboardLiveTranscript) throws {
        try database().saveValue(transcript, key: .keyboardLiveTranscript)
    }

    func keyboardLiveTranscript() throws -> KeyboardLiveTranscript? {
        try database().value(KeyboardLiveTranscript.self, key: .keyboardLiveTranscript)
    }

    func clearKeyboardLiveTranscript() throws {
        try database().clearValue(key: .keyboardLiveTranscript)
    }

    func saveSession(_ session: RecordingSession) throws {
        try database().saveSession(session)
    }

    func recordingSessions() throws -> [RecordingSession] {
        try database().recordingSessions()
    }

    func recordingSession(id: UUID) throws -> RecordingSession? {
        try database().recordingSession(id: id)
    }

    func recordingSession(requestID: UUID) throws -> RecordingSession? {
        try database().recordingSession(requestID: requestID)
    }

    func deleteRecordingSession(id: UUID) throws {
        try database().deleteRecordingSession(id: id)
    }

    func saveTranscript(_ transcript: Transcript) throws {
        try database().saveTranscript(transcript)
    }

    func transcripts() throws -> [Transcript] {
        try database().transcripts()
    }

    func transcript(for sessionID: UUID) throws -> Transcript? {
        try database().transcript(for: sessionID)
    }

    func deleteTranscript(for sessionID: UUID) throws {
        try database().deleteTranscript(for: sessionID)
    }

    func customWords() throws -> [CustomWord] {
        try database().customWords()
    }

    func saveCustomWords(_ customWords: [CustomWord]) throws {
        try database().saveCustomWords(customWords)
    }

    func addCustomWord(_ customWord: CustomWord) throws {
        try database().addCustomWord(customWord)
    }

    func updateCustomWord(_ customWord: CustomWord) throws {
        try database().updateCustomWord(customWord)
    }

    func removeCustomWord(id: UUID) throws {
        try database().removeCustomWord(id: id)
    }

    func textRecordsNeedingSync(limit: Int = 200) throws -> [SyncTextRecord] {
        try database().textRecordsNeedingSync(limit: limit)
    }

    func textRecordsForSyncMigration(limit: Int = 5_000) throws -> [SyncTextRecord] {
        try database().textRecordsForSyncMigration(limit: limit)
    }

    func upsertSyncedTextRecord(_ record: SyncTextRecord) throws {
        try database().upsertSyncedTextRecord(record)
    }

    func markTextRecordSynced(kind: SyncTextRecordKind, recordName: String, changeTag: String?) throws {
        try database().markTextRecordSynced(kind: kind, recordName: recordName, changeTag: changeTag)
    }

    func newAudioFileURL(sessionID: UUID) throws -> URL {
        let fileName = audioFileName(sessionID: sessionID)
        return try audioFileURL(fileName: fileName)
    }

    func newDictationAudioFileURL(startedAt: Date) throws -> URL {
        let fileName = audioFileName(prefix: "dictation", date: startedAt)
        return try uniqueAudioFileURL(fileName: fileName)
    }

    func audioFileURL(fileName: String) throws -> URL {
        let directory = try recordingsDirectoryURL()
        return directory.appendingPathComponent(fileName)
    }

    func deleteAudioFile(fileName: String) throws {
        let url = try audioFileURL(fileName: fileName)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try? deleteExportedAudioFile(fileName: fileName)
    }

    @discardableResult
    func exportAudioFileToDocuments(fileName: String) throws -> URL {
        let sourceURL = try audioFileURL(fileName: fileName)
        let destinationURL = try exportedRecordingsDirectoryURL().appendingPathComponent(fileName)

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    func audioFileName(sessionID: UUID) -> String {
        "session-\(sessionID.uuidString).wav"
    }

    func audioFileName(prefix: String, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(prefix)-\(formatter.string(from: date)).wav"
    }

    private func uniqueAudioFileURL(fileName: String) throws -> URL {
        let directory = try recordingsDirectoryURL()
        let proposedURL = directory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: proposedURL.path) else {
            return proposedURL
        }

        let baseName = proposedURL.deletingPathExtension().lastPathComponent
        let pathExtension = proposedURL.pathExtension
        for suffix in 1...999 {
            let candidateName = "\(baseName)-\(suffix).\(pathExtension)"
            let candidateURL = directory.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }
        }

        return directory.appendingPathComponent("\(baseName)-\(UUID().uuidString).\(pathExtension)")
    }

    private func database() throws -> SharedStoreDatabase {
        try SharedStoreDatabase(containerURL: containerURL(), encoder: encoder, decoder: decoder)
    }

    private func recordingsDirectoryURL() throws -> URL {
        let directory = try containerURL().appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func exportedRecordingsDirectoryURL() throws -> URL {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw SharedStoreError.appGroupUnavailable("Documents")
        }

        let directory = documentsURL.appendingPathComponent("Muesli Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func deleteExportedAudioFile(fileName: String) throws {
        let url = try exportedRecordingsDirectoryURL().appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func containerURL() throws -> URL {
        if let overrideContainerURL {
            try FileManager.default.createDirectory(at: overrideContainerURL, withIntermediateDirectories: true)
            return overrideContainerURL
        }

        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            throw SharedStoreError.appGroupUnavailable(appGroupIdentifier)
        }
        return url
    }
}

private enum SharedStoreKey: String {
    case pendingRequest = "pending_request"
    case pendingCommand = "pending_command"
    case keyboardHandoffState = "keyboard_handoff_state"
    case dictationStatus = "dictation_status"
    case keyboardExtensionStatus = "keyboard_extension_status"
    case keyboardRuntimeStatus = "keyboard_runtime_status"
    case keyboardLiveTranscript = "keyboard_live_transcript"
    case legacyJSONMigrated = "legacy_json_migrated_v1"
    case customWordsInitialized = "custom_words_initialized"
}

private enum SharedStoreDatabaseError: Error, LocalizedError {
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case bindFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let message):
            "Could not open Muesli data store: \(message)"
        case .prepareFailed(let message):
            "Could not prepare Muesli data query: \(message)"
        case .stepFailed(let message):
            "Could not update Muesli data store: \(message)"
        case .bindFailed(let message):
            "Could not bind Muesli data query: \(message)"
        }
    }
}

private struct SharedStoreDatabase {
    private static let databaseFileName = "Muesli.sqlite"
    private static let schemaVersion = 2

    private static let initializationLock = NSLock()
    nonisolated(unsafe) private static var initializedDatabasePaths: Set<String> = []

    private let containerURL: URL
    private let databaseURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(containerURL: URL, encoder: JSONEncoder, decoder: JSONDecoder) {
        self.containerURL = containerURL
        self.databaseURL = containerURL.appendingPathComponent(Self.databaseFileName)
        self.encoder = encoder
        self.decoder = decoder
    }

    func saveValue<T: Encodable>(_ value: T, key: SharedStoreKey) throws {
        let data = try encoder.encode(value)
        try withDatabase { db in
            try upsertValue(data, key: key, db: db)
        }
    }

    func value<T: Decodable>(_ type: T.Type, key: SharedStoreKey) throws -> T? {
        try withDatabase { db in
            guard let data = try valueData(key: key, db: db) else { return nil }
            return try decoder.decode(T.self, from: data)
        }
    }

    func clearValue(key: SharedStoreKey) throws {
        try withDatabase { db in
            try execute("DELETE FROM key_values WHERE key = ?", db: db) { statement in
                try bind(key.rawValue, to: statement, at: 1)
            }
        }
    }

    func saveResult(_ result: DictationResult) throws {
        try withDatabase { db in
            try transaction(db: db) {
                try upsertResultPickup(result, db: db)
                try upsertResultHistory(result, db: db)
                let status = DictationStatus(requestID: result.requestID, phase: .finished)
                try upsertValue(try encoder.encode(status), key: .dictationStatus, db: db)
            }
        }
    }

    func result(for requestID: UUID) throws -> DictationResult? {
        try withDatabase { db in
            try querySingleBlob(
                "SELECT payload FROM result_pickups WHERE request_id = ? LIMIT 1",
                db: db
            ) { statement in
                try bind(requestID.uuidString, to: statement, at: 1)
            }.map { try decoder.decode(DictationResult.self, from: $0) }
        }
    }

    func resultsHistory() throws -> [DictationResult] {
        try withDatabase { db in
            try queryBlobs(
                "SELECT payload FROM result_history WHERE deleted_at IS NULL ORDER BY created_at DESC",
                db: db
            ) { _ in }.map { try decoder.decode(DictationResult.self, from: $0) }
        }
    }

    func deleteResult(id: UUID, requestID: UUID) throws {
        try withDatabase { db in
            try transaction(db: db) {
                let now = Date().timeIntervalSince1970
                try execute(
                    """
                    UPDATE result_history
                    SET deleted_at = ?, updated_at = ?, sync_dirty = 1
                    WHERE id = ? OR request_id = ?
                    """,
                    db: db
                ) { statement in
                    try bind(now, to: statement, at: 1)
                    try bind(now, to: statement, at: 2)
                    try bind(id.uuidString, to: statement, at: 3)
                    try bind(requestID.uuidString, to: statement, at: 4)
                }

                try execute(
                    "DELETE FROM result_pickups WHERE request_id = ?",
                    db: db
                ) { statement in
                    try bind(requestID.uuidString, to: statement, at: 1)
                }
            }
        }
    }

    func clearResult(for requestID: UUID) throws {
        try withDatabase { db in
            try execute("DELETE FROM result_pickups WHERE request_id = ?", db: db) { statement in
                try bind(requestID.uuidString, to: statement, at: 1)
            }
        }
    }

    func saveSession(_ session: RecordingSession) throws {
        try withDatabase { db in
            try transaction(db: db) {
                try upsertSession(session, db: db)
            }
        }
    }

    func recordingSessions() throws -> [RecordingSession] {
        try withDatabase { db in
            try queryBlobs(
                "SELECT payload FROM recording_sessions WHERE deleted_at IS NULL ORDER BY created_at DESC",
                db: db
            ) { _ in }.map { try decoder.decode(RecordingSession.self, from: $0) }
        }
    }

    func recordingSession(id: UUID) throws -> RecordingSession? {
        try withDatabase { db in
            try querySingleBlob(
                "SELECT payload FROM recording_sessions WHERE id = ? LIMIT 1",
                db: db
            ) { statement in
                try bind(id.uuidString, to: statement, at: 1)
            }.map { try decoder.decode(RecordingSession.self, from: $0) }
        }
    }

    func recordingSession(requestID: UUID) throws -> RecordingSession? {
        try withDatabase { db in
            try querySingleBlob(
                "SELECT payload FROM recording_sessions WHERE request_id = ? LIMIT 1",
                db: db
            ) { statement in
                try bind(requestID.uuidString, to: statement, at: 1)
            }.map { try decoder.decode(RecordingSession.self, from: $0) }
        }
    }

    func deleteRecordingSession(id: UUID) throws {
        try withDatabase { db in
            try transaction(db: db) {
                let now = Date().timeIntervalSince1970
                try execute(
                    """
                    UPDATE recording_sessions
                    SET deleted_at = ?, updated_at = ?, sync_dirty = 1
                    WHERE id = ?
                    """,
                    db: db
                ) { statement in
                    try bind(now, to: statement, at: 1)
                    try bind(now, to: statement, at: 2)
                    try bind(id.uuidString, to: statement, at: 3)
                }
            }
        }
    }

    func saveTranscript(_ transcript: Transcript) throws {
        try withDatabase { db in
            try transaction(db: db) {
                try execute("DELETE FROM transcripts WHERE id = ? OR session_id = ?", db: db) { statement in
                    try bind(transcript.id.uuidString, to: statement, at: 1)
                    try bind(transcript.sessionID.uuidString, to: statement, at: 2)
                }
                try insertTranscript(transcript, db: db)
            }
        }
    }

    func transcripts() throws -> [Transcript] {
        try withDatabase { db in
            try queryBlobs(
                "SELECT payload FROM transcripts WHERE deleted_at IS NULL ORDER BY created_at DESC",
                db: db
            ) { _ in }
                .map { try decoder.decode(Transcript.self, from: $0) }
        }
    }

    func transcript(for sessionID: UUID) throws -> Transcript? {
        try withDatabase { db in
            try querySingleBlob(
                "SELECT payload FROM transcripts WHERE session_id = ? AND deleted_at IS NULL LIMIT 1",
                db: db
            ) { statement in
                try bind(sessionID.uuidString, to: statement, at: 1)
            }.map { try decoder.decode(Transcript.self, from: $0) }
        }
    }

    func deleteTranscript(for sessionID: UUID) throws {
        try withDatabase { db in
            try transaction(db: db) {
                let now = Date().timeIntervalSince1970
                try execute(
                    """
                    UPDATE transcripts
                    SET deleted_at = ?, updated_at = ?, sync_dirty = 1
                    WHERE session_id = ?
                    """,
                    db: db
                ) { statement in
                    try bind(now, to: statement, at: 1)
                    try bind(now, to: statement, at: 2)
                    try bind(sessionID.uuidString, to: statement, at: 3)
                }
            }
        }
    }

    func customWords() throws -> [CustomWord] {
        try withDatabase { db in
            let rows = try queryBlobs(
                "SELECT payload FROM custom_words WHERE deleted_at IS NULL ORDER BY created_at DESC",
                db: db
            ) { _ in }
                .map { try decoder.decode(CustomWord.self, from: $0) }
            if rows.isEmpty, try valueData(key: .customWordsInitialized, db: db) == nil {
                return [CustomWord(word: "muesli", replacement: "muesli")]
            }
            return rows
        }
    }

    func saveCustomWords(_ customWords: [CustomWord]) throws {
        try withDatabase { db in
            try transaction(db: db) {
                try softDeleteVisibleCustomWords(db: db)
                for customWord in customWords {
                    try insertCustomWord(customWord, db: db)
                }
                try upsertValue(try encoder.encode(true), key: .customWordsInitialized, db: db)
            }
        }
    }

    func addCustomWord(_ customWord: CustomWord) throws {
        try withDatabase { db in
            try transaction(db: db) {
                try insertCustomWord(customWord, db: db)
                try upsertValue(try encoder.encode(true), key: .customWordsInitialized, db: db)
            }
        }
    }

    func updateCustomWord(_ customWord: CustomWord) throws {
        try addCustomWord(customWord)
    }

    func removeCustomWord(id: UUID) throws {
        try withDatabase { db in
            try transaction(db: db) {
                let now = Date().timeIntervalSince1970
                try execute(
                    """
                    UPDATE custom_words
                    SET deleted_at = ?, updated_at = ?, sync_dirty = 1
                    WHERE id = ?
                    """,
                    db: db
                ) { statement in
                    try bind(now, to: statement, at: 1)
                    try bind(now, to: statement, at: 2)
                    try bind(id.uuidString, to: statement, at: 3)
                }
                try upsertValue(try encoder.encode(true), key: .customWordsInitialized, db: db)
            }
        }
    }

    func textRecordsNeedingSync(limit: Int = 200) throws -> [SyncTextRecord] {
        try withDatabase { db in
            var records: [SyncTextRecord] = []
            let dictationRows = try queryRows(
                """
                SELECT cloud_record_name, text, engine_identifier, created_at, updated_at,
                       deleted_at, session_id, cloud_change_tag
                FROM result_history
                WHERE sync_dirty = 1 AND cloud_record_name IS NOT NULL
                ORDER BY updated_at DESC
                LIMIT ?
                """,
                db: db
            ) { statement in
                try bind(limit, to: statement, at: 1)
            } read: { statement in
                SyncTextRecord(
                    id: sqliteColumnString(statement, 0) ?? UUID().uuidString,
                    kind: .dictation,
                    title: nil,
                    text: sqliteColumnString(statement, 1) ?? "",
                    speakerTranscript: nil,
                    summaryText: nil,
                    manualNotes: nil,
                    source: "ios",
                    engineIdentifier: sqliteColumnString(statement, 2),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                    updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                    startedAt: nil,
                    endedAt: nil,
                    durationSeconds: 0,
                    wordCount: Self.wordCount(sqliteColumnString(statement, 1) ?? ""),
                    isDeleted: sqlite3_column_type(statement, 5) != SQLITE_NULL,
                    cloudChangeTag: sqliteColumnString(statement, 7)
                )
            }
            records.append(contentsOf: dictationRows)

            let remaining = max(limit - records.count, 0)
            guard remaining > 0 else { return records }

            let meetingRows = try queryRows(
                """
                SELECT s.cloud_record_name, s.id, s.title, s.kind, s.phase, s.created_at,
                       s.started_at, s.ended_at, s.engine_identifier, s.error_message,
                       s.updated_at, s.deleted_at, s.cloud_change_tag,
                       t.text, t.speaker_transcript, t.summary_text, t.summary_backend,
                       t.summary_model, t.updated_at, t.deleted_at
                FROM recording_sessions s
                LEFT JOIN transcripts t ON t.session_id = s.id
                WHERE (s.sync_dirty = 1 OR t.sync_dirty = 1)
                  AND s.cloud_record_name IS NOT NULL
                  AND s.kind = ?
                ORDER BY MAX(s.updated_at, COALESCE(t.updated_at, 0)) DESC
                LIMIT ?
                """,
                db: db
            ) { statement in
                try bind(RecordingSessionKind.meeting.rawValue, to: statement, at: 1)
                try bind(remaining, to: statement, at: 2)
            } read: { statement in
                let started = Self.optionalDate(statement, 6)
                let ended = Self.optionalDate(statement, 7)
                let text = sqliteColumnString(statement, 13) ?? ""
                let summary = sqliteColumnString(statement, 15)
                let updated = max(sqlite3_column_double(statement, 10), sqlite3_column_double(statement, 18))
                return SyncTextRecord(
                    id: sqliteColumnString(statement, 0) ?? UUID().uuidString,
                    kind: .meeting,
                    title: sqliteColumnString(statement, 2),
                    text: text,
                    speakerTranscript: sqliteColumnString(statement, 14),
                    summaryText: summary,
                    manualNotes: nil,
                    source: "ios",
                    engineIdentifier: sqliteColumnString(statement, 8),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                    updatedAt: Date(timeIntervalSince1970: updated),
                    startedAt: started,
                    endedAt: ended,
                    durationSeconds: started.map { (ended ?? Date()).timeIntervalSince($0) } ?? 0,
                    wordCount: Self.wordCount(text + " " + (summary ?? "")),
                    isDeleted: sqlite3_column_type(statement, 11) != SQLITE_NULL || sqlite3_column_type(statement, 19) != SQLITE_NULL,
                    cloudChangeTag: sqliteColumnString(statement, 12)
                )
            }
            records.append(contentsOf: meetingRows)
            return records
        }
    }

    func textRecordsForSyncMigration(limit: Int = 5_000) throws -> [SyncTextRecord] {
        try withDatabase { db in
            var records: [SyncTextRecord] = []
            let dictationRows = try queryRows(
                """
                SELECT cloud_record_name, text, engine_identifier, created_at, updated_at,
                       deleted_at, session_id, cloud_change_tag
                FROM result_history
                WHERE cloud_record_name IS NOT NULL
                ORDER BY updated_at DESC
                LIMIT ?
                """,
                db: db
            ) { statement in
                try bind(limit, to: statement, at: 1)
            } read: { statement in
                SyncTextRecord(
                    id: sqliteColumnString(statement, 0) ?? UUID().uuidString,
                    kind: .dictation,
                    title: nil,
                    text: sqliteColumnString(statement, 1) ?? "",
                    speakerTranscript: nil,
                    summaryText: nil,
                    manualNotes: nil,
                    source: "ios",
                    engineIdentifier: sqliteColumnString(statement, 2),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                    updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                    startedAt: nil,
                    endedAt: nil,
                    durationSeconds: 0,
                    wordCount: Self.wordCount(sqliteColumnString(statement, 1) ?? ""),
                    isDeleted: sqlite3_column_type(statement, 5) != SQLITE_NULL,
                    cloudChangeTag: sqliteColumnString(statement, 7)
                )
            }
            records.append(contentsOf: dictationRows)

            let remaining = max(limit - records.count, 0)
            guard remaining > 0 else { return records }

            let meetingRows = try queryRows(
                """
                SELECT s.cloud_record_name, s.id, s.title, s.kind, s.phase, s.created_at,
                       s.started_at, s.ended_at, s.engine_identifier, s.error_message,
                       s.updated_at, s.deleted_at, s.cloud_change_tag,
                       t.text, t.speaker_transcript, t.summary_text, t.summary_backend,
                       t.summary_model, t.updated_at, t.deleted_at
                FROM recording_sessions s
                LEFT JOIN transcripts t ON t.session_id = s.id
                WHERE s.cloud_record_name IS NOT NULL
                  AND s.kind = ?
                ORDER BY MAX(s.updated_at, COALESCE(t.updated_at, 0)) DESC
                LIMIT ?
                """,
                db: db
            ) { statement in
                try bind(RecordingSessionKind.meeting.rawValue, to: statement, at: 1)
                try bind(remaining, to: statement, at: 2)
            } read: { statement in
                let started = Self.optionalDate(statement, 6)
                let ended = Self.optionalDate(statement, 7)
                let text = sqliteColumnString(statement, 13) ?? ""
                let summary = sqliteColumnString(statement, 15)
                let updated = max(sqlite3_column_double(statement, 10), sqlite3_column_double(statement, 18))
                return SyncTextRecord(
                    id: sqliteColumnString(statement, 0) ?? UUID().uuidString,
                    kind: .meeting,
                    title: sqliteColumnString(statement, 2),
                    text: text,
                    speakerTranscript: sqliteColumnString(statement, 14),
                    summaryText: summary,
                    manualNotes: nil,
                    source: "ios",
                    engineIdentifier: sqliteColumnString(statement, 8),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                    updatedAt: Date(timeIntervalSince1970: updated),
                    startedAt: started,
                    endedAt: ended,
                    durationSeconds: started.map { (ended ?? Date()).timeIntervalSince($0) } ?? 0,
                    wordCount: Self.wordCount(text + " " + (summary ?? "")),
                    isDeleted: sqlite3_column_type(statement, 11) != SQLITE_NULL || sqlite3_column_type(statement, 19) != SQLITE_NULL,
                    cloudChangeTag: sqliteColumnString(statement, 12)
                )
            }
            records.append(contentsOf: meetingRows)
            return records
        }
    }

    func upsertSyncedTextRecord(_ record: SyncTextRecord) throws {
        try withDatabase { db in
            switch record.kind {
            case .dictation:
                try upsertSyncedDictation(record, db: db)
            case .meeting:
                try upsertSyncedMeeting(record, db: db)
            }
        }
    }

    func markTextRecordSynced(kind: SyncTextRecordKind, recordName: String, changeTag: String?) throws {
        try withDatabase { db in
            let now = Date().timeIntervalSince1970
            let table = kind == .dictation ? "result_history" : "recording_sessions"
            try execute(
                """
                UPDATE \(table)
                SET cloud_change_tag = ?, last_synced_at = ?, sync_dirty = 0
                WHERE cloud_record_name = ?
                """,
                db: db
            ) { statement in
                try bind(changeTag, to: statement, at: 1)
                try bind(now, to: statement, at: 2)
                try bind(recordName, to: statement, at: 3)
            }
            if kind == .meeting {
                try execute(
                    """
                    UPDATE transcripts
                    SET last_synced_at = ?, sync_dirty = 0
                    WHERE session_id IN (
                        SELECT id FROM recording_sessions WHERE cloud_record_name = ?
                    )
                    """,
                    db: db
                ) { statement in
                    try bind(now, to: statement, at: 1)
                    try bind(recordName, to: statement, at: 2)
                }
            }
        }
    }

    private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK,
              let database else {
            let message = database.map { sqlite3ErrorMessage($0) } ?? "unknown error"
            if let database {
                sqlite3_close(database)
            }
            throw SharedStoreDatabaseError.openFailed(message)
        }
        defer { sqlite3_close(database) }

        try configure(database)
        try ensureInitialized(database)

        return try body(database)
    }

    private func configure(_ db: OpaquePointer) throws {
        try exec("PRAGMA busy_timeout = 5000", db: db)
        try exec("PRAGMA journal_mode = WAL", db: db)
        try exec("PRAGMA synchronous = NORMAL", db: db)
        try exec("PRAGMA foreign_keys = ON", db: db)
    }

    private func ensureInitialized(_ db: OpaquePointer) throws {
        Self.initializationLock.lock()
        let didInitialize = Self.initializedDatabasePaths.contains(databaseURL.path)
        Self.initializationLock.unlock()
        guard !didInitialize else { return }

        try exec(Self.schemaSQL, db: db)
        try migrateSchemaIfNeeded(db)
        try migrateLegacyJSONIfNeeded(db)
        try backfillNormalizedColumns(db)
        try setUserVersion(Self.schemaVersion, db: db)

        Self.initializationLock.lock()
        Self.initializedDatabasePaths.insert(databaseURL.path)
        Self.initializationLock.unlock()
    }

    private func migrateSchemaIfNeeded(_ db: OpaquePointer) throws {
        _ = try userVersion(db)

        let migrations: [(table: String, column: String, sql: String)] = [
            ("result_history", "session_id", "ALTER TABLE result_history ADD COLUMN session_id TEXT"),
            ("result_history", "text", "ALTER TABLE result_history ADD COLUMN text TEXT NOT NULL DEFAULT ''"),
            ("result_history", "engine_identifier", "ALTER TABLE result_history ADD COLUMN engine_identifier TEXT NOT NULL DEFAULT ''"),
            ("result_history", "updated_at", "ALTER TABLE result_history ADD COLUMN updated_at REAL NOT NULL DEFAULT 0"),
            ("result_history", "deleted_at", "ALTER TABLE result_history ADD COLUMN deleted_at REAL"),
            ("result_history", "cloud_record_name", "ALTER TABLE result_history ADD COLUMN cloud_record_name TEXT"),
            ("result_history", "cloud_change_tag", "ALTER TABLE result_history ADD COLUMN cloud_change_tag TEXT"),
            ("result_history", "last_synced_at", "ALTER TABLE result_history ADD COLUMN last_synced_at REAL"),
            ("result_history", "sync_dirty", "ALTER TABLE result_history ADD COLUMN sync_dirty INTEGER NOT NULL DEFAULT 1"),

            ("recording_sessions", "title", "ALTER TABLE recording_sessions ADD COLUMN title TEXT"),
            ("recording_sessions", "started_at", "ALTER TABLE recording_sessions ADD COLUMN started_at REAL"),
            ("recording_sessions", "ended_at", "ALTER TABLE recording_sessions ADD COLUMN ended_at REAL"),
            ("recording_sessions", "audio_file_name", "ALTER TABLE recording_sessions ADD COLUMN audio_file_name TEXT"),
            ("recording_sessions", "keeps_audio_recording", "ALTER TABLE recording_sessions ADD COLUMN keeps_audio_recording INTEGER NOT NULL DEFAULT 0"),
            ("recording_sessions", "transcript_id", "ALTER TABLE recording_sessions ADD COLUMN transcript_id TEXT"),
            ("recording_sessions", "engine_identifier", "ALTER TABLE recording_sessions ADD COLUMN engine_identifier TEXT"),
            ("recording_sessions", "error_message", "ALTER TABLE recording_sessions ADD COLUMN error_message TEXT"),
            ("recording_sessions", "updated_at", "ALTER TABLE recording_sessions ADD COLUMN updated_at REAL NOT NULL DEFAULT 0"),
            ("recording_sessions", "deleted_at", "ALTER TABLE recording_sessions ADD COLUMN deleted_at REAL"),
            ("recording_sessions", "cloud_record_name", "ALTER TABLE recording_sessions ADD COLUMN cloud_record_name TEXT"),
            ("recording_sessions", "cloud_change_tag", "ALTER TABLE recording_sessions ADD COLUMN cloud_change_tag TEXT"),
            ("recording_sessions", "last_synced_at", "ALTER TABLE recording_sessions ADD COLUMN last_synced_at REAL"),
            ("recording_sessions", "sync_dirty", "ALTER TABLE recording_sessions ADD COLUMN sync_dirty INTEGER NOT NULL DEFAULT 1"),

            ("transcripts", "text", "ALTER TABLE transcripts ADD COLUMN text TEXT NOT NULL DEFAULT ''"),
            ("transcripts", "speaker_transcript", "ALTER TABLE transcripts ADD COLUMN speaker_transcript TEXT"),
            ("transcripts", "summary_text", "ALTER TABLE transcripts ADD COLUMN summary_text TEXT"),
            ("transcripts", "diarization_state", "ALTER TABLE transcripts ADD COLUMN diarization_state TEXT NOT NULL DEFAULT 'notStarted'"),
            ("transcripts", "diarization_error_message", "ALTER TABLE transcripts ADD COLUMN diarization_error_message TEXT"),
            ("transcripts", "summary_state", "ALTER TABLE transcripts ADD COLUMN summary_state TEXT NOT NULL DEFAULT 'notStarted'"),
            ("transcripts", "summary_backend", "ALTER TABLE transcripts ADD COLUMN summary_backend TEXT"),
            ("transcripts", "summary_model", "ALTER TABLE transcripts ADD COLUMN summary_model TEXT"),
            ("transcripts", "summary_error_message", "ALTER TABLE transcripts ADD COLUMN summary_error_message TEXT"),
            ("transcripts", "updated_at", "ALTER TABLE transcripts ADD COLUMN updated_at REAL NOT NULL DEFAULT 0"),
            ("transcripts", "deleted_at", "ALTER TABLE transcripts ADD COLUMN deleted_at REAL"),
            ("transcripts", "cloud_record_name", "ALTER TABLE transcripts ADD COLUMN cloud_record_name TEXT"),
            ("transcripts", "cloud_change_tag", "ALTER TABLE transcripts ADD COLUMN cloud_change_tag TEXT"),
            ("transcripts", "last_synced_at", "ALTER TABLE transcripts ADD COLUMN last_synced_at REAL"),
            ("transcripts", "sync_dirty", "ALTER TABLE transcripts ADD COLUMN sync_dirty INTEGER NOT NULL DEFAULT 1"),

            ("custom_words", "replacement", "ALTER TABLE custom_words ADD COLUMN replacement TEXT"),
            ("custom_words", "matching_threshold", "ALTER TABLE custom_words ADD COLUMN matching_threshold REAL NOT NULL DEFAULT 0.85"),
            ("custom_words", "updated_at", "ALTER TABLE custom_words ADD COLUMN updated_at REAL NOT NULL DEFAULT 0"),
            ("custom_words", "deleted_at", "ALTER TABLE custom_words ADD COLUMN deleted_at REAL"),
            ("custom_words", "cloud_record_name", "ALTER TABLE custom_words ADD COLUMN cloud_record_name TEXT"),
            ("custom_words", "cloud_change_tag", "ALTER TABLE custom_words ADD COLUMN cloud_change_tag TEXT"),
            ("custom_words", "last_synced_at", "ALTER TABLE custom_words ADD COLUMN last_synced_at REAL"),
            ("custom_words", "sync_dirty", "ALTER TABLE custom_words ADD COLUMN sync_dirty INTEGER NOT NULL DEFAULT 1")
        ]

        var columnCache: [String: Set<String>] = [:]
        for migration in migrations {
            let columns = try columnCache[migration.table] ?? tableColumns(migration.table, db: db)
            columnCache[migration.table] = columns
            if !columns.contains(migration.column) {
                try exec(migration.sql, db: db)
                columnCache[migration.table]?.insert(migration.column)
            }
        }

        try ensureSyncIndexes(db)
    }

    private func ensureSyncIndexes(_ db: OpaquePointer) throws {
        try exec(
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_result_history_cloud_record_name ON result_history(cloud_record_name)",
            db: db
        )
        try exec(
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_recording_sessions_cloud_record_name ON recording_sessions(cloud_record_name)",
            db: db
        )
        try exec(
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_transcripts_cloud_record_name ON transcripts(cloud_record_name)",
            db: db
        )
    }

    private func tableColumns(_ table: String, db: OpaquePointer) throws -> Set<String> {
        var columns: Set<String> = []
        try forEachRow("PRAGMA table_info(\(table))", db: db) { statement in
            if let name = sqliteColumnString(statement, 1) {
                columns.insert(name)
            }
        }
        return columns
    }

    private func backfillNormalizedColumns(_ db: OpaquePointer) throws {
        try backfillResults(db)
        try backfillSessions(db)
        try backfillTranscripts(db)
        try backfillCustomWords(db)
    }

    private func backfillResults(_ db: OpaquePointer) throws {
        try forEachRow("SELECT request_id, id, created_at, payload FROM result_history", db: db) { statement in
            let requestID = sqliteColumnString(statement, 0)
            let fallbackID = sqliteColumnString(statement, 1)
            let fallbackCreatedAt = sqlite3_column_double(statement, 2)
            let payload = sqliteColumnData(statement, 3)
            let result = payload.flatMap { try? decoder.decode(DictationResult.self, from: $0) }
            let id = result?.id.uuidString ?? fallbackID ?? requestID
            let createdAt = result?.createdAt.timeIntervalSince1970 ?? fallbackCreatedAt
            try execute(
                """
                UPDATE result_history
                SET id = COALESCE(NULLIF(id, ''), ?),
                    session_id = COALESCE(session_id, ?),
                    text = CASE WHEN text = '' THEN ? ELSE text END,
                    engine_identifier = CASE WHEN engine_identifier = '' THEN ? ELSE engine_identifier END,
                    created_at = ?,
                    updated_at = CASE WHEN updated_at = 0 THEN ? ELSE updated_at END,
                    cloud_record_name = COALESCE(NULLIF(cloud_record_name, ''), ?),
                    sync_dirty = COALESCE(sync_dirty, 1)
                WHERE request_id = ?
                """,
                db: db
            ) { update in
                try bind(id, to: update, at: 1)
                try bind(result?.sessionID?.uuidString, to: update, at: 2)
                try bind(result?.text ?? "", to: update, at: 3)
                try bind(result?.engineIdentifier ?? "", to: update, at: 4)
                try bind(createdAt, to: update, at: 5)
                try bind(createdAt, to: update, at: 6)
                try bind(id, to: update, at: 7)
                try bind(requestID, to: update, at: 8)
            }
        }
    }

    private func backfillSessions(_ db: OpaquePointer) throws {
        try forEachRow("SELECT id, created_at, payload FROM recording_sessions", db: db) { statement in
            let rowID = sqliteColumnString(statement, 0)
            let fallbackCreatedAt = sqlite3_column_double(statement, 1)
            let payload = sqliteColumnData(statement, 2)
            let session = payload.flatMap { try? decoder.decode(RecordingSession.self, from: $0) }
            let id = session?.id.uuidString ?? rowID
            let createdAt = session?.createdAt.timeIntervalSince1970 ?? fallbackCreatedAt
            try execute(
                """
                UPDATE recording_sessions
                SET request_id = COALESCE(request_id, ?),
                    kind = CASE WHEN kind = '' THEN ? ELSE kind END,
                    title = COALESCE(title, ?),
                    phase = CASE WHEN phase = '' THEN ? ELSE phase END,
                    created_at = ?,
                    started_at = COALESCE(started_at, ?),
                    ended_at = COALESCE(ended_at, ?),
                    audio_file_name = COALESCE(audio_file_name, ?),
                    keeps_audio_recording = ?,
                    transcript_id = COALESCE(transcript_id, ?),
                    engine_identifier = COALESCE(engine_identifier, ?),
                    error_message = COALESCE(error_message, ?),
                    updated_at = CASE WHEN updated_at = 0 THEN ? ELSE updated_at END,
                    cloud_record_name = COALESCE(NULLIF(cloud_record_name, ''), ?),
                    sync_dirty = COALESCE(sync_dirty, 1)
                WHERE id = ?
                """,
                db: db
            ) { update in
                try bind(session?.requestID?.uuidString, to: update, at: 1)
                try bind(session?.kind.rawValue ?? RecordingSessionKind.quickDictation.rawValue, to: update, at: 2)
                try bind(session?.title, to: update, at: 3)
                try bind(session?.phase.rawValue ?? RecordingSessionPhase.completed.rawValue, to: update, at: 4)
                try bind(createdAt, to: update, at: 5)
                try bind(session?.startedAt?.timeIntervalSince1970, to: update, at: 6)
                try bind(session?.endedAt?.timeIntervalSince1970, to: update, at: 7)
                try bind(session?.audioFileName, to: update, at: 8)
                try bind(session?.keepsAudioRecording == true ? 1 : 0, to: update, at: 9)
                try bind(session?.transcriptID?.uuidString, to: update, at: 10)
                try bind(session?.engineIdentifier, to: update, at: 11)
                try bind(session?.errorMessage, to: update, at: 12)
                try bind(createdAt, to: update, at: 13)
                try bind(id, to: update, at: 14)
                try bind(rowID, to: update, at: 15)
            }
        }
    }

    private func backfillTranscripts(_ db: OpaquePointer) throws {
        try forEachRow("SELECT id, created_at, engine_identifier, payload FROM transcripts", db: db) { statement in
            let rowID = sqliteColumnString(statement, 0)
            let fallbackCreatedAt = sqlite3_column_double(statement, 1)
            let fallbackEngine = sqliteColumnString(statement, 2) ?? ""
            let payload = sqliteColumnData(statement, 3)
            let transcript = payload.flatMap { try? decoder.decode(Transcript.self, from: $0) }
            let id = transcript?.id.uuidString ?? rowID
            let createdAt = transcript?.createdAt.timeIntervalSince1970 ?? fallbackCreatedAt
            try execute(
                """
                UPDATE transcripts
                SET text = CASE WHEN text = '' THEN ? ELSE text END,
                    speaker_transcript = COALESCE(speaker_transcript, ?),
                    summary_text = COALESCE(summary_text, ?),
                    created_at = ?,
                    engine_identifier = CASE WHEN engine_identifier = '' THEN ? ELSE engine_identifier END,
                    diarization_state = CASE WHEN diarization_state = '' THEN ? ELSE diarization_state END,
                    diarization_error_message = COALESCE(diarization_error_message, ?),
                    summary_state = CASE WHEN summary_state = '' THEN ? ELSE summary_state END,
                    summary_backend = COALESCE(summary_backend, ?),
                    summary_model = COALESCE(summary_model, ?),
                    summary_error_message = COALESCE(summary_error_message, ?),
                    updated_at = CASE WHEN updated_at = 0 THEN ? ELSE updated_at END,
                    cloud_record_name = COALESCE(NULLIF(cloud_record_name, ''), ?),
                    sync_dirty = COALESCE(sync_dirty, 1)
                WHERE id = ?
                """,
                db: db
            ) { update in
                try bind(transcript?.text ?? "", to: update, at: 1)
                try bind(transcript?.speakerTranscript, to: update, at: 2)
                try bind(transcript?.summaryText, to: update, at: 3)
                try bind(createdAt, to: update, at: 4)
                try bind(transcript?.engineIdentifier ?? fallbackEngine, to: update, at: 5)
                try bind(transcript?.diarizationState.rawValue ?? MeetingProcessingState.notStarted.rawValue, to: update, at: 6)
                try bind(transcript?.diarizationErrorMessage, to: update, at: 7)
                try bind(transcript?.summaryState.rawValue ?? MeetingProcessingState.notStarted.rawValue, to: update, at: 8)
                try bind(transcript?.summaryBackend, to: update, at: 9)
                try bind(transcript?.summaryModel, to: update, at: 10)
                try bind(transcript?.summaryErrorMessage, to: update, at: 11)
                try bind(createdAt, to: update, at: 12)
                try bind(id, to: update, at: 13)
                try bind(rowID, to: update, at: 14)
            }
        }
    }

    private func backfillCustomWords(_ db: OpaquePointer) throws {
        try forEachRow("SELECT id, created_at, payload FROM custom_words", db: db) { statement in
            let rowID = sqliteColumnString(statement, 0)
            let fallbackCreatedAt = sqlite3_column_double(statement, 1)
            let payload = sqliteColumnData(statement, 2)
            let customWord = payload.flatMap { try? decoder.decode(CustomWord.self, from: $0) }
            let id = customWord?.id.uuidString ?? rowID
            let createdAt = customWord?.createdAt.timeIntervalSince1970 ?? fallbackCreatedAt
            try execute(
                """
                UPDATE custom_words
                SET replacement = COALESCE(replacement, ?),
                    matching_threshold = ?,
                    created_at = ?,
                    is_enabled = ?,
                    updated_at = CASE WHEN updated_at = 0 THEN ? ELSE updated_at END,
                    cloud_record_name = COALESCE(NULLIF(cloud_record_name, ''), ?),
                    sync_dirty = COALESCE(sync_dirty, 1)
                WHERE id = ?
                """,
                db: db
            ) { update in
                try bind(customWord?.replacement, to: update, at: 1)
                try bind(customWord?.matchingThreshold ?? 0.85, to: update, at: 2)
                try bind(createdAt, to: update, at: 3)
                try bind(customWord?.isEnabled == false ? 0 : 1, to: update, at: 4)
                try bind(createdAt, to: update, at: 5)
                try bind(id, to: update, at: 6)
                try bind(rowID, to: update, at: 7)
            }
        }
    }

    private func migrateLegacyJSONIfNeeded(_ db: OpaquePointer) throws {
        guard try valueData(key: .legacyJSONMigrated, db: db) == nil else { return }

        try transaction(db: db) {
            try migrateValue(DictationRequest.self, fileName: "pending-request.json", key: .pendingRequest, db: db)
            try migrateValue(DictationCommand.self, fileName: "pending-command.json", key: .pendingCommand, db: db)
            try migrateValue(DictationStatus.self, fileName: "status.json", key: .dictationStatus, db: db)
            try migrateValue(KeyboardExtensionStatus.self, fileName: "keyboard-status.json", key: .keyboardExtensionStatus, db: db)
            try migrateValue(KeyboardRuntimeStatus.self, fileName: "keyboard-runtime-status.json", key: .keyboardRuntimeStatus, db: db)

            if let results = legacyValue([DictationResult].self, fileName: "dictation-history.json") {
                for result in results {
                    try upsertResultHistory(result, db: db)
                }
            }

            for pickup in legacyResultPickups() {
                try upsertResultPickup(pickup, db: db)
            }

            if let sessions = legacyValue([RecordingSession].self, fileName: "recording-sessions.json") {
                for session in sessions {
                    try upsertSession(session, db: db)
                }
            }

            if let transcripts = legacyValue([Transcript].self, fileName: "transcripts.json") {
                for transcript in transcripts {
                    try insertTranscript(transcript, db: db)
                }
            }

            if let customWords = legacyValue([CustomWord].self, fileName: "custom-words.json") {
                try softDeleteVisibleCustomWords(db: db)
                for customWord in customWords {
                    try insertCustomWord(customWord, db: db)
                }
                try upsertValue(try encoder.encode(true), key: .customWordsInitialized, db: db)
            }

            try upsertValue(try encoder.encode(true), key: .legacyJSONMigrated, db: db)
        }
    }

    private func migrateValue<T: Codable>(
        _ type: T.Type,
        fileName: String,
        key: SharedStoreKey,
        db: OpaquePointer
    ) throws {
        guard let value = legacyValue(type, fileName: fileName) else { return }
        try upsertValue(try encoder.encode(value), key: key, db: db)
    }

    private func legacyValue<T: Decodable>(_ type: T.Type, fileName: String) -> T? {
        let url = containerURL.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? decoder.decode(type, from: data)
    }

    private func legacyResultPickups() -> [DictationResult] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: containerURL,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        return contents
            .filter { $0.lastPathComponent.hasPrefix("result-") && $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(DictationResult.self, from: data)
            }
    }

    private func upsertValue(_ data: Data, key: SharedStoreKey, db: OpaquePointer) throws {
        try execute(
            """
            INSERT INTO key_values (key, payload, updated_at)
            VALUES (?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET payload = excluded.payload, updated_at = excluded.updated_at
            """,
            db: db
        ) { statement in
            try bind(key.rawValue, to: statement, at: 1)
            try bind(data, to: statement, at: 2)
            try bind(Date().timeIntervalSince1970, to: statement, at: 3)
        }
    }

    private func valueData(key: SharedStoreKey, db: OpaquePointer) throws -> Data? {
        try querySingleBlob("SELECT payload FROM key_values WHERE key = ? LIMIT 1", db: db) { statement in
            try bind(key.rawValue, to: statement, at: 1)
        }
    }

    private func upsertResultPickup(_ result: DictationResult, db: OpaquePointer) throws {
        try execute(
            """
            INSERT INTO result_pickups (request_id, payload, updated_at)
            VALUES (?, ?, ?)
            ON CONFLICT(request_id) DO UPDATE SET payload = excluded.payload, updated_at = excluded.updated_at
            """,
            db: db
        ) { statement in
            try bind(result.requestID.uuidString, to: statement, at: 1)
            try bind(try encoder.encode(result), to: statement, at: 2)
            try bind(Date().timeIntervalSince1970, to: statement, at: 3)
        }
    }

    private func upsertResultHistory(_ result: DictationResult, db: OpaquePointer) throws {
        let now = Date().timeIntervalSince1970
        try execute(
            """
            INSERT INTO result_history (
                id, request_id, session_id, text, engine_identifier, created_at, updated_at,
                deleted_at, cloud_record_name, cloud_change_tag, last_synced_at, sync_dirty, payload
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, NULL, ?, NULL, NULL, 1, ?)
            ON CONFLICT(request_id) DO UPDATE SET
                id = excluded.id,
                session_id = excluded.session_id,
                text = excluded.text,
                engine_identifier = excluded.engine_identifier,
                created_at = excluded.created_at,
                updated_at = excluded.updated_at,
                deleted_at = NULL,
                cloud_record_name = excluded.cloud_record_name,
                sync_dirty = 1,
                payload = excluded.payload
            """,
            db: db
        ) { statement in
            try bind(result.id.uuidString, to: statement, at: 1)
            try bind(result.requestID.uuidString, to: statement, at: 2)
            try bind(result.sessionID?.uuidString, to: statement, at: 3)
            try bind(result.text, to: statement, at: 4)
            try bind(result.engineIdentifier, to: statement, at: 5)
            try bind(result.createdAt.timeIntervalSince1970, to: statement, at: 6)
            try bind(now, to: statement, at: 7)
            try bind(result.id.uuidString, to: statement, at: 8)
            try bind(try encoder.encode(result), to: statement, at: 9)
        }
    }

    private func upsertSession(_ session: RecordingSession, db: OpaquePointer) throws {
        let now = Date().timeIntervalSince1970
        try execute(
            """
            INSERT INTO recording_sessions (
                id, request_id, kind, title, phase, created_at, started_at, ended_at,
                audio_file_name, keeps_audio_recording, transcript_id, engine_identifier,
                error_message, updated_at, deleted_at, cloud_record_name, cloud_change_tag,
                last_synced_at, sync_dirty, payload
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, NULL, NULL, 1, ?)
            ON CONFLICT(id) DO UPDATE SET
                request_id = excluded.request_id,
                kind = excluded.kind,
                title = excluded.title,
                phase = excluded.phase,
                created_at = excluded.created_at,
                started_at = excluded.started_at,
                ended_at = excluded.ended_at,
                audio_file_name = excluded.audio_file_name,
                keeps_audio_recording = excluded.keeps_audio_recording,
                transcript_id = excluded.transcript_id,
                engine_identifier = excluded.engine_identifier,
                error_message = excluded.error_message,
                updated_at = excluded.updated_at,
                deleted_at = NULL,
                cloud_record_name = excluded.cloud_record_name,
                sync_dirty = 1,
                payload = excluded.payload
            """,
            db: db
        ) { statement in
            try bind(session.id.uuidString, to: statement, at: 1)
            try bind(session.requestID?.uuidString, to: statement, at: 2)
            try bind(session.kind.rawValue, to: statement, at: 3)
            try bind(session.title, to: statement, at: 4)
            try bind(session.phase.rawValue, to: statement, at: 5)
            try bind(session.createdAt.timeIntervalSince1970, to: statement, at: 6)
            try bind(session.startedAt?.timeIntervalSince1970, to: statement, at: 7)
            try bind(session.endedAt?.timeIntervalSince1970, to: statement, at: 8)
            try bind(session.audioFileName, to: statement, at: 9)
            try bind(session.keepsAudioRecording ? 1 : 0, to: statement, at: 10)
            try bind(session.transcriptID?.uuidString, to: statement, at: 11)
            try bind(session.engineIdentifier, to: statement, at: 12)
            try bind(session.errorMessage, to: statement, at: 13)
            try bind(now, to: statement, at: 14)
            try bind(session.id.uuidString, to: statement, at: 15)
            try bind(try encoder.encode(session), to: statement, at: 16)
        }
    }

    private func insertTranscript(_ transcript: Transcript, db: OpaquePointer) throws {
        let now = Date().timeIntervalSince1970
        try execute(
            """
            INSERT INTO transcripts (
                id, session_id, text, speaker_transcript, summary_text, created_at,
                engine_identifier, diarization_state, diarization_error_message,
                summary_state, summary_backend, summary_model, summary_error_message,
                updated_at, deleted_at, cloud_record_name, cloud_change_tag, last_synced_at,
                sync_dirty, payload
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, NULL, NULL, 1, ?)
            """,
            db: db
        ) { statement in
            try bind(transcript.id.uuidString, to: statement, at: 1)
            try bind(transcript.sessionID.uuidString, to: statement, at: 2)
            try bind(transcript.text, to: statement, at: 3)
            try bind(transcript.speakerTranscript, to: statement, at: 4)
            try bind(transcript.summaryText, to: statement, at: 5)
            try bind(transcript.createdAt.timeIntervalSince1970, to: statement, at: 6)
            try bind(transcript.engineIdentifier, to: statement, at: 7)
            try bind(transcript.diarizationState.rawValue, to: statement, at: 8)
            try bind(transcript.diarizationErrorMessage, to: statement, at: 9)
            try bind(transcript.summaryState.rawValue, to: statement, at: 10)
            try bind(transcript.summaryBackend, to: statement, at: 11)
            try bind(transcript.summaryModel, to: statement, at: 12)
            try bind(transcript.summaryErrorMessage, to: statement, at: 13)
            try bind(now, to: statement, at: 14)
            try bind(transcript.id.uuidString, to: statement, at: 15)
            try bind(try encoder.encode(transcript), to: statement, at: 16)
        }
    }

    private func insertCustomWord(_ customWord: CustomWord, db: OpaquePointer) throws {
        let now = Date().timeIntervalSince1970
        try execute(
            """
            INSERT INTO custom_words (
                id, word, replacement, matching_threshold, created_at, is_enabled,
                updated_at, deleted_at, cloud_record_name, cloud_change_tag,
                last_synced_at, sync_dirty, payload
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, NULL, ?, NULL, NULL, 1, ?)
            ON CONFLICT(id) DO UPDATE SET
                word = excluded.word,
                replacement = excluded.replacement,
                matching_threshold = excluded.matching_threshold,
                created_at = excluded.created_at,
                is_enabled = excluded.is_enabled,
                updated_at = excluded.updated_at,
                deleted_at = NULL,
                cloud_record_name = excluded.cloud_record_name,
                sync_dirty = 1,
                payload = excluded.payload
            """,
            db: db
        ) { statement in
            try bind(customWord.id.uuidString, to: statement, at: 1)
            try bind(customWord.word, to: statement, at: 2)
            try bind(customWord.replacement, to: statement, at: 3)
            try bind(customWord.matchingThreshold, to: statement, at: 4)
            try bind(customWord.createdAt.timeIntervalSince1970, to: statement, at: 5)
            try bind(customWord.isEnabled ? 1 : 0, to: statement, at: 6)
            try bind(now, to: statement, at: 7)
            try bind(customWord.id.uuidString, to: statement, at: 8)
            try bind(try encoder.encode(customWord), to: statement, at: 9)
        }
    }

    private func softDeleteVisibleCustomWords(db: OpaquePointer) throws {
        let now = Date().timeIntervalSince1970
        try execute(
            """
            UPDATE custom_words
            SET deleted_at = ?, updated_at = ?, sync_dirty = 1
            WHERE deleted_at IS NULL
            """,
            db: db
        ) { statement in
            try bind(now, to: statement, at: 1)
            try bind(now, to: statement, at: 2)
        }
    }

    private func upsertSyncedDictation(_ record: SyncTextRecord, db: OpaquePointer) throws {
        if let localUpdatedAt = try localUpdatedAt(table: "result_history", recordName: record.id, db: db),
           localUpdatedAt > record.updatedAt.timeIntervalSince1970 {
            return
        }

        let existingLink = try queryRows(
            "SELECT id, request_id, session_id FROM result_history WHERE cloud_record_name = ? LIMIT 1",
            db: db
        ) { statement in
            try bind(record.id, to: statement, at: 1)
        } read: { statement in
            (
                id: sqliteColumnString(statement, 0),
                requestID: sqliteColumnString(statement, 1),
                sessionID: sqliteColumnString(statement, 2)
            )
        }.first ?? nil

        let resultID = existingLink?.id.flatMap(UUID.init(uuidString:)) ?? UUID(uuidString: record.id) ?? UUID()
        let requestID = existingLink?.requestID.flatMap(UUID.init(uuidString:)) ?? resultID
        let sessionID = existingLink?.sessionID.flatMap(UUID.init(uuidString:))
        let result = DictationResult(
            id: resultID,
            requestID: requestID,
            sessionID: sessionID,
            text: record.text,
            createdAt: record.createdAt,
            engineIdentifier: record.engineIdentifier ?? "icloud",
            source: record.source
        )
        try execute(
            """
            INSERT INTO result_history (
                id, request_id, session_id, text, engine_identifier, created_at, updated_at,
                deleted_at, cloud_record_name, cloud_change_tag, last_synced_at, sync_dirty, payload
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?)
            ON CONFLICT(cloud_record_name) DO UPDATE SET
                id = excluded.id,
                request_id = excluded.request_id,
                session_id = COALESCE(result_history.session_id, excluded.session_id),
                text = excluded.text,
                engine_identifier = excluded.engine_identifier,
                created_at = excluded.created_at,
                updated_at = excluded.updated_at,
                deleted_at = excluded.deleted_at,
                cloud_record_name = excluded.cloud_record_name,
                cloud_change_tag = excluded.cloud_change_tag,
                last_synced_at = excluded.last_synced_at,
                sync_dirty = 0,
                payload = excluded.payload
            """,
            db: db
        ) { statement in
            try bind(resultID.uuidString, to: statement, at: 1)
            try bind(requestID.uuidString, to: statement, at: 2)
            try bind(sessionID?.uuidString, to: statement, at: 3)
            try bind(record.text, to: statement, at: 4)
            try bind(record.engineIdentifier ?? "icloud", to: statement, at: 5)
            try bind(record.createdAt.timeIntervalSince1970, to: statement, at: 6)
            try bind(record.updatedAt.timeIntervalSince1970, to: statement, at: 7)
            try bind(record.isDeleted ? record.updatedAt.timeIntervalSince1970 : nil, to: statement, at: 8)
            try bind(record.id, to: statement, at: 9)
            try bind(record.cloudChangeTag, to: statement, at: 10)
            try bind(Date().timeIntervalSince1970, to: statement, at: 11)
            try bind(try encoder.encode(result), to: statement, at: 12)
        }
    }

    private func upsertSyncedMeeting(_ record: SyncTextRecord, db: OpaquePointer) throws {
        if let localUpdatedAt = try localUpdatedAt(table: "recording_sessions", recordName: record.id, db: db),
           localUpdatedAt > record.updatedAt.timeIntervalSince1970 {
            return
        }

        let existingSessionID = try queryRows(
            "SELECT id FROM recording_sessions WHERE cloud_record_name = ? LIMIT 1",
            db: db
        ) { statement in
            try bind(record.id, to: statement, at: 1)
        } read: { statement in
            sqliteColumnString(statement, 0)
        }.first ?? nil
        let sessionID = existingSessionID.flatMap(UUID.init(uuidString:)) ?? UUID(uuidString: record.id) ?? UUID()
        let transcriptID = UUID()
        let session = RecordingSession(
            id: sessionID,
            requestID: nil,
            kind: .meeting,
            title: record.title ?? "Meeting",
            createdAt: record.createdAt,
            startedAt: record.startedAt,
            endedAt: record.endedAt,
            phase: record.isDeleted ? .cancelled : .completed,
            audioFileName: nil,
            keepsAudioRecording: false,
            transcriptID: transcriptID,
            engineIdentifier: record.engineIdentifier,
            errorMessage: nil
        )
        let transcript = Transcript(
            id: transcriptID,
            sessionID: sessionID,
            text: record.text,
            createdAt: record.createdAt,
            engineIdentifier: record.engineIdentifier ?? "icloud",
            speakerTranscript: record.speakerTranscript,
            summaryText: record.summaryText,
            diarizationState: .completed,
            summaryState: record.summaryText == nil ? .notStarted : .completed
        )

        try execute(
            """
            INSERT INTO recording_sessions (
                id, request_id, kind, title, phase, created_at, started_at, ended_at,
                audio_file_name, keeps_audio_recording, transcript_id, engine_identifier,
                error_message, updated_at, deleted_at, cloud_record_name, cloud_change_tag,
                last_synced_at, sync_dirty, payload
            )
            VALUES (?, NULL, ?, ?, ?, ?, ?, ?, NULL, 0, ?, ?, NULL, ?, ?, ?, ?, ?, 0, ?)
            ON CONFLICT(id) DO UPDATE SET
                title = excluded.title,
                phase = excluded.phase,
                started_at = excluded.started_at,
                ended_at = excluded.ended_at,
                audio_file_name = NULL,
                keeps_audio_recording = 0,
                transcript_id = excluded.transcript_id,
                engine_identifier = excluded.engine_identifier,
                updated_at = excluded.updated_at,
                deleted_at = excluded.deleted_at,
                cloud_record_name = excluded.cloud_record_name,
                cloud_change_tag = excluded.cloud_change_tag,
                last_synced_at = excluded.last_synced_at,
                sync_dirty = 0,
                payload = excluded.payload
            """,
            db: db
        ) { statement in
            try bind(session.id.uuidString, to: statement, at: 1)
            try bind(session.kind.rawValue, to: statement, at: 2)
            try bind(session.title, to: statement, at: 3)
            try bind(session.phase.rawValue, to: statement, at: 4)
            try bind(session.createdAt.timeIntervalSince1970, to: statement, at: 5)
            try bind(session.startedAt?.timeIntervalSince1970, to: statement, at: 6)
            try bind(session.endedAt?.timeIntervalSince1970, to: statement, at: 7)
            try bind(transcriptID.uuidString, to: statement, at: 8)
            try bind(session.engineIdentifier, to: statement, at: 9)
            try bind(record.updatedAt.timeIntervalSince1970, to: statement, at: 10)
            try bind(record.isDeleted ? record.updatedAt.timeIntervalSince1970 : nil, to: statement, at: 11)
            try bind(record.id, to: statement, at: 12)
            try bind(record.cloudChangeTag, to: statement, at: 13)
            try bind(Date().timeIntervalSince1970, to: statement, at: 14)
            try bind(try encoder.encode(session), to: statement, at: 15)
        }

        try execute("DELETE FROM transcripts WHERE session_id = ?", db: db) { statement in
            try bind(sessionID.uuidString, to: statement, at: 1)
        }
        try insertTranscript(transcript, db: db)
        try execute(
            """
            UPDATE transcripts
            SET updated_at = ?, deleted_at = ?, cloud_record_name = ?, cloud_change_tag = ?,
                last_synced_at = ?, sync_dirty = 0
            WHERE session_id = ?
            """,
            db: db
        ) { statement in
            try bind(record.updatedAt.timeIntervalSince1970, to: statement, at: 1)
            try bind(record.isDeleted ? record.updatedAt.timeIntervalSince1970 : nil, to: statement, at: 2)
            try bind("\(record.id)-transcript", to: statement, at: 3)
            try bind(record.cloudChangeTag, to: statement, at: 4)
            try bind(Date().timeIntervalSince1970, to: statement, at: 5)
            try bind(sessionID.uuidString, to: statement, at: 6)
        }
    }

    private func localUpdatedAt(table: String, recordName: String, db: OpaquePointer) throws -> Double? {
        try queryRows(
            "SELECT updated_at FROM \(table) WHERE cloud_record_name = ? LIMIT 1",
            db: db
        ) { statement in
            try bind(recordName, to: statement, at: 1)
        } read: { statement in
            sqlite3_column_double(statement, 0)
        }.first ?? nil
    }

    private func transaction(db: OpaquePointer, _ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE TRANSACTION", db: db)
        do {
            try body()
            try exec("COMMIT", db: db)
        } catch {
            try? exec("ROLLBACK", db: db)
            throw error
        }
    }

    private func userVersion(_ db: OpaquePointer) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw SharedStoreDatabaseError.prepareFailed(sqlite3ErrorMessage(db))
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func setUserVersion(_ version: Int, db: OpaquePointer) throws {
        try exec("PRAGMA user_version = \(version)", db: db)
    }

    private func querySingleBlob(
        _ sql: String,
        db: OpaquePointer,
        bindValues: (OpaquePointer) throws -> Void
    ) throws -> Data? {
        try queryBlobs(sql, db: db, bindValues: bindValues).first
    }

    private func queryBlobs(
        _ sql: String,
        db: OpaquePointer,
        bindValues: (OpaquePointer) throws -> Void
    ) throws -> [Data] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw SharedStoreDatabaseError.prepareFailed(sqlite3ErrorMessage(db))
        }
        defer { sqlite3_finalize(statement) }

        try bindValues(statement)

        var rows: [Data] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW {
                guard let bytes = sqlite3_column_blob(statement, 0) else {
                    rows.append(Data())
                    continue
                }
                rows.append(Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
            } else if result == SQLITE_DONE {
                return rows
            } else {
                throw SharedStoreDatabaseError.stepFailed(sqlite3ErrorMessage(db))
            }
        }
    }

    private func queryRows<T>(
        _ sql: String,
        db: OpaquePointer,
        bindValues: (OpaquePointer) throws -> Void,
        read: (OpaquePointer) throws -> T
    ) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw SharedStoreDatabaseError.prepareFailed(sqlite3ErrorMessage(db))
        }
        defer { sqlite3_finalize(statement) }

        try bindValues(statement)

        var rows: [T] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW {
                rows.append(try read(statement))
            } else if result == SQLITE_DONE {
                return rows
            } else {
                throw SharedStoreDatabaseError.stepFailed(sqlite3ErrorMessage(db))
            }
        }
    }

    private func forEachRow(
        _ sql: String,
        db: OpaquePointer,
        body: (OpaquePointer) throws -> Void
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw SharedStoreDatabaseError.prepareFailed(sqlite3ErrorMessage(db))
        }
        defer { sqlite3_finalize(statement) }

        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW {
                try body(statement)
            } else if result == SQLITE_DONE {
                return
            } else {
                throw SharedStoreDatabaseError.stepFailed(sqlite3ErrorMessage(db))
            }
        }
    }

    private func execute(
        _ sql: String,
        db: OpaquePointer,
        bindValues: (OpaquePointer) throws -> Void
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw SharedStoreDatabaseError.prepareFailed(sqlite3ErrorMessage(db))
        }
        defer { sqlite3_finalize(statement) }

        try bindValues(statement)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SharedStoreDatabaseError.stepFailed(sqlite3ErrorMessage(db))
        }
    }

    private func exec(_ sql: String, db: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        if result != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? sqlite3ErrorMessage(db)
            sqlite3_free(errorMessage)
            throw SharedStoreDatabaseError.stepFailed(message)
        }
    }

    private func bind(_ value: String?, to statement: OpaquePointer, at index: Int32) throws {
        let result: Int32
        if let value {
            result = sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
        } else {
            result = sqlite3_bind_null(statement, index)
        }
        guard result == SQLITE_OK else {
            throw SharedStoreDatabaseError.bindFailed("text at index \(index)")
        }
    }

    private func bind(_ value: Int, to statement: OpaquePointer, at index: Int32) throws {
        guard sqlite3_bind_int64(statement, index, sqlite3_int64(value)) == SQLITE_OK else {
            throw SharedStoreDatabaseError.bindFailed("integer at index \(index)")
        }
    }

    private func bind(_ value: Double, to statement: OpaquePointer, at index: Int32) throws {
        guard sqlite3_bind_double(statement, index, value) == SQLITE_OK else {
            throw SharedStoreDatabaseError.bindFailed("double at index \(index)")
        }
    }

    private func bind(_ value: Double?, to statement: OpaquePointer, at index: Int32) throws {
        let result: Int32
        if let value {
            result = sqlite3_bind_double(statement, index, value)
        } else {
            result = sqlite3_bind_null(statement, index)
        }
        guard result == SQLITE_OK else {
            throw SharedStoreDatabaseError.bindFailed("optional double at index \(index)")
        }
    }

    private func bind(_ data: Data, to statement: OpaquePointer, at index: Int32) throws {
        let result = data.withUnsafeBytes { buffer -> Int32 in
            sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
        }
        guard result == SQLITE_OK else {
            throw SharedStoreDatabaseError.bindFailed("blob at index \(index)")
        }
    }

    private func sqlite3ErrorMessage(_ db: OpaquePointer) -> String {
        sqlite3_errmsg(db).map { String(cString: $0) } ?? "unknown SQLite error"
    }

    private func sqliteColumnString(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let text = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: text)
    }

    private func sqliteColumnData(_ statement: OpaquePointer, _ index: Int32) -> Data? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let bytes = sqlite3_column_blob(statement, index) else {
            return nil
        }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
    }

    private static func optionalDate(_ statement: OpaquePointer, _ index: Int32) -> Date? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        let value = sqlite3_column_double(statement, index)
        guard value > 0 else { return nil }
        return Date(timeIntervalSince1970: value)
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    private static let schemaSQL = """
    CREATE TABLE IF NOT EXISTS key_values (
        key TEXT PRIMARY KEY NOT NULL,
        payload BLOB NOT NULL,
        updated_at REAL NOT NULL
    );

    CREATE TABLE IF NOT EXISTS result_pickups (
        request_id TEXT PRIMARY KEY NOT NULL,
        payload BLOB NOT NULL,
        updated_at REAL NOT NULL
    );

    CREATE TABLE IF NOT EXISTS result_history (
        id TEXT NOT NULL,
        request_id TEXT PRIMARY KEY NOT NULL,
        session_id TEXT,
        text TEXT NOT NULL DEFAULT '',
        engine_identifier TEXT NOT NULL DEFAULT '',
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL DEFAULT 0,
        deleted_at REAL,
        cloud_record_name TEXT,
        cloud_change_tag TEXT,
        last_synced_at REAL,
        sync_dirty INTEGER NOT NULL DEFAULT 1,
        payload BLOB NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_result_history_created_at ON result_history(created_at DESC);

    CREATE TABLE IF NOT EXISTS recording_sessions (
        id TEXT PRIMARY KEY NOT NULL,
        request_id TEXT UNIQUE,
        kind TEXT NOT NULL,
        title TEXT,
        phase TEXT NOT NULL,
        created_at REAL NOT NULL,
        started_at REAL,
        ended_at REAL,
        audio_file_name TEXT,
        keeps_audio_recording INTEGER NOT NULL DEFAULT 0,
        transcript_id TEXT,
        engine_identifier TEXT,
        error_message TEXT,
        updated_at REAL NOT NULL DEFAULT 0,
        deleted_at REAL,
        cloud_record_name TEXT,
        cloud_change_tag TEXT,
        last_synced_at REAL,
        sync_dirty INTEGER NOT NULL DEFAULT 1,
        payload BLOB NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_recording_sessions_created_at ON recording_sessions(created_at DESC);
    CREATE INDEX IF NOT EXISTS idx_recording_sessions_request_id ON recording_sessions(request_id);

    CREATE TABLE IF NOT EXISTS transcripts (
        id TEXT PRIMARY KEY NOT NULL,
        session_id TEXT UNIQUE NOT NULL,
        created_at REAL NOT NULL,
        text TEXT NOT NULL DEFAULT '',
        speaker_transcript TEXT,
        summary_text TEXT,
        engine_identifier TEXT NOT NULL,
        diarization_state TEXT NOT NULL DEFAULT 'notStarted',
        diarization_error_message TEXT,
        summary_state TEXT NOT NULL DEFAULT 'notStarted',
        summary_backend TEXT,
        summary_model TEXT,
        summary_error_message TEXT,
        updated_at REAL NOT NULL DEFAULT 0,
        deleted_at REAL,
        cloud_record_name TEXT,
        cloud_change_tag TEXT,
        last_synced_at REAL,
        sync_dirty INTEGER NOT NULL DEFAULT 1,
        payload BLOB NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_transcripts_session_id ON transcripts(session_id);
    CREATE INDEX IF NOT EXISTS idx_transcripts_created_at ON transcripts(created_at DESC);

    CREATE TABLE IF NOT EXISTS custom_words (
        id TEXT PRIMARY KEY NOT NULL,
        word TEXT NOT NULL,
        replacement TEXT,
        matching_threshold REAL NOT NULL DEFAULT 0.85,
        created_at REAL NOT NULL,
        is_enabled INTEGER NOT NULL,
        updated_at REAL NOT NULL DEFAULT 0,
        deleted_at REAL,
        cloud_record_name TEXT,
        cloud_change_tag TEXT,
        last_synced_at REAL,
        sync_dirty INTEGER NOT NULL DEFAULT 1,
        payload BLOB NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_custom_words_created_at ON custom_words(created_at DESC);
    """
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
