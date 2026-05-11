import Foundation

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
    private static let resultsHistoryFileName = "dictation-history.json"
    private static let sessionsFileName = "recording-sessions.json"
    private static let transcriptsFileName = "transcripts.json"
    private static let keyboardStatusFileName = "keyboard-status.json"
    private static let keyboardRuntimeStatusFileName = "keyboard-runtime-status.json"
    private static let pendingCommandFileName = "pending-command.json"
    private static let maxStoredResults = 200
    private static let maxStoredSessions = 500

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
        try write(request, to: "pending-request.json")
    }

    func pendingRequest() throws -> DictationRequest? {
        try read(DictationRequest.self, from: "pending-request.json")
    }

    func clearPendingRequest() throws {
        try remove("pending-request.json")
    }

    func saveCommand(_ command: DictationCommand) throws {
        try write(command, to: Self.pendingCommandFileName)
    }

    func pendingCommand() throws -> DictationCommand? {
        try read(DictationCommand.self, from: Self.pendingCommandFileName)
    }

    func clearPendingCommand() throws {
        try remove(Self.pendingCommandFileName)
    }

    func saveStatus(_ status: DictationStatus) throws {
        try write(status, to: "status.json")
    }

    func status() throws -> DictationStatus {
        try read(DictationStatus.self, from: "status.json") ?? .idle
    }

    func saveResult(_ result: DictationResult) throws {
        try write(result, to: resultFileName(for: result.requestID))
        try appendResultToHistory(result)
        try saveStatus(.init(requestID: result.requestID, phase: .finished))
    }

    func result(for requestID: UUID) throws -> DictationResult? {
        try read(DictationResult.self, from: resultFileName(for: requestID))
    }

    func resultsHistory() throws -> [DictationResult] {
        let results = try read([DictationResult].self, from: Self.resultsHistoryFileName) ?? []
        return results.sorted { $0.createdAt > $1.createdAt }
    }

    func clearResult(for requestID: UUID) throws {
        try remove(resultFileName(for: requestID))
    }

    func saveKeyboardExtensionStatus(_ status: KeyboardExtensionStatus) throws {
        try write(status, to: Self.keyboardStatusFileName)
    }

    func keyboardExtensionStatus() throws -> KeyboardExtensionStatus? {
        try read(KeyboardExtensionStatus.self, from: Self.keyboardStatusFileName)
    }

    func saveKeyboardRuntimeStatus(_ status: KeyboardRuntimeStatus) throws {
        try write(status, to: Self.keyboardRuntimeStatusFileName)
    }

    func keyboardRuntimeStatus() throws -> KeyboardRuntimeStatus? {
        try read(KeyboardRuntimeStatus.self, from: Self.keyboardRuntimeStatusFileName)
    }

    func clearKeyboardRuntimeStatus() throws {
        try remove(Self.keyboardRuntimeStatusFileName)
    }

    func saveSession(_ session: RecordingSession) throws {
        var sessions = try recordingSessions()
        sessions.removeAll { $0.id == session.id }
        sessions.insert(session, at: 0)
        sessions.sort { $0.createdAt > $1.createdAt }
        if sessions.count > Self.maxStoredSessions {
            sessions = Array(sessions.prefix(Self.maxStoredSessions))
        }
        try write(sessions, to: Self.sessionsFileName)
    }

    func recordingSessions() throws -> [RecordingSession] {
        let sessions = try read([RecordingSession].self, from: Self.sessionsFileName) ?? []
        return sessions.sorted { $0.createdAt > $1.createdAt }
    }

    func recordingSession(id: UUID) throws -> RecordingSession? {
        try recordingSessions().first { $0.id == id }
    }

    func recordingSession(requestID: UUID) throws -> RecordingSession? {
        try recordingSessions().first { $0.requestID == requestID }
    }

    func saveTranscript(_ transcript: Transcript) throws {
        var transcripts = try transcripts()
        transcripts.removeAll { $0.id == transcript.id || $0.sessionID == transcript.sessionID }
        transcripts.insert(transcript, at: 0)
        transcripts.sort { $0.createdAt > $1.createdAt }
        try write(transcripts, to: Self.transcriptsFileName)
    }

    func transcripts() throws -> [Transcript] {
        let transcripts = try read([Transcript].self, from: Self.transcriptsFileName) ?? []
        return transcripts.sorted { $0.createdAt > $1.createdAt }
    }

    func transcript(for sessionID: UUID) throws -> Transcript? {
        try transcripts().first { $0.sessionID == sessionID }
    }

    func newAudioFileURL(sessionID: UUID) throws -> URL {
        let fileName = audioFileName(sessionID: sessionID)
        return try audioFileURL(fileName: fileName)
    }

    func audioFileURL(fileName: String) throws -> URL {
        let directory = try recordingsDirectoryURL()
        return directory.appendingPathComponent(fileName)
    }

    func audioFileName(sessionID: UUID) -> String {
        "session-\(sessionID.uuidString).wav"
    }

    private func appendResultToHistory(_ result: DictationResult) throws {
        var results = try resultsHistory()
        results.removeAll { $0.requestID == result.requestID }
        results.insert(result, at: 0)
        if results.count > Self.maxStoredResults {
            results = Array(results.prefix(Self.maxStoredResults))
        }
        try write(results, to: Self.resultsHistoryFileName)
    }

    private func resultFileName(for requestID: UUID) -> String {
        "result-\(requestID.uuidString).json"
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

    private func fileURL(_ fileName: String) throws -> URL {
        try containerURL().appendingPathComponent(fileName)
    }

    private func read<T: Decodable>(_ type: T.Type, from fileName: String) throws -> T? {
        let url = try fileURL(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try decoder.decode(type, from: data)
    }

    private func write<T: Encodable>(_ value: T, to fileName: String) throws {
        let url = try fileURL(fileName)
        let temporaryURL = url.appendingPathExtension("tmp")
        let data = try encoder.encode(value)
        try data.write(to: temporaryURL, options: [.atomic])
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: url)
    }

    private func remove(_ fileName: String) throws {
        let url = try fileURL(fileName)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
