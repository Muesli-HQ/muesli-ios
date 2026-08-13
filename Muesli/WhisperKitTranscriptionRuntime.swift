import Foundation
@preconcurrency import WhisperKit

actor WhisperKitTranscriptionRuntime {
    private static let completionMarkerName = ".muesli-download-complete"
    private static let requiredModelComponents = [
        "MelSpectrogram",
        "AudioEncoder",
        "TextDecoder",
    ]

    private var whisperKit: WhisperKit?
    private var loadedVariant: String?

    func load(
        variant: String,
        progress: (@Sendable (Double, String?) -> Void)? = nil
    ) async throws {
        if loadedVariant == variant, whisperKit != nil { return }

        try Self.prepareDownloadStorage()

        guard Self.isModelDownloaded(variant) else {
            throw WhisperKitRuntimeError.incompleteDownload
        }
        progress?(0.92, "Loading downloaded Whisper model...")
        let modelFolder = Self.modelDirectory(for: variant)

        progress?(0.94, "Optimizing WhisperKit for this iPhone...")
        let configuration = WhisperKitConfig(
            model: nil,
            modelFolder: modelFolder.path,
            computeOptions: ModelComputeOptions(
                audioEncoderCompute: .cpuAndNeuralEngine,
                textDecoderCompute: .cpuAndNeuralEngine
            )
        )
        do {
            whisperKit = try await WhisperKit(configuration)
            loadedVariant = variant
            progress?(1, "Whisper model ready")
        } catch {
            Self.invalidateCompletionMarker(at: modelFolder)
            throw error
        }
    }

    func transcribe(audioURL: URL) async throws -> String {
        guard let whisperKit else {
            throw WhisperKitRuntimeError.notLoaded
        }
        let results = try await whisperKit.transcribe(audioPath: audioURL.path)
        return results
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func unload() async {
        await whisperKit?.unloadModels()
        whisperKit = nil
        loadedVariant = nil
    }

    static func isModelDownloaded(_ variant: String) -> Bool {
        isModelDownloaded(at: modelDirectory(for: variant))
    }

    static func isModelDownloaded(at directory: URL) -> Bool {
        let marker = directory.appendingPathComponent(completionMarkerName)
        guard FileManager.default.fileExists(atPath: marker.path) else { return false }
        return requiredModelComponents.allSatisfy { modelComponentExists(named: $0, in: directory) }
    }

    static func modelDirectory(for variant: String) -> URL {
        let fullName = variant.hasPrefix("openai_whisper-")
            ? variant
            : "openai_whisper-\(variant)"
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("huggingface", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(fullName, isDirectory: true)
    }

    static func markDownloadComplete(at directory: URL) throws {
        guard requiredModelComponents.allSatisfy({ modelComponentExists(named: $0, in: directory) }) else {
            throw WhisperKitRuntimeError.incompleteDownload
        }
        try Data().write(
            to: directory.appendingPathComponent(completionMarkerName),
            options: .atomic
        )
    }

    private static func prepareDownloadStorage() throws {
        try FileManager.default.createDirectory(
            at: downloadStorageDirectory,
            withIntermediateDirectories: true
        )
        try excludeDownloadStorageFromBackup()
    }

    private static var downloadStorageDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("huggingface", isDirectory: true)
    }

    private static func excludeDownloadStorageFromBackup() throws {
        var directory = downloadStorageDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
    }

    private static func invalidateCompletionMarker(at directory: URL) {
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent(completionMarkerName)
        )
    }

    private static func modelComponentExists(named name: String, in directory: URL) -> Bool {
        let compiled = directory.appendingPathComponent("\(name).mlmodelc", isDirectory: true)
        if directoryContainsNonemptyFile(compiled) {
            return true
        }

        let packagedModel = directory
            .appendingPathComponent("\(name).mlpackage", isDirectory: true)
            .appendingPathComponent("Data/com.apple.CoreML/model.mlmodel")
        guard let values = try? packagedModel.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else {
            return false
        }
        return values.isRegularFile == true && (values.fileSize ?? 0) > 0
    }

    private static func directoryContainsNonemptyFile(_ directory: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else {
                continue
            }
            if values.isRegularFile == true, (values.fileSize ?? 0) > 0 {
                return true
            }
        }
        return false
    }

}

private enum WhisperKitRuntimeError: LocalizedError {
    case notLoaded
    case incompleteDownload

    var errorDescription: String? {
        switch self {
        case .notLoaded:
            "WhisperKit model is not loaded."
        case .incompleteDownload:
            "The WhisperKit model download is incomplete."
        }
    }
}
