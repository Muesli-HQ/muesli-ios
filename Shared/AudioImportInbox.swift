import Foundation

/// A durable handoff: publish the directory only after both audio and metadata exist.
enum AudioImportInbox {
    enum ImportError: LocalizedError {
        case unsupportedFormat, emptyFile
        var errorDescription: String? {
            switch self {
            case .unsupportedFormat: "Choose a WAV, MP3, M4A, MP4, AIFF, or CAF audio file."
            case .emptyFile: "This file is empty or is not a regular audio file."
            }
        }
    }
    static let extensions: Set<String> = ["wav", "mp3", "m4a", "mp4", "aiff", "aif", "caf"]
    struct Item: Codable, Identifiable, Sendable {
        let id: UUID
        let title: String
        let fileName: String
    }
    #if DEBUG && targetEnvironment(simulator)
    // Unsigned UI-test apps have no App Group entitlement. Keep their inbox
    // isolated per launch, just like the coordinator's fixture store.
    private static let uiTestRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("AudioImportUITests-" + UUID().uuidString, isDirectory: true)
    #endif

    static func directory() throws -> URL {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains(MuesliAppConstants.uiTestingLaunchArgument) {
            try FileManager.default.createDirectory(at: uiTestRoot, withIntermediateDirectories: true)
            return uiTestRoot
        }
        #endif
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: MuesliAppConstants.appGroupIdentifier) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let url = root.appendingPathComponent("AudioImports", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func enqueue(_ source: URL, title: String? = nil, root: URL? = nil) throws -> Item {
        guard extensions.contains(source.pathExtension.lowercased()) else { throw ImportError.unsupportedFormat }
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let root = try root ?? directory()
        let item = Item(id: UUID(), title: title ?? source.deletingPathExtension().lastPathComponent,
                        fileName: "audio.\(source.pathExtension.lowercased())")
        let stage = root.appendingPathComponent(".\(item.id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        // File providers may need to download/materialize the selected file first.
        // Coordinate the read instead of copying an uncoordinated provider URL.
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { readable in
            do {
                let values = try readable.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else { throw ImportError.emptyFile }
                try FileManager.default.copyItem(at: readable, to: stage.appendingPathComponent(item.fileName))
            } catch { copyError = error }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
        try JSONEncoder().encode(item).write(to: stage.appendingPathComponent("item.json"), options: .atomic)
        try FileManager.default.moveItem(at: stage, to: root.appendingPathComponent(item.id.uuidString))
        return item
    }
    static func items(root: URL? = nil) throws -> [Item] {
        let root = try root ?? directory()
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url.appendingPathComponent("item.json")),
                      let item = try? JSONDecoder().decode(Item.self, from: data),
                      item.id.uuidString == url.lastPathComponent,
                      item.fileName == "audio.\(URL(fileURLWithPath: item.fileName).pathExtension)",
                      extensions.contains(URL(fileURLWithPath: item.fileName).pathExtension) else { return nil }
                return item
            }
    }
    static func audioURL(_ item: Item) throws -> URL {
        try directory().appendingPathComponent(item.id.uuidString).appendingPathComponent(item.fileName)
    }
    static func remove(_ item: Item) throws {
        try FileManager.default.removeItem(at: directory().appendingPathComponent(item.id.uuidString))
    }
}
