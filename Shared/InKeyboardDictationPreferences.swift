import Foundation

/// Preferences the keyboard extension needs for in-keyboard dictation.
///
/// The app's other preferences live in `UserDefaults.standard`, which the
/// keyboard process cannot read. These are stored in the App Group suite so
/// both processes see the same values. Post-processing flags are mirrored from
/// the app's standard defaults by `mirrorPostProcessing(...)`.
enum InKeyboardDictationPreferences {
    static let enabledKey = "muesli.keyboard.inKeyboardDictation.enabled"
    static let fillerWordRemovalKey = "muesli.keyboard.inKeyboardDictation.fillerWordRemoval"
    static let customDictionaryKey = "muesli.keyboard.inKeyboardDictation.customDictionary"
    static let liveTranscriptKey = "muesli.keyboard.inKeyboardDictation.liveTranscript"
    /// In-keyboard dictation is the default way to record from the keyboard.
    static let enabledByDefault = true
    static let liveTranscriptByDefault = false

    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: MuesliAppConstants.appGroupIdentifier)
    }

    static func isEnabled(in defaults: UserDefaults? = sharedDefaults) -> Bool {
        bool(enabledKey, defaultValue: enabledByDefault, in: defaults)
    }

    /// Show the live transcript instead of the waveform while dictating.
    static func showsLiveTranscript(in defaults: UserDefaults? = sharedDefaults) -> Bool {
        bool(liveTranscriptKey, defaultValue: liveTranscriptByDefault, in: defaults)
    }

    static func fillerWordRemovalEnabled(in defaults: UserDefaults? = sharedDefaults) -> Bool {
        bool(fillerWordRemovalKey, defaultValue: true, in: defaults)
    }

    static func customDictionaryEnabled(in defaults: UserDefaults? = sharedDefaults) -> Bool {
        bool(customDictionaryKey, defaultValue: true, in: defaults)
    }

    static func mirrorPostProcessing(
        fillerWordRemoval: Bool,
        customDictionary: Bool,
        in defaults: UserDefaults? = sharedDefaults
    ) {
        defaults?.set(fillerWordRemoval, forKey: fillerWordRemovalKey)
        defaults?.set(customDictionary, forKey: customDictionaryKey)
    }

    /// Applies the same filler-word and custom-dictionary pass the app's
    /// `TranscriptPostProcessor` runs, using the mirrored flags.
    static func postProcess(
        _ text: String,
        customWords: [CustomWord],
        defaults: UserDefaults? = sharedDefaults
    ) -> String {
        var processed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !processed.isEmpty else { return processed }
        if fillerWordRemovalEnabled(in: defaults) {
            processed = FillerWordFilter.apply(processed)
        }
        if customDictionaryEnabled(in: defaults), !customWords.isEmpty {
            processed = CustomWordMatcher.apply(text: processed, customWords: customWords)
        }
        return processed
    }

    private static func bool(_ key: String, defaultValue: Bool, in defaults: UserDefaults?) -> Bool {
        guard let defaults, defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }
}
