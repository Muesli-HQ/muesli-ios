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
    private static let maxStoredResults = 200

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
        try saveStatus(.init(requestID: request.id, phase: .requested))
    }

    func pendingRequest() throws -> DictationRequest? {
        try read(DictationRequest.self, from: "pending-request.json")
    }

    func clearPendingRequest() throws {
        try remove("pending-request.json")
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
