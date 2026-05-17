import Foundation

struct TranscriptPostProcessor {
    private let store: SharedStore

    init(store: SharedStore) {
        self.store = store
    }

    func process(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        var processed = text
        if MuesliPreferences.fillerWordRemovalEnabled {
            processed = FillerWordFilter.apply(processed)
        }

        if MuesliPreferences.customDictionaryEnabled,
           let customWords = try? store.customWords(),
           !customWords.isEmpty {
            processed = CustomWordMatcher.apply(text: processed, customWords: customWords)
        }

        return processed
    }
}
