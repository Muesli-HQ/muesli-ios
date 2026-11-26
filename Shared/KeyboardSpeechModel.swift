import Foundation

/// Contract between the app and the keyboard for running a Parakeet model
/// inside the keyboard extension.
///
/// The keyboard cannot read the app's private model folder. The app clones the
/// selected Parakeet model into the App Group (`KeyboardModels/<id>`). APFS
/// clones share blocks, so this costs no extra disk until either copy changes.
/// It then writes `keyboard-model.json`. The keyboard reports its memory limit,
/// so the app only shares a model the keyboard can hold, and the keyboard
/// reports whether its copy is loaded.
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

    static let manifestFileName = "keyboard-model.json"
    static let memoryLimitKey = "muesli.keyboard.memoryLimitBytes"
    static let keyboardStateKey = "muesli.keyboard.parakeet.state"
    static let keyboardStateModelKey = "muesli.keyboard.parakeet.stateModel"
    static let keyboardStateFingerprintKey = "muesli.keyboard.parakeet.stateFingerprint"

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
    }

    struct Manifest: Codable, Equatable, Sendable {
        var modelID: String
        var displayName: String
        var engineIdentifier: String
        var version: Version
        /// Identifies the app's verified download, so a re-download is re-shared.
        var sourceFingerprint: String
    }

    /// What the keyboard last reported about its copy.
    enum KeyboardState: String, Sendable {
        case loading
        case ready
        case tooLittleMemory
        case failed
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

    static func readManifest(in container: URL? = containerURL) -> Manifest? {
        guard let url = rootDirectory(in: container)?.appendingPathComponent(manifestFileName),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    // MARK: - Keyboard reports

    static func reportedMemoryLimit(in defaults: UserDefaults? = InKeyboardDictationPreferences.sharedDefaults) -> UInt64? {
        guard let value = defaults?.object(forKey: memoryLimitKey) as? NSNumber else { return nil }
        return value.uint64Value
    }

    static func recordMemoryLimit(_ bytes: UInt64, in defaults: UserDefaults? = InKeyboardDictationPreferences.sharedDefaults) {
        defaults?.set(NSNumber(value: bytes), forKey: memoryLimitKey)
    }

    static func keyboardState(in defaults: UserDefaults? = InKeyboardDictationPreferences.sharedDefaults) -> (KeyboardState, String)? {
        guard let raw = defaults?.string(forKey: keyboardStateKey),
              let state = KeyboardState(rawValue: raw),
              let model = defaults?.string(forKey: keyboardStateModelKey) else { return nil }
        return (state, model)
    }

    static func recordKeyboardState(
        _ state: KeyboardState,
        modelID: String,
        fingerprint: String? = nil,
        in defaults: UserDefaults? = InKeyboardDictationPreferences.sharedDefaults
    ) {
        defaults?.set(state.rawValue, forKey: keyboardStateKey)
        defaults?.set(modelID, forKey: keyboardStateModelKey)
        defaults?.set(fingerprint, forKey: keyboardStateFingerprintKey)
    }

    /// True when the keyboard started loading this exact model and never
    /// finished: iOS most likely ended the keyboard for using too much memory.
    /// The keyboard then stays on Apple Speech for this download instead of
    /// crashing on every open.
    static func previousLoadDidNotFinish(
        manifest: Manifest,
        in defaults: UserDefaults? = InKeyboardDictationPreferences.sharedDefaults
    ) -> Bool {
        let state = defaults?.string(forKey: keyboardStateKey)
        let fingerprint = defaults?.string(forKey: keyboardStateFingerprintKey)
        let model = defaults?.string(forKey: keyboardStateModelKey)
        return (state == KeyboardState.loading.rawValue || state == KeyboardState.failed.rawValue)
            && model == manifest.modelID
            && fingerprint == manifest.sourceFingerprint
    }

    static func canHoldModel(memoryLimit: UInt64?) -> Bool {
        guard let memoryLimit else { return false }
        return memoryLimit >= requiredMemoryLimitBytes
    }
}
