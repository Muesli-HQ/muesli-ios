import AuthenticationServices
import CloudKit
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
    @AppStorage(MuesliPreferences.meetingTemplateKey) private var meetingTemplate = MeetingTemplatePreset.general.rawValue
    @AppStorage(MuesliPreferences.iCloudSyncEnabledKey) private var iCloudSyncEnabled = false
    @State private var keyboardStatusText = "Unknown"
    @State private var openRouterAPIKey = ""
    @State private var summaryStatusText: String?
    @State private var chatGPTSignedIn = false
    @State private var appleSyncSnapshot = AppleSyncAccountSnapshot.checking
    @State private var appleSyncStatusText: String?
    @State private var selectedSettingsSection: SettingsSection?

    var body: some View {
        NavigationStack {
            settingsContent
            .background(MuesliTheme.backgroundBase)
            .toolbar(.hidden, for: .navigationBar)
            .onAppear {
                refreshKeyboardStatus()
                refreshSummarySettings()
                AppTelemetry.signal("settings_viewed")
                refreshAppleSyncSettings()
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
            .onChange(of: iCloudSyncEnabled) { _, enabled in
                AppTelemetry.signal(
                    "icloud_sync_toggled",
                    parameters: ["enabled": enabled ? "true" : "false"]
                )
                appleSyncStatusText = enabled
                    ? "iCloud sync is enabled. Full transcript syncing will start once the CloudKit sync engine is connected."
                    : "iCloud sync is off. Your data stays local on this iPhone."
                refreshAppleSyncSettings()
            }
        }
    }

    @ViewBuilder
    private var settingsContent: some View {
        if let selectedSettingsSection {
            ScrollView {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
                    detailHeader(for: selectedSettingsSection)
                    settingsSectionContent(selectedSettingsSection)
                }
                .padding(MuesliTheme.spacing20)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
                    settingsHeader

                    MuesliSurface {
                        VStack(spacing: MuesliTheme.spacing4) {
                            ForEach(SettingsSection.allCases) { section in
                                SettingsSectionRow(section: section) {
                                    withAnimation(.snappy(duration: 0.22)) {
                                        selectedSettingsSection = section
                                    }
                                }
                                if section != SettingsSection.allCases.last {
                                    Divider().overlay(MuesliTheme.surfaceBorder)
                                }
                            }
                        }
                        .padding(MuesliTheme.spacing12)
                    }
                }
                .padding(MuesliTheme.spacing20)
            }
        }
    }

    private var settingsHeader: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
            Text("Settings")
                .font(MuesliTheme.title1())
                .foregroundStyle(MuesliTheme.textPrimary)
            Text("Configure Muesli without mixing setup into the main workspace.")
                .font(MuesliTheme.callout())
                .foregroundStyle(MuesliTheme.textSecondary)
        }
    }

    private func detailHeader(for section: SettingsSection) -> some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
            Button {
                withAnimation(.snappy(duration: 0.22)) {
                    selectedSettingsSection = nil
                }
            } label: {
                Label("Settings", systemImage: "chevron.left")
                    .font(MuesliTheme.headline())
                    .foregroundStyle(MuesliTheme.accent)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                Text(section.title)
                    .font(MuesliTheme.title1())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Text(section.detail)
                    .font(MuesliTheme.callout())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func settingsSectionContent(_ section: SettingsSection) -> some View {
        switch section {
        case .general:
            generalSettings
        case .input:
            inputSettings
        case .meetings:
            meetingSettings
        case .models:
            modelSettings
        case .syncPrivacy:
            syncPrivacySettings
        case .aiSummaries:
            aiSummarySettings
        }
    }

    private var generalSettings: some View {
        MuesliSurface {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                SettingsRow(icon: "moon.circle", title: "Appearance", value: "System")
                Divider().overlay(MuesliTheme.surfaceBorder)
                SettingsRow(icon: "lock.shield", title: "Processing", value: "On device")
                Divider().overlay(MuesliTheme.surfaceBorder)
                SettingsRow(icon: "iphone", title: "App Data", value: "Local SQLite")
            }
            .padding(MuesliTheme.spacing16)
        }
    }

    private var inputSettings: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
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
                    Divider().overlay(MuesliTheme.surfaceBorder)
                    SettingsNavigationRow(
                        icon: "character.book.closed",
                        title: "Dictionary",
                        detail: "Manage filler words, custom phrases, names, and acronyms."
                    ) {
                        onSelectSection?(.dictionary)
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
                    Divider().overlay(MuesliTheme.surfaceBorder)
                    SettingsToggleRow(
                        icon: "waveform.badge.mic",
                        title: "Dictation Live Activities",
                        detail: "Show keyboard and in-app dictation progress on the Dynamic Island and Lock Screen.",
                        isOn: $liveActivitiesForDictations
                    )
                }
                .padding(MuesliTheme.spacing16)
            }
        }
    }

    private var meetingSettings: some View {
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
                    icon: "person.2.wave.2",
                    title: "Meeting Live Activities",
                    detail: "Show active meeting recordings while Muesli is recording in the background.",
                    isOn: $liveActivitiesForMeetings
                )
                Divider().overlay(MuesliTheme.surfaceBorder)
                SettingsMeetingTemplatePicker(selection: $meetingTemplate)
            }
            .padding(MuesliTheme.spacing16)
        }
    }

    private var modelSettings: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
            MuesliSurface(cornerRadius: MuesliTheme.cornerLarge) {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
                    SettingsRow(
                        icon: "checkmark.seal",
                        title: "Active Model",
                        value: "Parakeet v3",
                        valueColor: MuesliTheme.textSecondary
                    )
                    Divider().overlay(MuesliTheme.surfaceBorder)
                    SettingsRow(icon: "cpu", title: "Runtime", value: "CoreML / ANE")
                    Divider().overlay(MuesliTheme.surfaceBorder)
                    SettingsRow(icon: "iphone", title: "Execution", value: "On device")
                    Divider().overlay(MuesliTheme.surfaceBorder)
                    VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                        Text(coordinator.modelPreparation.status)
                            .font(MuesliTheme.headline())
                            .foregroundStyle(MuesliTheme.textPrimary)
                        Text(coordinator.modelPreparation.detail)
                            .font(MuesliTheme.body())
                            .foregroundStyle(MuesliTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let progress = coordinator.modelPreparation.progress,
                       coordinator.modelPreparation.isPreparing {
                        ProgressView(value: progress)
                            .tint(MuesliTheme.accent)
                    }
                    Button {
                        coordinator.prepareModel()
                    } label: {
                        Label(modelButtonTitle, systemImage: modelButtonIcon)
                            .font(MuesliTheme.headline())
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(modelButtonDisabled ? MuesliTheme.textTertiary : .white)
                    .background(modelButtonDisabled ? MuesliTheme.surfacePrimary : MuesliTheme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                    .disabled(modelButtonDisabled)
                }
                .padding(MuesliTheme.spacing16)
            }
        }
    }

    private var syncPrivacySettings: some View {
        MuesliSurface {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                SettingsToggleRow(
                    icon: "icloud",
                    title: "iCloud Sync",
                    detail: "Sync dictations, meetings, summaries, dictionary terms, and settings through your private iCloud account.",
                    isOn: $iCloudSyncEnabled
                )
                Divider().overlay(MuesliTheme.surfaceBorder)
                SettingsRow(
                    icon: "icloud",
                    title: "iCloud",
                    value: appleSyncSnapshot.iCloudStatusLabel,
                    iconColor: appleSyncSnapshot.isICloudAvailable ? MuesliTheme.success : MuesliTheme.accent,
                    valueColor: appleSyncSnapshot.isICloudAvailable ? MuesliTheme.success : MuesliTheme.textTertiary
                )
                Divider().overlay(MuesliTheme.surfaceBorder)
                SettingsRow(
                    icon: "person.crop.circle.badge.checkmark",
                    title: "Apple Account",
                    value: appleSyncSnapshot.appleAccountLabel,
                    iconColor: appleSyncSnapshot.isSignedInWithApple ? MuesliTheme.success : MuesliTheme.accent,
                    valueColor: appleSyncSnapshot.isSignedInWithApple ? MuesliTheme.success : MuesliTheme.textTertiary
                )

                if appleSyncSnapshot.isSignedInWithApple {
                    Button(action: signOutOfAppleSync) {
                        Label("Signed in · Sign Out", systemImage: "checkmark.circle.fill")
                            .font(MuesliTheme.headline())
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(MuesliTheme.success)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                } else {
                    SignInWithAppleButton(.signIn) { request in
                        AppTelemetry.signal("apple_sync_sign_in_started")
                        request.requestedScopes = [.fullName, .email]
                    } onCompletion: { result in
                        handleAppleSyncSignIn(result)
                    }
                    .signInWithAppleButtonStyle(.white)
                    .frame(height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                }

                Text(appleSyncStatusText ?? appleSyncSnapshot.detail)
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(MuesliTheme.spacing16)
        }
    }

    private var aiSummarySettings: some View {
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

                    SettingsModelPickerRow(
                        icon: "cpu",
                        title: "OpenRouter Model",
                        selection: $openRouterModel,
                        presets: SummaryModelPreset.openRouterModels
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

                    SettingsModelPickerRow(
                        icon: "cpu",
                        title: "ChatGPT Model",
                        selection: $chatGPTModel,
                        presets: SummaryModelPreset.chatGPTModels,
                        preserveCustomValue: false,
                        fallbackSelection: MeetingSummaryBackend.defaultChatGPTModel
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

    private var modelButtonTitle: String {
        switch coordinator.modelPreparation.phase {
        case .ready:
            "Model Ready"
        case .downloading, .preparing:
            "Preparing"
        case .failed:
            "Try Again"
        case .idle:
            "Prepare Model"
        }
    }

    private var modelButtonIcon: String {
        switch coordinator.modelPreparation.phase {
        case .ready:
            "checkmark"
        case .downloading, .preparing:
            "arrow.down"
        case .failed:
            "arrow.clockwise"
        case .idle:
            "square.and.arrow.down"
        }
    }

    private var modelButtonDisabled: Bool {
        coordinator.modelPreparation.isReady || coordinator.modelPreparation.isPreparing
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

    private func refreshAppleSyncSettings() {
        Task {
            appleSyncSnapshot = await AppleSyncAccountManager.shared.snapshot()
            AppTelemetry.signal(
                "icloud_sync_status_checked",
                parameters: [
                    "icloud_available": appleSyncSnapshot.isICloudAvailable ? "true" : "false",
                    "apple_signed_in": appleSyncSnapshot.isSignedInWithApple ? "true" : "false",
                ]
            )
            if iCloudSyncEnabled && !appleSyncSnapshot.isICloudAvailable {
                appleSyncStatusText = "Sign in to iCloud on this iPhone before enabling Muesli sync."
            } else if iCloudSyncEnabled && !appleSyncSnapshot.isSignedInWithApple {
                appleSyncStatusText = "Sign in with Apple to confirm the account Muesli should prepare for sync."
            } else if iCloudSyncEnabled {
                appleSyncStatusText = "Ready for private iCloud sync. Transcription still happens on-device."
            } else {
                appleSyncStatusText = nil
            }
        }
    }

    private func handleAppleSyncSignIn(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                appleSyncStatusText = "Apple sign-in did not return an Apple ID credential."
                AppTelemetry.signal("apple_sync_sign_in_failed", parameters: ["reason": "missing_credential"])
                return
            }
            do {
                try AppleSyncAccountManager.shared.save(credential: credential)
                appleSyncStatusText = "Signed in with Apple for Muesli sync."
                AppTelemetry.signal("apple_sync_sign_in_completed")
            } catch {
                appleSyncStatusText = error.localizedDescription
                AppTelemetry.signal(
                    "apple_sync_sign_in_failed",
                    parameters: ["reason": String(describing: type(of: error))]
                )
            }
        case .failure(let error):
            appleSyncStatusText = error.localizedDescription
            AppTelemetry.signal(
                "apple_sync_sign_in_failed",
                parameters: ["reason": String(describing: type(of: error))]
            )
        }
        refreshAppleSyncSettings()
    }

    private func signOutOfAppleSync() {
        AppleSyncAccountManager.shared.signOut()
        iCloudSyncEnabled = false
        appleSyncStatusText = "Signed out of Apple sync. iCloud sync is off."
        AppTelemetry.signal("apple_sync_signed_out")
        refreshAppleSyncSettings()
    }

}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case input
    case meetings
    case models
    case syncPrivacy
    case aiSummaries

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:
            "General"
        case .input:
            "Input"
        case .meetings:
            "Meetings"
        case .models:
            "Models"
        case .syncPrivacy:
            "Sync & Privacy"
        case .aiSummaries:
            "AI Summaries"
        }
    }

    var detail: String {
        switch self {
        case .general:
            "App-wide behavior, appearance, and local data defaults."
        case .input:
            "Keyboard setup, dictation sessions, and dictionary shortcuts."
        case .meetings:
            "Recording, audio retention, live activities, and note templates."
        case .models:
            "Local transcription runtime and model preparation."
        case .syncPrivacy:
            "Private iCloud sync and Apple account setup."
        case .aiSummaries:
            "Meeting summary providers, auth, and model selection."
        }
    }

    var icon: String {
        switch self {
        case .general:
            "switch.2"
        case .input:
            "keyboard"
        case .meetings:
            "person.2.wave.2"
        case .models:
            "cpu"
        case .syncPrivacy:
            "icloud"
        case .aiSummaries:
            "sparkles"
        }
    }
}

private struct SettingsSectionRow: View {
    let section: SettingsSection
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: MuesliTheme.spacing12) {
                Image(systemName: section.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(MuesliTheme.accent)
                    .frame(width: 28, height: 28)
                    .background(MuesliTheme.accentSubtle)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))

                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    Text(section.title)
                        .font(MuesliTheme.headline())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text(section.detail)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: MuesliTheme.spacing12)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .padding(.top, MuesliTheme.spacing4)
            }
            .padding(.horizontal, MuesliTheme.spacing4)
            .padding(.vertical, MuesliTheme.spacing8)
        }
        .buttonStyle(.plain)
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

struct SettingsModelPickerRow: View {
    let icon: String
    let title: String
    @Binding var selection: String
    let presets: [SummaryModelPreset]
    var preserveCustomValue = true
    var fallbackSelection: String?

    private var menuPresets: [SummaryModelPreset] {
        SummaryModelPreset.menuPresets(
            presets,
            currentModel: selection,
            preserveCustomValue: preserveCustomValue
        )
    }

    private var normalizedSelection: String {
        let trimmedSelection = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        if presets.contains(where: { $0.id == trimmedSelection }) {
            return trimmedSelection
        }
        if preserveCustomValue, !trimmedSelection.isEmpty {
            return trimmedSelection
        }
        return fallbackSelection ?? presets.first?.id ?? selection
    }

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

            Picker(title, selection: $selection) {
                ForEach(menuPresets) { preset in
                    Text(preset.label).tag(preset.id)
                }
            }
            .pickerStyle(.menu)
            .font(MuesliTheme.body())
            .tint(MuesliTheme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, MuesliTheme.spacing12)
            .frame(height: 42)
            .background(MuesliTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        }
        .onAppear(perform: normalizeSelectionIfNeeded)
        .onChange(of: selection) { _, _ in
            normalizeSelectionIfNeeded()
        }
    }

    private func normalizeSelectionIfNeeded() {
        let validSelection = normalizedSelection
        guard selection != validSelection else { return }
        selection = validSelection
    }
}

private struct SettingsMeetingTemplatePicker: View {
    @Binding var selection: String

    private var selectedTemplate: MeetingTemplatePreset {
        MeetingTemplatePreset(rawValue: selection) ?? .general
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            HStack(spacing: MuesliTheme.spacing12) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(MuesliTheme.accent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    Text("Meeting Template")
                        .font(MuesliTheme.headline())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text(selectedTemplate.detail)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Picker("Meeting Template", selection: $selection) {
                ForEach(MeetingTemplatePreset.allCases) { template in
                    Text(template.label).tag(template.rawValue)
                }
            }
            .pickerStyle(.menu)
            .font(MuesliTheme.body())
            .tint(MuesliTheme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, MuesliTheme.spacing12)
            .frame(height: 42)
            .background(MuesliTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        }
        .onAppear(perform: normalizeSelectionIfNeeded)
        .onChange(of: selection) { _, _ in
            normalizeSelectionIfNeeded()
        }
    }

    private func normalizeSelectionIfNeeded() {
        guard MeetingTemplatePreset(rawValue: selection) == nil else { return }
        selection = MeetingTemplatePreset.general.rawValue
    }
}

struct AppleSyncAccountSnapshot: Equatable {
    let iCloudStatusLabel: String
    let appleAccountLabel: String
    let detail: String
    let isICloudAvailable: Bool
    let isSignedInWithApple: Bool

    static let checking = AppleSyncAccountSnapshot(
        iCloudStatusLabel: "Checking",
        appleAccountLabel: "Checking",
        detail: "Checking iCloud and Apple account status.",
        isICloudAvailable: false,
        isSignedInWithApple: false
    )
}

enum AppleSyncAccountError: Error, LocalizedError {
    case missingUserIdentifier

    var errorDescription: String? {
        switch self {
        case .missingUserIdentifier:
            "Apple sign-in did not return a user identifier."
        }
    }
}

@MainActor
final class AppleSyncAccountManager {
    static let shared = AppleSyncAccountManager()

    private static let keychainService = "com.phequals7.muesli.ios.apple-sync"
    private let keychain = KeychainStore(service: keychainService)

    private init() {}

    func snapshot() async -> AppleSyncAccountSnapshot {
        async let cloudStatus = iCloudStatus()
        async let appleCredential = appleCredentialStatus()
        let (cloud, credential) = await (cloudStatus, appleCredential)

        let accountLabel: String
        let isSignedIn: Bool
        switch credential {
        case .authorized:
            accountLabel = storedAccountLabel()
            isSignedIn = true
        case .revoked:
            signOut()
            accountLabel = "Revoked"
            isSignedIn = false
        case .notFound:
            accountLabel = "Not signed in"
            isSignedIn = false
        case .transferred:
            accountLabel = storedAccountLabel()
            isSignedIn = true
        @unknown default:
            accountLabel = "Unknown"
            isSignedIn = false
        }

        let detail: String
        if !cloud.isAvailable {
            detail = "Muesli sync needs iCloud enabled on this iPhone."
        } else if !isSignedIn {
            detail = "Sign in with Apple to prepare private iCloud sync for this app."
        } else {
            detail = "Ready for private iCloud sync. Transcripts and summaries will sync through your iCloud account."
        }

        return AppleSyncAccountSnapshot(
            iCloudStatusLabel: cloud.label,
            appleAccountLabel: accountLabel,
            detail: detail,
            isICloudAvailable: cloud.isAvailable,
            isSignedInWithApple: isSignedIn
        )
    }

    func save(credential: ASAuthorizationAppleIDCredential) throws {
        let user = credential.user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty else { throw AppleSyncAccountError.missingUserIdentifier }

        try keychain.set(user, for: "apple_user_id")
        if let email = credential.email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty {
            try keychain.set(email, for: "apple_email")
        }
        let displayName = PersonNameComponentsFormatter().string(from: credential.fullName ?? PersonNameComponents())
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !displayName.isEmpty {
            try keychain.set(displayName, for: "apple_display_name")
        }
    }

    func signOut() {
        ["apple_user_id", "apple_email", "apple_display_name"].forEach {
            keychain.delete(account: $0)
        }
    }

    private func storedAccountLabel() -> String {
        let displayName = ((try? keychain.string(for: "apple_display_name")) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !displayName.isEmpty { return displayName }

        let email = ((try? keychain.string(for: "apple_email")) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !email.isEmpty { return email }

        return "Signed in"
    }

    private func appleCredentialStatus() async -> ASAuthorizationAppleIDProvider.CredentialState {
        guard let userID = try? keychain.string(for: "apple_user_id"), !userID.isEmpty else {
            return .notFound
        }
        return await withCheckedContinuation { continuation in
            ASAuthorizationAppleIDProvider().getCredentialState(forUserID: userID) { state, _ in
                continuation.resume(returning: state)
            }
        }
    }

    private func iCloudStatus() async -> (label: String, isAvailable: Bool) {
        await withCheckedContinuation { continuation in
            CKContainer.default().accountStatus { status, error in
                if error != nil {
                    continuation.resume(returning: ("Unavailable", false))
                    return
                }
                switch status {
                case .available:
                    continuation.resume(returning: ("Available", true))
                case .noAccount:
                    continuation.resume(returning: ("No iCloud account", false))
                case .restricted:
                    continuation.resume(returning: ("Restricted", false))
                case .couldNotDetermine:
                    continuation.resume(returning: ("Unknown", false))
                case .temporarilyUnavailable:
                    continuation.resume(returning: ("Temporarily unavailable", false))
                @unknown default:
                    continuation.resume(returning: ("Unknown", false))
                }
            }
        }
    }
}
