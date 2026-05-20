import SwiftUI

struct SettingsView: View {
    @Bindable var coordinator: DictationCoordinator
    var onSelectSection: ((AppSection) -> Void)?

    @AppStorage(MuesliPreferences.liveActivitiesForDictationsKey) private var liveActivitiesForDictations = true
    @AppStorage(MuesliPreferences.liveActivitiesForMeetingsKey) private var liveActivitiesForMeetings = true
    @AppStorage(MuesliPreferences.keyboardSessionModeKey) private var keyboardSessionMode = false
    @AppStorage(MuesliPreferences.keyboardSessionTimeoutMinutesKey) private var keyboardSessionTimeoutMinutes = 10
    @AppStorage(MuesliPreferences.keepMeetingAudioRecordingsKey) private var keepMeetingAudioRecordings = false
    @AppStorage(MuesliPreferences.meetingSummariesEnabledKey) private var meetingSummariesEnabled = false
    @AppStorage(MuesliPreferences.meetingSummaryBackendKey) private var meetingSummaryBackend = MeetingSummaryBackend.openRouter.rawValue
    @AppStorage(MuesliPreferences.openRouterModelKey) private var openRouterModel = MeetingSummaryBackend.defaultOpenRouterModel
    @AppStorage(MuesliPreferences.chatGPTModelKey) private var chatGPTModel = MeetingSummaryBackend.defaultChatGPTModel
    @State private var keyboardStatusText = "Unknown"
    @State private var openRouterAPIKey = ""
    @State private var summaryStatusText: String?
    @State private var chatGPTSignedIn = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
                    settingsHeader

                    MuesliSurface {
                        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                            SettingsRow(icon: "keyboard", title: "Keyboard", value: keyboardStatusText)
                            Link(destination: URL(string: UIApplication.openSettingsURLString)!) {
                                HStack {
                                    Text("Open Keyboard Settings")
                                    Spacer()
                                    Image(systemName: "arrow.up.right")
                                }
                                .font(MuesliTheme.headline())
                                .foregroundStyle(MuesliTheme.accent)
                                .padding(.top, MuesliTheme.spacing4)
                            }
                        }
                        .padding(MuesliTheme.spacing16)
                    }

                    MuesliSurface {
                        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                            SettingsNavigationRow(
                                icon: "character.book.closed",
                                title: "Dictionary",
                                detail: "Manage filler words, custom phrases, names, and acronyms."
                            ) {
                                onSelectSection?(.dictionary)
                            }
                            Divider().overlay(MuesliTheme.surfaceBorder)
                            SettingsNavigationRow(
                                icon: "square.and.arrow.down",
                                title: "Models",
                                detail: "Prepare and inspect the local Parakeet v3 runtime."
                            ) {
                                onSelectSection?(.models)
                            }
                        }
                        .padding(MuesliTheme.spacing16)
                    }

                    MuesliSurface {
                        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                            SettingsToggleRow(
                                icon: "keyboard.badge.ellipsis",
                                title: "Keyboard Session Mode",
                                detail: "Keep Muesli ready for keyboard dictation with a visible microphone session.",
                                isOn: $keyboardSessionMode
                            )
                            Divider().overlay(MuesliTheme.surfaceBorder)
                            SettingsRow(
                                icon: "waveform.badge.mic",
                                title: "Session",
                                value: coordinator.keyboardSessionStatusText
                            )
                            Divider().overlay(MuesliTheme.surfaceBorder)
                            Stepper(value: $keyboardSessionTimeoutMinutes, in: 1...30, step: 1) {
                                SettingsRow(
                                    icon: "timer",
                                    title: "Timeout",
                                    value: "\(keyboardSessionTimeoutMinutes) min"
                                )
                            }
                            .disabled(!keyboardSessionMode)
                        }
                        .padding(MuesliTheme.spacing16)
                    }

                    MuesliSurface {
                        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                            SettingsToggleRow(
                                icon: "waveform.path.ecg.rectangle",
                                title: "Save Meeting Audio",
                                detail: "Keep the original meeting recording after delayed transcription finishes. Queued recordings are always kept until transcription completes.",
                                isOn: $keepMeetingAudioRecordings
                            )
                            Divider().overlay(MuesliTheme.surfaceBorder)
                            SettingsToggleRow(
                                icon: "waveform.badge.mic",
                                title: "Dictation Live Activities",
                                detail: "Show keyboard and in-app dictation progress on the Dynamic Island and Lock Screen.",
                                isOn: $liveActivitiesForDictations
                            )
                            Divider().overlay(MuesliTheme.surfaceBorder)
                            SettingsToggleRow(
                                icon: "person.2.wave.2",
                                title: "Meeting Live Activities",
                                detail: "Show active meeting recordings while Muesli is recording in the background.",
                                isOn: $liveActivitiesForMeetings
                            )
                        }
                        .padding(MuesliTheme.spacing16)
                    }

                    MuesliSurface {
                        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                            SettingsToggleRow(
                                icon: "sparkles",
                                title: "Meeting Summaries",
                                detail: "Generate structured notes after local transcription and speaker diarization.",
                                isOn: $meetingSummariesEnabled
                            )

                            Divider().overlay(MuesliTheme.surfaceBorder)

                            Picker("Summary Backend", selection: $meetingSummaryBackend) {
                                ForEach(MeetingSummaryBackend.allCases) { backend in
                                    Text(backend.label).tag(backend.rawValue)
                                }
                            }
                            .pickerStyle(.segmented)
                            .disabled(!meetingSummariesEnabled)

                            if selectedSummaryBackend == .openRouter {
                                SettingsTextFieldRow(
                                    icon: "key",
                                    title: "OpenRouter API Key",
                                    placeholder: "sk-or-...",
                                    text: $openRouterAPIKey,
                                    isSecure: true
                                )
                                .disabled(!meetingSummariesEnabled)

                                SettingsTextFieldRow(
                                    icon: "cpu",
                                    title: "OpenRouter Model",
                                    placeholder: MeetingSummaryBackend.defaultOpenRouterModel,
                                    text: $openRouterModel
                                )
                                .disabled(!meetingSummariesEnabled)
                            } else {
                                SettingsRow(
                                    icon: "person.crop.circle.badge.checkmark",
                                    title: "ChatGPT",
                                    value: chatGPTSignedIn ? "Signed in" : "Not signed in",
                                    iconColor: chatGPTSignedIn ? MuesliTheme.success : MuesliTheme.accent,
                                    valueColor: chatGPTSignedIn ? MuesliTheme.success : MuesliTheme.textTertiary
                                )

                                Button(action: toggleChatGPTSignIn) {
                                    Label(
                                        chatGPTSignedIn ? "Signed in · Sign Out" : "Sign In with ChatGPT",
                                        systemImage: chatGPTSignedIn ? "checkmark.circle.fill" : "person.crop.circle"
                                    )
                                        .font(MuesliTheme.headline())
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 44)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.white)
                                .background(chatGPTSignedIn ? MuesliTheme.success : MuesliTheme.accent)
                                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                                .disabled(!meetingSummariesEnabled)

                                SettingsTextFieldRow(
                                    icon: "cpu",
                                    title: "ChatGPT Model",
                                    placeholder: MeetingSummaryBackend.defaultChatGPTModel,
                                    text: $chatGPTModel
                                )
                                .disabled(!meetingSummariesEnabled)
                            }

                            if let summaryStatusText {
                                Text(summaryStatusText)
                                    .font(MuesliTheme.caption())
                                    .foregroundStyle(MuesliTheme.textTertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(MuesliTheme.spacing16)
                    }
                }
                .padding(MuesliTheme.spacing20)
            }
            .background(MuesliTheme.backgroundBase)
            .toolbar(.hidden, for: .navigationBar)
            .onAppear {
                refreshKeyboardStatus()
                refreshSummarySettings()
            }
            .onChange(of: liveActivitiesForDictations) { _, _ in
                coordinator.applyLiveActivityPreferences()
            }
            .onChange(of: liveActivitiesForMeetings) { _, _ in
                coordinator.applyLiveActivityPreferences()
            }
            .onChange(of: keyboardSessionMode) { _, enabled in
                coordinator.setKeyboardSessionModeEnabled(enabled)
            }
            .onChange(of: keyboardSessionTimeoutMinutes) { _, _ in
                coordinator.refreshKeyboardSessionTimeout()
            }
            .onChange(of: openRouterAPIKey) { _, newValue in
                saveOpenRouterAPIKey(newValue)
            }
        }
    }

    private var settingsHeader: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
            Text("Settings")
                .font(MuesliTheme.title1())
                .foregroundStyle(MuesliTheme.textPrimary)
            Text("Configure the keyboard shell and local model runtime.")
                .font(MuesliTheme.callout())
                .foregroundStyle(MuesliTheme.textSecondary)
        }
    }

    private func refreshKeyboardStatus() {
        let store = SharedStore()
        let extensionStatus = try? store.keyboardExtensionStatus()
        let confirmed = UserDefaults.standard.bool(forKey: OnboardingPreferenceKeys.keyboardEnabledConfirmed)
        let fullAccessConfirmed = UserDefaults.standard.bool(forKey: OnboardingPreferenceKeys.fullAccessConfirmed)

        if extensionStatus?.hasOpenAccess == true {
            keyboardStatusText = "Enabled"
        } else if confirmed && fullAccessConfirmed {
            keyboardStatusText = "Needs first use"
        } else if confirmed {
            keyboardStatusText = "Full Access needed"
        } else {
            keyboardStatusText = "Not confirmed"
        }
    }

    private var selectedSummaryBackend: MeetingSummaryBackend {
        MeetingSummaryBackend(rawValue: meetingSummaryBackend) ?? .openRouter
    }

    private func refreshSummarySettings() {
        openRouterAPIKey = MeetingSummaryClient.storedOpenRouterAPIKey()
        chatGPTSignedIn = ChatGPTAuthManager.shared.isAuthenticated
    }

    private func saveOpenRouterAPIKey(_ apiKey: String) {
        do {
            try MeetingSummaryClient.saveOpenRouterAPIKey(apiKey)
            summaryStatusText = apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "OpenRouter key cleared."
                : "OpenRouter key saved in Keychain."
        } catch {
            summaryStatusText = error.localizedDescription
        }
    }

    private func toggleChatGPTSignIn() {
        if chatGPTSignedIn {
            ChatGPTAuthManager.shared.signOut()
            chatGPTSignedIn = false
            summaryStatusText = "Signed out of ChatGPT."
            return
        }

        Task {
            do {
                try await ChatGPTAuthManager.shared.signIn()
                chatGPTSignedIn = ChatGPTAuthManager.shared.isAuthenticated
                summaryStatusText = "Signed in to ChatGPT."
            } catch {
                chatGPTSignedIn = ChatGPTAuthManager.shared.isAuthenticated
                summaryStatusText = error.localizedDescription
            }
        }
    }

}

private struct SettingsNavigationRow: View {
    let icon: String
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
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

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .padding(.top, 2)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct SettingsRow: View {
    let icon: String
    let title: String
    let value: String
    var iconColor = MuesliTheme.accent
    var valueColor = MuesliTheme.textTertiary

    var body: some View {
        HStack(spacing: MuesliTheme.spacing12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 22)
            Text(title)
                .font(MuesliTheme.headline())
                .foregroundStyle(MuesliTheme.textPrimary)
            Spacer()
            Text(value)
                .font(MuesliTheme.callout())
                .foregroundStyle(valueColor)
        }
    }
}

private struct SettingsToggleRow: View {
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

struct SettingsTextFieldRow: View {
    let icon: String
    let title: String
    let placeholder: String
    @Binding var text: String
    var isSecure = false

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            HStack(spacing: MuesliTheme.spacing12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(MuesliTheme.accent)
                    .frame(width: 22)
                Text(title)
                    .font(MuesliTheme.headline())
                    .foregroundStyle(MuesliTheme.textPrimary)
            }

            Group {
                if isSecure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(MuesliTheme.body())
            .foregroundStyle(MuesliTheme.textPrimary)
            .padding(.horizontal, MuesliTheme.spacing12)
            .frame(height: 42)
            .background(MuesliTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        }
    }
}
