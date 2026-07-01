import SwiftUI

struct DictionaryView: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                DictionarySettingsContent()
                    .padding(.horizontal, MuesliTheme.spacing20)
                    .padding(.top, MuesliTheme.spacing24)
                    .padding(.bottom, MuesliTheme.spacing24)
            }
            .background(MuesliTheme.backgroundBase)
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

struct DictionarySettingsContent: View {
    @AppStorage(MuesliPreferences.fillerWordRemovalKey) private var fillerWordRemoval = true
    @AppStorage(MuesliPreferences.customDictionaryKey) private var customDictionary = true
    @State private var customWords: [CustomWord] = []
    @State private var newWord = ""
    @State private var newReplacement = ""
    @State private var dictionaryError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing20) {
            header
            cleanupPanel
            dictionaryPanel
        }
        .onAppear(perform: loadCustomWords)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
            Text("Dictionary")
                .font(MuesliTheme.title1())
                .foregroundStyle(MuesliTheme.textPrimary)
            Text("Tune post-processing for names, brands, acronyms, and repeated transcription mistakes.")
                .font(MuesliTheme.callout())
                .foregroundStyle(MuesliTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var cleanupPanel: some View {
        MuesliSurface {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                DictionaryToggleRow(
                    icon: "text.word.spacing",
                    title: "Remove Filler Words",
                    detail: "Remove common speech fillers before voice notes and meeting transcripts are saved.",
                    isOn: $fillerWordRemoval
                )
                Divider().overlay(MuesliTheme.surfaceBorder)
                DictionaryToggleRow(
                    icon: "character.book.closed",
                    title: "Use Custom Dictionary",
                    detail: "Apply your word and phrase corrections after local transcription.",
                    isOn: $customDictionary
                )
            }
            .padding(MuesliTheme.spacing16)
        }
    }

    private var dictionaryPanel: some View {
        MuesliSurface {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                        Text("Custom Words")
                            .font(MuesliTheme.title3())
                            .foregroundStyle(MuesliTheme.textPrimary)
                        Text("\(customWords.count) saved")
                            .font(MuesliTheme.caption())
                            .foregroundStyle(MuesliTheme.textTertiary)
                    }

                    Spacer()
                }

                VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                    TextField("Word or phrase", text: $newWord)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                    TextField("Replace with (optional)", text: $newReplacement)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                    Button {
                        addCustomWord()
                    } label: {
                        Label("Add Dictionary Entry", systemImage: "plus")
                            .font(MuesliTheme.headline())
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .foregroundStyle(.white)
                            .background(
                                newWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? MuesliTheme.surfacePrimary
                                    : MuesliTheme.accent
                            )
                            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                            .contentShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                    }
                    .buttonStyle(.plain)
                    .disabled(newWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if let dictionaryError {
                    Text(dictionaryError)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.recording)
                }

                if customWords.isEmpty {
                    emptyState
                } else {
                    LazyVStack(spacing: MuesliTheme.spacing8) {
                        ForEach(customWords) { customWord in
                            CustomWordRow(customWord: customWord) {
                                removeCustomWord(id: customWord.id)
                            }
                        }
                    }
                }
            }
            .padding(MuesliTheme.spacing16)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            Image(systemName: "character.book.closed")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(MuesliTheme.accent)
            Text("No custom entries yet")
                .font(MuesliTheme.headline())
                .foregroundStyle(MuesliTheme.textPrimary)
            Text("Add terms like product names, people, acronyms, or phrases that the model often mishears.")
                .font(MuesliTheme.body())
                .foregroundStyle(MuesliTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(MuesliTheme.spacing16)
        .background(MuesliTheme.surfacePrimary)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
    }

    private func loadCustomWords() {
        do {
            customWords = try SharedStore().customWords()
            dictionaryError = nil
        } catch {
            dictionaryError = error.localizedDescription
        }
    }

    private func addCustomWord() {
        let trimmedWord = newWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedWord.isEmpty else { return }

        let trimmedReplacement = newReplacement.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = CustomWord(
            word: trimmedWord,
            replacement: trimmedReplacement.isEmpty ? nil : trimmedReplacement
        )

        do {
            try SharedStore().addCustomWord(entry)
            newWord = ""
            newReplacement = ""
            loadCustomWords()
        } catch {
            dictionaryError = error.localizedDescription
        }
    }

    private func removeCustomWord(id: UUID) {
        do {
            try SharedStore().removeCustomWord(id: id)
            loadCustomWords()
        } catch {
            dictionaryError = error.localizedDescription
        }
    }
}

private struct DictionaryToggleRow: View {
    let icon: String
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: MuesliTheme.spacing12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(MuesliTheme.accent)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                Text(title)
                    .font(MuesliTheme.headline())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Text(detail)
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: MuesliTheme.spacing12)

            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .tint(MuesliTheme.accent)
        }
    }
}

private struct CustomWordRow: View {
    let customWord: CustomWord
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: MuesliTheme.spacing12) {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                Text(customWord.word)
                    .font(MuesliTheme.headline())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Text(subtitle)
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textSecondary)
            }

            Spacer()

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .foregroundStyle(MuesliTheme.recording)
                    .background(MuesliTheme.recording.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                    .contentShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete dictionary entry")
        }
        .padding(MuesliTheme.spacing12)
        .background(MuesliTheme.surfacePrimary)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
    }

    private var subtitle: String {
        guard let replacement = customWord.replacement,
              !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              replacement != customWord.word else {
            return "Keep spelling as \(customWord.word)"
        }
        return "Replace with \(replacement)"
    }
}
