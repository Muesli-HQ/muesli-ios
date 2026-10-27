import CryptoKit
import Foundation

/// The immutable R2 manifest contract shared with the macOS app.
struct ModelDownloadManifest: Codable, Sendable {
    enum Source: String, Codable, Sendable { case mirror, huggingFace }
    let source: Source
    let version: String
    let files: [ModelDownloadFile]

    static func mirrorURL(for model: LocalTranscriptionModel) -> URL? {
        let path: String
        if let variant = model.whisperVariant {
            path = "whisperkit/openai_whisper-\(variant)"
        } else if model == .parakeetUnified {
            path = "fluidaudio/parakeet-unified-en-0.6b"
        } else if model == .parakeetV3 {
            path = "fluidaudio/parakeet-tdt-0.6b-v3"
        } else { return nil }
        return URL(string: "https://assets.muesli.works/models/\(path)/legacy-local-v1/manifest.json")
    }

    static func decodeMirror(_ data: Data, url: URL, spec: ModelDownloadSpec) throws -> Self {
        struct Payload: Decodable {
            struct File: Decodable { let relativePath: String; let objectKey: String; let bytes: Int64; let sha256: String }
            let format: String; let modelID: String; let version: String; let files: [File]
        }
        guard url == mirrorURL(for: spec.model) else { throw ModelDownloadValidationError.invalidManifest }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        let expectedID = spec.model.whisperVariant ?? spec.remotePath
        guard payload.format == "muesli-r2-model-manifest-v1", payload.modelID == expectedID,
              !payload.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !payload.files.isEmpty else { throw ModelDownloadValidationError.invalidManifest }
        let prefix = url.deletingLastPathComponent().path.dropFirst() + "/files/"
        var seen = Set<String>()
        let files = try payload.files.map { item -> ModelDownloadFile in
            guard safePath(item.relativePath), safePath(item.objectKey),
                  item.objectKey.hasPrefix(prefix), item.bytes > 0, validSHA256(item.sha256),
                  seen.insert(item.relativePath).inserted else { throw ModelDownloadValidationError.invalidManifest }
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            components.path = "/" + item.objectKey
            guard let remoteURL = components.url else { throw ModelDownloadValidationError.invalidManifest }
            return ModelDownloadFile(remotePath: item.objectKey, localPath: item.relativePath,
                                     remoteURL: remoteURL, size: item.bytes, model: spec.model,
                                     sha256: item.sha256.lowercased())
        }
        try validateCoverage(files, spec: spec)
        return .init(source: .mirror, version: payload.version, files: files)
    }

    static func validateCoverage(_ files: [ModelDownloadFile], spec: ModelDownloadSpec) throws {
        let paths = Set(files.map(\.localPath))
        guard !files.isEmpty, paths.count == files.count,
              files.allSatisfy({ safePath($0.localPath) && $0.size >= 0 && $0.model == spec.model
                  && ($0.sha256.map(validSHA256) == true
                      || ($0.gitSHA1?.count == 40 && $0.gitSHA1?.utf8.allSatisfy(isHexByte) == true)) }),
              spec.requiredModels.allSatisfy({ paths.contains("\($0)/coremldata.bin") }),
              spec.requiredSupportingFiles.isSubset(of: paths)
        else { throw ModelDownloadValidationError.invalidManifest }
    }

    static func safePath(_ path: String) -> Bool {
        !path.isEmpty && !path.contains("\\") && !path.contains("%")
            && !path.contains("?") && !path.contains("#") && !path.contains("\n")
            && path.split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    static func validSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy(isHexByte)
    }

    private static func isHexByte(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (97...102).contains(byte) || (65...70).contains(byte)
    }

    static func validate(_ file: ModelDownloadFile, at url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              Int64(values.fileSize ?? -1) == file.size else { throw ModelDownloadValidationError.sizeMismatch }
        if let expected = file.sha256 {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hash = SHA256()
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
            let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard actual == expected.lowercased() else { throw ModelDownloadValidationError.checksumMismatch }
        } else if let expected = file.gitSHA1 {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hash = Insecure.SHA1()
            hash.update(data: Data("blob \(file.size)\0".utf8))
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
            let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard actual == expected.lowercased() else { throw ModelDownloadValidationError.checksumMismatch }
        } else { throw ModelDownloadValidationError.invalidManifest }
    }
}

enum ModelDownloadValidationError: Error, LocalizedError {
    case invalidManifest, sizeMismatch, checksumMismatch, badResponse, modelInUse
    var errorDescription: String? {
        if case .modelInUse = self { return "Wait for the model download to finish before removing it." }
        return "The model download could not be verified. Retry the download."
    }
}

/// Persisted before tasks resume. Each source owns a separate staging directory.
struct ModelDownloadTransaction: Codable, Sendable {
    enum Phase: String, Codable { case downloading, needsFallback, installing, failed }
    var id: UUID
    let modelRawValue: String
    var manifest: ModelDownloadManifest
    var completed: Set<String> = []
    var retries: [String: Int] = [:]
    var phase: Phase = .downloading
    var failureMessage: String?
    var retiredStages: [UUID] = []

    var model: LocalTranscriptionModel? { LocalTranscriptionModel(rawValue: modelRawValue) }
    func accepts(_ file: ModelDownloadFile) -> Bool {
        phase == .downloading && file.attemptID == id && file.model == model
            && !completed.contains(file.localPath)
            && manifest.files.contains { $0.localPath == file.localPath && $0.remoteURL == file.remoteURL }
    }
    func stagingDirectory(for destination: URL) -> URL {
        Self.stagingDirectory(id: id, destination: destination)
    }
    static func stagingDirectory(id: UUID, destination: URL) -> URL {
        destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).download-\(id.uuidString)")
    }
    static func backupDirectory(for destination: URL) -> URL {
        destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).previous-model")
    }
    mutating func useFallback(_ fallback: ModelDownloadManifest) {
        retiredStages.append(id)
        id = UUID()
        manifest = fallback
        completed = []
        retries = [:]
        phase = .downloading
        failureMessage = nil
    }

    static func recoverInstallation(at destination: URL) throws {
        let fm = FileManager.default
        let backup = backupDirectory(for: destination)
        if !fm.fileExists(atPath: destination.path), fm.fileExists(atPath: backup.path) {
            try fm.moveItem(at: backup, to: destination)
        }
    }

    static func install(staging: URL, destination: URL) throws {
        let fm = FileManager.default
        let backup = backupDirectory(for: destination)
        try recoverInstallation(at: destination)
        if fm.fileExists(atPath: backup.path) { try fm.removeItem(at: backup) }
        if fm.fileExists(atPath: destination.path) { try fm.moveItem(at: destination, to: backup) }
        do { try fm.moveItem(at: staging, to: destination) }
        catch {
            try recoverInstallation(at: destination)
            throw error
        }
        // The caller removes the backup only after finalizing readiness.
    }

    static func rollbackInstallation(staging: URL, destination: URL) throws {
        let fm = FileManager.default
        let backup = backupDirectory(for: destination)
        guard fm.fileExists(atPath: backup.path) else { return }
        if fm.fileExists(atPath: destination.path), !fm.fileExists(atPath: staging.path) {
            try fm.moveItem(at: destination, to: staging)
        }
        try recoverInstallation(at: destination)
    }
}
