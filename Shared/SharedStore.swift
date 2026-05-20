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

    func saveTranscript(_ transcript: Transcript) throws {
        try database().saveTranscript(transcript)
    }

    func transcripts() throws -> [Transcript] {
        try database().transcripts()
    }

    func transcript(for sessionID: UUID) throws -> Transcript? {
        try database().transcript(for: sessionID)
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

    func newAudioFileURL(sessionID: UUID) throws -> URL {
        let fileName = audioFileName(sessionID: sessionID)
        return try audioFileURL(fileName: fileName)
    }

    func audioFileURL(fileName: String) throws -> URL {
        let directory = try recordingsDirectoryURL()
        return directory.appendingPathComponent(fileName)
    }

    func deleteAudioFile(fileName: String) throws {
        let url = try audioFileURL(fileName: fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    func audioFileName(sessionID: UUID) -> String {
        "session-\(sessionID.uuidString).wav"
    }

    private func database() throws -> SharedStoreDatabase {
        try SharedStoreDatabase(containerURL: containerURL(), encoder: encoder, decoder: decoder)
    }

    private func recordingsDirectoryURL() throws -> URL {
        let directory = try containerURL().appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
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
    case dictationStatus = "dictation_status"
    case keyboardExtensionStatus = "keyboard_extension_status"
    case keyboardRuntimeStatus = "keyboard_runtime_status"
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
    private static let maxStoredResults = 200
    private static let maxStoredSessions = 500

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
                try pruneResultsHistory(db: db)
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
                "SELECT payload FROM result_history ORDER BY created_at DESC LIMIT ?",
                db: db
            ) { statement in
                try bind(Self.maxStoredResults, to: statement, at: 1)
            }.map { try decoder.decode(DictationResult.self, from: $0) }
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
                try pruneSessions(db: db)
            }
        }
    }

    func recordingSessions() throws -> [RecordingSession] {
        try withDatabase { db in
            try queryBlobs(
                "SELECT payload FROM recording_sessions ORDER BY created_at DESC LIMIT ?",
                db: db
            ) { statement in
                try bind(Self.maxStoredSessions, to: statement, at: 1)
            }.map { try decoder.decode(RecordingSession.self, from: $0) }
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
            try queryBlobs("SELECT payload FROM transcripts ORDER BY created_at DESC", db: db) { _ in }
                .map { try decoder.decode(Transcript.self, from: $0) }
        }
    }

    func transcript(for sessionID: UUID) throws -> Transcript? {
        try withDatabase { db in
            try querySingleBlob(
                "SELECT payload FROM transcripts WHERE session_id = ? LIMIT 1",
                db: db
            ) { statement in
                try bind(sessionID.uuidString, to: statement, at: 1)
            }.map { try decoder.decode(Transcript.self, from: $0) }
        }
    }

    func customWords() throws -> [CustomWord] {
        try withDatabase { db in
            let rows = try queryBlobs("SELECT payload FROM custom_words ORDER BY created_at DESC", db: db) { _ in }
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
                try execute("DELETE FROM custom_words", db: db) { _ in }
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
                try execute("DELETE FROM custom_words WHERE id = ?", db: db) { statement in
                    try bind(customWord.id.uuidString, to: statement, at: 1)
                }
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
                try execute("DELETE FROM custom_words WHERE id = ?", db: db) { statement in
                    try bind(id.uuidString, to: statement, at: 1)
                }
                try upsertValue(try encoder.encode(true), key: .customWordsInitialized, db: db)
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
        try migrateLegacyJSONIfNeeded(db)

        Self.initializationLock.lock()
        Self.initializedDatabasePaths.insert(databaseURL.path)
        Self.initializationLock.unlock()
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
                try pruneResultsHistory(db: db)
            }

            for pickup in legacyResultPickups() {
                try upsertResultPickup(pickup, db: db)
            }

            if let sessions = legacyValue([RecordingSession].self, fileName: "recording-sessions.json") {
                for session in sessions {
                    try upsertSession(session, db: db)
                }
                try pruneSessions(db: db)
            }

            if let transcripts = legacyValue([Transcript].self, fileName: "transcripts.json") {
                for transcript in transcripts {
                    try insertTranscript(transcript, db: db)
                }
            }

            if let customWords = legacyValue([CustomWord].self, fileName: "custom-words.json") {
                try execute("DELETE FROM custom_words", db: db) { _ in }
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
        try execute(
            """
            INSERT INTO result_history (id, request_id, created_at, payload)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(request_id) DO UPDATE SET
                id = excluded.id,
                created_at = excluded.created_at,
                payload = excluded.payload
            """,
            db: db
        ) { statement in
            try bind(result.id.uuidString, to: statement, at: 1)
            try bind(result.requestID.uuidString, to: statement, at: 2)
            try bind(result.createdAt.timeIntervalSince1970, to: statement, at: 3)
            try bind(try encoder.encode(result), to: statement, at: 4)
        }
    }

    private func pruneResultsHistory(db: OpaquePointer) throws {
        try execute(
            """
            DELETE FROM result_history
            WHERE request_id NOT IN (
                SELECT request_id FROM result_history ORDER BY created_at DESC LIMIT ?
            )
            """,
            db: db
        ) { statement in
            try bind(Self.maxStoredResults, to: statement, at: 1)
        }
    }

    private func upsertSession(_ session: RecordingSession, db: OpaquePointer) throws {
        try execute(
            """
            INSERT INTO recording_sessions (id, request_id, kind, phase, created_at, payload)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                request_id = excluded.request_id,
                kind = excluded.kind,
                phase = excluded.phase,
                created_at = excluded.created_at,
                payload = excluded.payload
            """,
            db: db
        ) { statement in
            try bind(session.id.uuidString, to: statement, at: 1)
            try bind(session.requestID?.uuidString, to: statement, at: 2)
            try bind(session.kind.rawValue, to: statement, at: 3)
            try bind(session.phase.rawValue, to: statement, at: 4)
            try bind(session.createdAt.timeIntervalSince1970, to: statement, at: 5)
            try bind(try encoder.encode(session), to: statement, at: 6)
        }
    }

    private func pruneSessions(db: OpaquePointer) throws {
        try execute(
            """
            DELETE FROM recording_sessions
            WHERE id NOT IN (
                SELECT id FROM recording_sessions ORDER BY created_at DESC LIMIT ?
            )
            """,
            db: db
        ) { statement in
            try bind(Self.maxStoredSessions, to: statement, at: 1)
        }
    }

    private func insertTranscript(_ transcript: Transcript, db: OpaquePointer) throws {
        try execute(
            """
            INSERT INTO transcripts (id, session_id, created_at, engine_identifier, payload)
            VALUES (?, ?, ?, ?, ?)
            """,
            db: db
        ) { statement in
            try bind(transcript.id.uuidString, to: statement, at: 1)
            try bind(transcript.sessionID.uuidString, to: statement, at: 2)
            try bind(transcript.createdAt.timeIntervalSince1970, to: statement, at: 3)
            try bind(transcript.engineIdentifier, to: statement, at: 4)
            try bind(try encoder.encode(transcript), to: statement, at: 5)
        }
    }

    private func insertCustomWord(_ customWord: CustomWord, db: OpaquePointer) throws {
        try execute(
            """
            INSERT INTO custom_words (id, word, created_at, is_enabled, payload)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                word = excluded.word,
                created_at = excluded.created_at,
                is_enabled = excluded.is_enabled,
                payload = excluded.payload
            """,
            db: db
        ) { statement in
            try bind(customWord.id.uuidString, to: statement, at: 1)
            try bind(customWord.word, to: statement, at: 2)
            try bind(customWord.createdAt.timeIntervalSince1970, to: statement, at: 3)
            try bind(customWord.isEnabled ? 1 : 0, to: statement, at: 4)
            try bind(try encoder.encode(customWord), to: statement, at: 5)
        }
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
        created_at REAL NOT NULL,
        payload BLOB NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_result_history_created_at ON result_history(created_at DESC);

    CREATE TABLE IF NOT EXISTS recording_sessions (
        id TEXT PRIMARY KEY NOT NULL,
        request_id TEXT UNIQUE,
        kind TEXT NOT NULL,
        phase TEXT NOT NULL,
        created_at REAL NOT NULL,
        payload BLOB NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_recording_sessions_created_at ON recording_sessions(created_at DESC);
    CREATE INDEX IF NOT EXISTS idx_recording_sessions_request_id ON recording_sessions(request_id);

    CREATE TABLE IF NOT EXISTS transcripts (
        id TEXT PRIMARY KEY NOT NULL,
        session_id TEXT UNIQUE NOT NULL,
        created_at REAL NOT NULL,
        engine_identifier TEXT NOT NULL,
        payload BLOB NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_transcripts_session_id ON transcripts(session_id);
    CREATE INDEX IF NOT EXISTS idx_transcripts_created_at ON transcripts(created_at DESC);

    CREATE TABLE IF NOT EXISTS custom_words (
        id TEXT PRIMARY KEY NOT NULL,
        word TEXT NOT NULL,
        created_at REAL NOT NULL,
        is_enabled INTEGER NOT NULL,
        payload BLOB NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_custom_words_created_at ON custom_words(created_at DESC);
    """
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
