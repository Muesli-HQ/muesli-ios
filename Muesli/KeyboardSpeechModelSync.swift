import Foundation

/// Shares the selected Parakeet model with the keyboard extension by cloning
/// it into the App Group (see `KeyboardSpeechModel`). The keyboard decides
/// whether it can load it from its own measured memory limit, and otherwise
/// keeps using Apple Speech.
@MainActor
enum KeyboardSpeechModelSync {
    private static var isSyncing = false
    private static var needsAnotherPass = false

    /// Models the keyboard can try. Whether one fits is decided in the
    /// keyboard from its measured memory; a model that ends the keyboard while
    /// loading is not tried again for that download. Whisper needs WhisperKit,
    /// which the keyboard does not link.
    static func keyboardVersion(for model: LocalTranscriptionModel) -> KeyboardSpeechModel.Version? {
        switch model {
        case .parakeetTdtCtc110m: .tdtCtc110m
        case .parakeetV3: .v3
        case .parakeetRedux: .redux
        case .phonon25: .phonon
        case .parakeetUnified: .unified
        case .nemotron35: .nemotron
        case .parakeetRealtimeEou120m: .eou320
        case .appleSpeech, .whisperTinyEnglish, .whisperSmallEnglish, .whisperMediumEnglish, .whisperLargeTurbo: nil
        }
    }

    /// Brings the App Group copy in line with the selected model. Runs file
    /// work off the main actor and coalesces overlapping calls.
    static func sync(selectedModel: LocalTranscriptionModel) {
        guard !isSyncing else {
            needsAnotherPass = true
            return
        }
        isSyncing = true
        let plan = makePlan(for: selectedModel)
        Task.detached(priority: .utility) {
            let outcome = apply(plan)
            await MainActor.run {
                AppTelemetry.signal("keyboard_model_sync", parameters: ["outcome": outcome])
                isSyncing = false
                if needsAnotherPass {
                    needsAnotherPass = false
                    sync(selectedModel: MuesliPreferences.transcriptionModel)
                }
            }
        }
    }

    enum Plan: Sendable {
        case remove
        case share(source: URL, manifest: KeyboardSpeechModel.Manifest)
    }

    static func makePlan(for model: LocalTranscriptionModel) -> Plan {
        guard let version = keyboardVersion(for: model),
              ModelBackgroundDownloadService.isModelDownloaded(model),
              let source = ModelBackgroundDownloadService.storageDirectory(for: model) else {
            return .remove
        }
        return .share(source: source, manifest: KeyboardSpeechModel.Manifest(
            modelID: model.rawValue,
            displayName: model.shortName,
            engineIdentifier: model.engineIdentifier,
            version: version,
            sourceFingerprint: fingerprint(of: source)
        ))
    }

    /// Changes when the app re-downloads or re-verifies the model.
    nonisolated static func fingerprint(of directory: URL) -> String {
        let receipt = directory.appendingPathComponent(".muesli-verified-manifest.json")
        let attributes = try? FileManager.default.attributesOfItem(atPath: receipt.path)
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        return "\(Int(modified))-\(size)"
    }

    /// Returns a short outcome for telemetry.
    nonisolated static func apply(_ plan: Plan, container: URL? = KeyboardSpeechModel.containerURL) -> String {
        let fileManager = FileManager.default
        guard let root = KeyboardSpeechModel.rootDirectory(in: container) else { return "noContainer" }
        let manifestURL = root.appendingPathComponent(KeyboardSpeechModel.manifestFileName)

        switch plan {
        case .remove:
            guard fileManager.fileExists(atPath: root.path) else { return "none" }
            try? fileManager.removeItem(at: root)
            return "removed"

        case .share(let source, let manifest):
            guard let destination = KeyboardSpeechModel.modelDirectory(for: manifest.modelID, in: container) else {
                return "noContainer"
            }
            if KeyboardSpeechModel.readManifest(in: container) == manifest,
               fileManager.fileExists(atPath: destination.path) {
                return "current"
            }
            do {
                try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
                var excluded = URLResourceValues()
                excluded.isExcludedFromBackup = true
                var rootURL = root
                try? rootURL.setResourceValues(excluded)

                // The keyboard must never see a half-written model: withdraw
                // the manifest first, clone beside, then swap into place.
                try? fileManager.removeItem(at: manifestURL)
                let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
                // APFS clones the files, so this uses no extra disk.
                try fileManager.copyItem(at: source, to: staging)
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.moveItem(at: staging, to: destination)

                for entry in (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
                where entry.lastPathComponent != manifest.modelID {
                    try? fileManager.removeItem(at: entry)
                }
                let data = try JSONEncoder().encode(manifest)
                try data.write(to: manifestURL, options: .atomic)
                return "shared"
            } catch {
                return "failed"
            }
        }
    }
}
