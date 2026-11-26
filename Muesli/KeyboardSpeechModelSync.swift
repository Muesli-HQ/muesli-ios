import Foundation

/// Shares the selected Parakeet model with the keyboard extension by cloning
/// it into the App Group (see `KeyboardSpeechModel`). The keyboard decides
/// whether it can load it from its own measured memory limit, and otherwise
/// keeps using Apple Speech.
@MainActor
enum KeyboardSpeechModelSync {
    private static var isSyncing = false
    private static var needsAnotherPass = false

    /// Models the keyboard can try: every downloadable model. Whether one fits
    /// is decided in the keyboard from its measured memory; a model that fails
    /// or ends the keyboard while loading is hidden from the keyboard's model
    /// menu for that download.
    static func keyboardVersion(for model: LocalTranscriptionModel) -> KeyboardSpeechModel.Version? {
        switch model {
        case .parakeetTdtCtc110m: .tdtCtc110m
        case .parakeetV3: .v3
        case .parakeetRedux: .redux
        case .phonon25: .phonon
        case .parakeetUnified: .unified
        case .nemotron35: .nemotron
        case .parakeetRealtimeEou120m: .eou320
        case .whisperTinyEnglish, .whisperSmallEnglish, .whisperMediumEnglish, .whisperLargeTurbo: .whisper
        case .appleSpeech: nil
        }
    }

    /// WhisperKit finds a tokenizer in the model folder, so the shared copy
    /// carries one and the keyboard never downloads it. The app keeps it in
    /// the Hugging Face cache under the tokenizer's repo name.
    static func whisperTokenizerFiles(for model: LocalTranscriptionModel) -> [URL] {
        let repo: String? = switch model {
        case .whisperTinyEnglish: "whisper-tiny.en"
        case .whisperSmallEnglish: "whisper-small.en"
        case .whisperMediumEnglish: "whisper-medium.en"
        case .whisperLargeTurbo: "whisper-large-v3"
        default: nil
        }
        guard let repo else { return [] }
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("huggingface/models/openai/\(repo)", isDirectory: true)
        return ["tokenizer.json", "tokenizer_config.json"]
            .map { folder.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Brings the App Group copies in line with the downloaded models. Runs
    /// file work off the main actor and coalesces overlapping calls.
    static func sync() {
        guard !isSyncing else {
            needsAnotherPass = true
            return
        }
        isSyncing = true
        let plan = makePlan()
        Task.detached(priority: .utility) {
            let outcome = apply(plan)
            await MainActor.run {
                AppTelemetry.signal("keyboard_model_sync", parameters: ["outcome": outcome])
                isSyncing = false
                if needsAnotherPass {
                    needsAnotherPass = false
                    sync()
                }
            }
        }
    }

    struct Entry: Sendable {
        var source: URL
        var manifest: KeyboardSpeechModel.Manifest
        /// Copied into the model's shared folder (Whisper's tokenizer).
        var extraFiles: [URL] = []
    }

    struct Plan: Sendable {
        var entries: [Entry]
    }

    static func makePlan(
        models: [LocalTranscriptionModel] = LocalTranscriptionModel.allCases,
        isDownloaded: (LocalTranscriptionModel) -> Bool = { ModelBackgroundDownloadService.isModelDownloaded($0) }
    ) -> Plan {
        Plan(entries: models.compactMap { model in
            guard let version = keyboardVersion(for: model),
                  isDownloaded(model),
                  let source = ModelBackgroundDownloadService.storageDirectory(for: model) else { return nil }
            return Entry(source: source, manifest: KeyboardSpeechModel.Manifest(
                modelID: model.rawValue,
                displayName: model.shortName,
                engineIdentifier: model.engineIdentifier,
                version: version,
                sourceFingerprint: fingerprint(of: source)
            ), extraFiles: whisperTokenizerFiles(for: model))
        })
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
        let catalogURL = root.appendingPathComponent(KeyboardSpeechModel.catalogFileName)

        guard !plan.entries.isEmpty else {
            guard fileManager.fileExists(atPath: root.path) else { return "none" }
            try? fileManager.removeItem(at: root)
            return "removed"
        }

        let existing = KeyboardSpeechModel.readCatalog(in: container)?.models ?? []
        let changed = plan.entries.filter { entry in
            guard let directory = KeyboardSpeechModel.modelDirectory(for: entry.manifest.modelID, in: container) else {
                return true
            }
            return !existing.contains(entry.manifest) || !fileManager.fileExists(atPath: directory.path)
        }
        let wanted = Set(plan.entries.map(\.manifest.modelID))
        let stale = existing.filter { !wanted.contains($0.modelID) }
        if changed.isEmpty, stale.isEmpty {
            return "current"
        }

        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            var excluded = URLResourceValues()
            excluded.isExcludedFromBackup = true
            var rootURL = root
            try? rootURL.setResourceValues(excluded)

            // The keyboard must never load a half-written model: list only the
            // untouched models while copies change, then the full set.
            let changedIDs = Set(changed.map(\.manifest.modelID))
            let untouched = existing.filter { wanted.contains($0.modelID) && !changedIDs.contains($0.modelID) }
            try write(KeyboardSpeechModel.Catalog(models: untouched), to: catalogURL)

            for entry in changed {
                guard let destination = KeyboardSpeechModel.modelDirectory(for: entry.manifest.modelID, in: container) else {
                    continue
                }
                let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
                // APFS clones the files, so this uses no extra disk.
                try fileManager.copyItem(at: entry.source, to: staging)
                for file in entry.extraFiles {
                    let target = staging.appendingPathComponent(file.lastPathComponent)
                    if !fileManager.fileExists(atPath: target.path) {
                        try fileManager.copyItem(at: file, to: target)
                    }
                }
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.moveItem(at: staging, to: destination)
            }

            let keep = wanted.union([KeyboardSpeechModel.catalogFileName])
            for item in (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            where !keep.contains(item.lastPathComponent) {
                try? fileManager.removeItem(at: item)
            }
            try write(KeyboardSpeechModel.Catalog(models: plan.entries.map(\.manifest)), to: catalogURL)
            return "shared"
        } catch {
            return "failed"
        }
    }

    nonisolated private static func write(_ catalog: KeyboardSpeechModel.Catalog, to url: URL) throws {
        try JSONEncoder().encode(catalog).write(to: url, options: .atomic)
    }
}
