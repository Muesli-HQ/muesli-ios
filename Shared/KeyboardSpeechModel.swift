import Foundation

/// Contract between the app and the keyboard for running a Parakeet model
/// inside the keyboard extension.
///
/// The keyboard cannot read the app's private model folder. The app clones
/// every downloaded model the keyboard can run into the App Group
/// (`KeyboardModels/<id>`) and lists them in `keyboard-models.json`. APFS
/// clones share blocks, so this costs no extra disk until either copy changes.
/// The keyboard loads whichever model is selected in the keyboard model
/// catalog, so a model picked in the keyboard switches at once, without the
/// app. The keyboard reports its memory limit and whether its copy is loaded.
enum KeyboardSpeechModel {
    /// The keyboard's memory limit must be at least this. iOS 26 gives
    /// keyboards about 177 MB on recent iPhones. A loaded Parakeet model plus
    /// recording has been measured at about 91 MB in another keyboard
    /// (Hex PR #2390), and this adds headroom for Muesli's UI and WebKit.
    static let requiredMemoryLimitBytes: UInt64 = 131 * 1_024 * 1_024
    /// Free memory the keyboard needs right before loading or transcribing.
    static let requiredAvailableBytes: UInt64 = 60 * 1_024 * 1_024
    /// Longest recording Parakeet transcribes in the keyboard. Longer ones use
    /// Apple Speech's transcript, so the sample buffer stays small (~6 MB).
    static let maximumDurationSeconds: Double = 180

    static let catalogFileName = "keyboard-models.json"
    static let memoryLimitKey = "muesli.keyboard.memoryLimitBytes"
    static let unsupportedModelsKey = "muesli.keyboard.unsupportedModels.v2"
    /// Model ID -> fingerprint for each load in progress, one per model.
    static let loadingModelsKey = "muesli.keyboard.loadingModels.v2"

    /// Model families the keyboard loads. All use the ANE/CPU, never the GPU.
    enum Version: String, Codable, Sendable {
        case tdtCtc110m
        case v3
        /// Its encoder runs on the CPU only, as in the app (no 2-bit ANE path).
        case redux
        /// Phonon 2.5: a v3-family model; encoder on the CPU, as in the app.
        case phonon
        case unified
        /// Nemotron 3.5 streaming multilingual.
        case nemotron
        /// Parakeet Realtime (EOU) with 320 ms chunks.
        case eou320
        /// A WhisperKit model; its tokenizer is shared in the same folder.
        case whisper
    }

    struct Manifest: Codable, Equatable, Sendable {
        var modelID: String
        var displayName: String
        var engineIdentifier: String
        var version: Version
        /// Identifies the app's verified download, so a re-download is re-shared.
        var sourceFingerprint: String
    }

    static var containerURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: MuesliAppConstants.appGroupIdentifier
        )
    }

    static func rootDirectory(in container: URL? = containerURL) -> URL? {
        container?.appendingPathComponent("KeyboardModels", isDirectory: true)
    }

    static func modelDirectory(for modelID: String, in container: URL? = containerURL) -> URL? {
        rootDirectory(in: container)?.appendingPathComponent(modelID, isDirectory: true)
    }

    /// Every model shared with the keyboard.
    struct Catalog: Codable, Equatable, Sendable {
        var models: [Manifest]
    }

    static func readCatalog(in container: URL? = containerURL) -> Catalog? {
        guard let url = rootDirectory(in: container)?.appendingPathComponent(catalogFileName),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Catalog.self, from: data)
    }

    /// The shared copy of `modelID`, if the keyboard can run it.
    static func readManifest(for modelID: String?, in container: URL? = containerURL) -> Manifest? {
        guard let modelID else { return nil }
        return readCatalog(in: container)?.models.first { $0.modelID == modelID }
    }

    // MARK: - Keyboard reports

    static func reportedMemoryLimit(in defaults: UserDefaults? = InKeyboardDictationPreferences.sharedDefaults) -> UInt64? {
        guard let value = defaults?.object(forKey: memoryLimitKey) as? NSNumber else { return nil }
        return value.uint64Value
    }

    static func recordMemoryLimit(_ bytes: UInt64, in defaults: UserDefaults? = InKeyboardDictationPreferences.sharedDefaults) {
        defaults?.set(NSNumber(value: bytes), forKey: memoryLimitKey)
    }

    // MARK: - Crash guard

    /// Unfinished loads in a row before a model counts as one the keyboard
    /// can't run. One isn't enough: iOS also ends a keyboard that was simply
    /// closed while a long first load was running.
    static let unfinishedLoadLimit = 2

    /// Marks a load as started. If iOS ends the keyboard before `endLoad`,
    /// the marker remains and the next `beginLoad` of the same download counts
    /// it. Kept per model, so loading another model never erases this record.
    static func beginLoad(
        _ manifest: Manifest,
        in defaults: UserDefaults? = InKeyboardDictationPreferences.sharedDefaults
    ) {
        let attempts = unfinishedLoads(manifest: manifest, in: defaults) + 1
        var loading = defaults?.dictionary(forKey: loadingModelsKey) as? [String: String] ?? [:]
        loading[manifest.modelID] = "\(manifest.sourceFingerprint)#\(attempts)"
        defaults?.set(loading, forKey: loadingModelsKey)
    }

    /// The load finished, failed, or was cancelled on purpose (memory warning,
    /// model switch). None of those is a crash.
    static func endLoad(
        _ manifest: Manifest,
        in defaults: UserDefaults? = InKeyboardDictationPreferences.sharedDefaults
    ) {
        var loading = defaults?.dictionary(forKey: loadingModelsKey) as? [String: String] ?? [:]
        guard loading.removeValue(forKey: manifest.modelID) != nil else { return }
        defaults?.set(loading, forKey: loadingModelsKey)
    }

    /// How many loads of this exact download in a row started and never
    /// finished, because iOS ended the keyboard during them.
    static func unfinishedLoads(
        manifest: Manifest,
        in defaults: UserDefaults? = InKeyboardDictationPreferences.sharedDefaults
    ) -> Int {
        let loading = defaults?.dictionary(forKey: loadingModelsKey) as? [String: String] ?? [:]
        guard let record = loading[manifest.modelID] else { return 0 }
        let parts = record.split(separator: "#", omittingEmptySubsequences: false)
        guard parts.count > 1, let count = Int(parts.last!) else {
            return record == manifest.sourceFingerprint ? 1 : 0
        }
        return parts.dropLast().joined(separator: "#") == manifest.sourceFingerprint ? count : 0
    }

    /// True when the keyboard started loading this exact download and never
    /// finished.
    static func previousLoadDidNotFinish(
        manifest: Manifest,
        in defaults: UserDefaults? = InKeyboardDictationPreferences.sharedDefaults
    ) -> Bool {
        unfinishedLoads(manifest: manifest, in: defaults) > 0
    }

    /// True once loads of this download were cut short `unfinishedLoadLimit`
    /// times in a row: most likely the model ends the keyboard.
    static func keepsEndingTheKeyboard(
        manifest: Manifest,
        in defaults: UserDefaults? = InKeyboardDictationPreferences.sharedDefaults
    ) -> Bool {
        unfinishedLoads(manifest: manifest, in: defaults) >= unfinishedLoadLimit
    }

    // MARK: - What the keyboard can run

    /// Records that this download can't run in the keyboard (its load failed
    /// or ended the keyboard), so the keyboard's model menu hides it. A new
    /// download of the model is tried again.
    static func markUnsupported(
        _ manifest: Manifest,
        in defaults: UserDefaults? = InKeyboardDictationPreferences.sharedDefaults
    ) {
        var unsupported = defaults?.dictionary(forKey: unsupportedModelsKey) as? [String: String] ?? [:]
        unsupported[manifest.modelID] = manifest.sourceFingerprint
        defaults?.set(unsupported, forKey: unsupportedModelsKey)
    }

    /// True once this download failed to load or ended the keyboard.
    static func isUnsupported(
        _ manifest: Manifest,
        in defaults: UserDefaults? = InKeyboardDictationPreferences.sharedDefaults
    ) -> Bool {
        let unsupported = defaults?.dictionary(forKey: unsupportedModelsKey) as? [String: String] ?? [:]
        return unsupported[manifest.modelID] == manifest.sourceFingerprint
    }

    /// Model IDs the keyboard can transcribe with itself: shared by the app,
    /// not known to fail, and only when the keyboard's memory limit allows a
    /// model at all. Apple Speech isn't included; it always runs.
    static func runnableModelIDs(
        in container: URL? = containerURL,
        defaults: UserDefaults? = InKeyboardDictationPreferences.sharedDefaults
    ) -> Set<String> {
        if let limit = reportedMemoryLimit(in: defaults), !canHoldModel(memoryLimit: limit) {
            return []
        }
        let unsupported = defaults?.dictionary(forKey: unsupportedModelsKey) as? [String: String] ?? [:]
        let models = readCatalog(in: container)?.models ?? []
        return Set(models.filter { unsupported[$0.modelID] != $0.sourceFingerprint }.map(\.modelID))
    }

    static func canHoldModel(memoryLimit: UInt64?) -> Bool {
        guard let memoryLimit else { return false }
        return memoryLimit >= requiredMemoryLimitBytes
    }
}
