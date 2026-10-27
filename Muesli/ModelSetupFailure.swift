import Foundation

/// Do not expose raw errors here: they can contain local paths or signed URLs.
struct ModelSetupFailure {
    let status: String
    let detail: String

    static func describe(_ error: Error) -> Self {
        if let storage = error as? ModelStorageError {
            return .init(status: "More storage needed", detail: storage.localizedDescription)
        }
        var current = error as NSError
        var visited = Set<ObjectIdentifier>()
        var isNetworkFailure = false
        while visited.insert(ObjectIdentifier(current)).inserted {
            if (current.domain == NSCocoaErrorDomain && current.code == NSFileWriteOutOfSpaceError)
                || (current.domain == NSPOSIXErrorDomain && current.code == 28) {
                return .init(status: "More storage needed",
                             detail: "Free up space in iPhone Settings, then retry setup. Downloaded model files are kept.")
            }
            if current.domain == NSURLErrorDomain {
                isNetworkFailure = isNetworkFailure || [NSURLErrorNotConnectedToInternet,
                    NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut, NSURLErrorCannotFindHost,
                    NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed,
                    NSURLErrorDataNotAllowed].contains(current.code)
            }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            current = underlying
        }
        if isNetworkFailure {
            return .init(status: "Connection interrupted", detail: "Check your connection, then retry setup.")
        }
        return .init(status: "Model setup failed",
                     detail: "The model could not be prepared on this iPhone. Retry setup, or choose a smaller model. If it keeps failing, remove this model and download it again.")
    }
}

enum ModelStorageError: LocalizedError {
    case insufficientSpace(required: Int64, available: Int64)

    var errorDescription: String? {
        switch self {
        case .insufficientSpace(let required, let available):
            "Model setup needs about \(ByteCountFormatter.string(fromByteCount: required, countStyle: .decimal)) of free space; \(ByteCountFormatter.string(fromByteCount: available, countStyle: .decimal)) is available. Free up space in iPhone Settings or choose a smaller model, then retry setup."
        }
    }
}

enum ModelSetupStorage {
    /// Conservative workspace allowance for model optimization, not an exact
    /// prediction of Core ML's peak usage.
    static func requiredBytes(downloadBytes: Int64, modelBytes: Int64) -> Int64 {
        max(0, downloadBytes) + max(512_000_000, max(0, modelBytes) * 2)
    }

    static func check(availableBytes: Int64?, requiredBytes: Int64) throws {
        guard let availableBytes, availableBytes >= 0 else { return }
        guard availableBytes >= requiredBytes else {
            throw ModelStorageError.insufficientSpace(required: requiredBytes, available: availableBytes)
        }
    }

    static func check(at directory: URL, downloadBytes: Int64, modelBytes: Int64) throws {
        let values = try? directory.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey
        ])
        let available = values?.volumeAvailableCapacityForImportantUsage
            ?? values?.volumeAvailableCapacity.map(Int64.init)
        try check(availableBytes: available,
                  requiredBytes: requiredBytes(downloadBytes: downloadBytes, modelBytes: modelBytes))
    }
}
