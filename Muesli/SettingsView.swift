import CloudKit
import SwiftUI

struct SettingsView: View {
    @Bindable var coordinator: DictationCoordinator
    var openSyncPrivacyRequest: UUID?
    var openInputRequest: UUID?
    var isActive = true
    var onSelectSection: ((AppSection) -> Void)?

    @AppStorage(MuesliPreferences.liveActivitiesForDictationsKey) private var liveActivitiesForDictations = true
    @AppStorage(MuesliPreferences.liveActivitiesForMeetingsKey) private var liveActivitiesForMeetings = true
    @AppStorage(MuesliPreferences.keyboardSessionModeKey) private var keyboardSessionMode = false
    @AppStorage(MuesliPreferences.recordingMicrophonePreferenceKey) private var microphonePreference = RecordingMicrophonePreference.automatic.rawValue
    @AppStorage(MuesliPreferences.keepDictationAudioRecordingsKey) private var keepDictationAudioRecordings = false
    @AppStorage(MuesliPreferences.longVoiceNoteModeEnabledKey) private var longVoiceNoteModeEnabled = true
    @AppStorage(MuesliPreferences.longVoiceNoteThresholdSecondsKey) private var longVoiceNoteThresholdSeconds = 60
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
    @State private var isSyncQRCodeScannerPresented = false
    @State private var isApplyingQRCodeSyncEnable = false
    @State private var modelPendingRemoval: LocalTranscriptionModel?
    @State private var isModelRemovalConfirmationPresented = false
    @State private var modelBeingRemoved: LocalTranscriptionModel?
    @State private var modelRemovalErrorMessage: String?

    var body: some View {
        NavigationStack {
            settingsContent
                .background(MuesliTheme.backgroundBase)
                .toolbar(.hidden, for: .navigationBar)
                .onAppear {
                    refreshVisibleSettingsIfNeeded()
                    openRequestedSyncPrivacySection()
                    openRequestedInputSection()
                }
                .onChange(of: isActive) { _, active in
                    guard active else { return }
                    refreshVisibleSettingsIfNeeded()
                    openRequestedSyncPrivacySection()
                    openRequestedInputSection()
                }
                .onChange(of: openSyncPrivacyRequest) { _, _ in
                    openRequestedSyncPrivacySection()
                }
                .onChange(of: openInputRequest) { _, _ in
                    openRequestedInputSection()
                }
                .sheet(isPresented: $isSyncQRCodeScannerPresented) {
                    SyncQRCodeScannerView(
                        isSyncAlreadyEnabled: iCloudSyncEnabled,
                        onOpenSyncURL: { url in
                            coordinator.handleOpenURL(url)
                        },
                        onEnableSyncURL: { _ in
                            enablePrivateICloudSyncFromQR()
                        }
                    )
                }
                .onChange(of: liveActivitiesForDictations) { _, _ in
                    coordinator.applyLiveActivityPreferences()
                }
                .onChange(of: liveActivitiesForMeetings) { _, _ in
                    coordinator.applyLiveActivityPreferences()
                }
                .onChange(of: keyboardSessionMode) { _, enabled in
                    guard isActive else { return }
                    coordinator.setKeyboardSessionModeEnabled(enabled)
                }
                .onChange(of: microphonePreference) { _, newValue in
                    guard isActive else { return }
                    coordinator.refreshAudioInputRoute()
                    AppTelemetry.signal("recording_microphone_preference_changed", parameters: ["preference": newValue])
                }
                .onChange(of: openRouterAPIKey) { _, newValue in
                    saveOpenRouterAPIKey(newValue)
                }
                .onChange(of: iCloudSyncEnabled) { _, enabled in
                    if enabled && isApplyingQRCodeSyncEnable {
                        isApplyingQRCodeSyncEnable = false
                        return
                    }
                    AppTelemetry.signal(
                        "icloud_sync_toggled",
                        parameters: ["enabled": enabled ? "true" : "false"]
                    )
                    appleSyncStatusText = enabled
                        ? "Private iCloud sync is on. Open Muesli on your Mac to see the same text history."
                        : "iCloud sync is off. Your data stays local on this iPhone."
                    if enabled {
                        AppTelemetry.signal("bridge_enable_started", parameters: ["platform": "ios", "source": "settings"])
                        coordinator.syncICloudTextIfEnabled(reason: "settings_toggle")
                    } else {
                        coordinator.iCloudSyncStatusText = "iCloud sync is off."
                    }
                    refreshAppleSyncSettings()
                }
        }
        .alert(
            modelPendingRemoval.map { "Remove \($0.shortName)?" } ?? "Remove model?",
            isPresented: $isModelRemovalConfirmationPresented,
            presenting: modelPendingRemoval
        ) { model in
            Button("Remove Download", role: .destructive) {
                removeDownloadedModel(model)
                modelPendingRemoval = nil
            }
            Button("Cancel", role: .cancel) {
                modelPendingRemoval = nil
            }
        } message: { model in
            Text(modelRemovalConfirmationMessage(for: model))
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
            Text("Voice notes, meetings, local models, and privacy.")
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
            .accessibilityIdentifier("settings.backButton")

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
        case .about:
            AboutSettingsContent()
        case .appearance:
            appearanceSettings
        case .input:
            inputSettings
        case .dictionary:
            DictionarySettingsContent()
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

    private var appearanceSettings: some View {
        AppearanceSettingsContent()
    }

    private var inputSettings: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
            MuesliSurface {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                    SettingsRow(icon: "keyboard", title: "Keyboard Extension", value: keyboardStatusText)
                        .accessibilityIdentifier("settings.keyboardExtensionRow")
                    Link(destination: URL(string: UIApplication.openSettingsURLString)!) {
                        HStack {
                            Text("Open iOS Settings")
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
                    SettingsToggleRow(
                        icon: "keyboard.badge.ellipsis",
                        title: "Keyboard Session Mode",
                        detail: keyboardSessionModeDetail,
                        isOn: $keyboardSessionMode,
                        accessibilityID: "settings.keyboardSessionToggle"
                    )
                    Divider().overlay(MuesliTheme.surfaceBorder)
                    SettingsMicrophonePicker(selection: $microphonePreference)
                    Divider().overlay(MuesliTheme.surfaceBorder)
                    SettingsToggleRow(
                        icon: "waveform.badge.mic",
                        title: "Voice Note Live Activities",
                        detail: "Show keyboard and in-app voice note progress on the Dynamic Island and Lock Screen.",
                        isOn: $liveActivitiesForDictations
                    )
                    Divider().overlay(MuesliTheme.surfaceBorder)
                    SettingsToggleRow(
                        icon: "waveform.circle",
                        title: "Save Voice Note Audio",
                        detail: "Keep original voice note audio locally on this iPhone for playback and troubleshooting. Audio does not sync.",
                        isOn: $keepDictationAudioRecordings
                    )
                    Divider().overlay(MuesliTheme.surfaceBorder)
                    LongVoiceNoteSettingsRow(
                        isEnabled: $longVoiceNoteModeEnabled,
                        thresholdSeconds: $longVoiceNoteThresholdSeconds
                    )
                }
                .padding(MuesliTheme.spacing16)
            }
        }
    }

    private var keyboardSessionModeDetail: String {
        let baseDetail = "Keeps an app-owned microphone session live so the keyboard can start and stop voice notes without reopening Muesli."
        let status = coordinator.keyboardSessionStatusText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !status.isEmpty, status != "Off" {
            switch status {
            case "Ready", "Starting", "Recording", "Transcribing":
                return "\(status). \(baseDetail)"
            default:
                if status.hasPrefix("Retrying session standby") || status.hasPrefix("Session standby unavailable") {
                    return "\(status). \(baseDetail)"
                }
                return "\(status). Tap Start to record normally, or toggle this off and on to retry."
            }
        }

        guard keyboardSessionMode else {
            return "When off, keyboard Start opens Muesli because iOS keyboards cannot own microphone access."
        }

        return "Starting. \(baseDetail)"
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
                        value: coordinator.selectedTranscriptionModel.shortName,
                        valueColor: MuesliTheme.textSecondary
                    )
                    Divider().overlay(MuesliTheme.surfaceBorder)
                    TranscriptionModelSelector(
                        selection: $coordinator.selectedTranscriptionModel,
                        preparation: coordinator.modelPreparation,
                        onSelect: coordinator.selectTranscriptionModel
                    )
                    Divider().overlay(MuesliTheme.surfaceBorder)
                    SettingsRow(
                        icon: "cpu",
                        title: "Runtime",
                        value: coordinator.selectedTranscriptionModel.family == .whisper
                            ? "WhisperKit / CoreML"
                            : "FluidAudio / CoreML"
                    )
                    Divider().overlay(MuesliTheme.surfaceBorder)
                    SettingsRow(icon: "textformat", title: "Language", value: coordinator.selectedTranscriptionModel.capabilityLabel)
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
                    if coordinator.modelPreparation.phase == .failed {
                        Button {
                            coordinator.prepareModel()
                        } label: {
                            Label("Retry Download", systemImage: "arrow.clockwise")
                                .font(MuesliTheme.headline())
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                                .foregroundStyle(.white)
                                .background(MuesliTheme.accent)
                                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                                .contentShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(MuesliTheme.spacing16)
            }

            downloadedModelsSettings
        }
    }

    private var downloadedModelsSettings: some View {
        MuesliSurface(cornerRadius: MuesliTheme.cornerLarge) {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    Label("Downloaded Models", systemImage: "internaldrive")
                        .font(MuesliTheme.headline())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text("Remove models you no longer use to reclaim local storage.")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let modelRemovalErrorMessage {
                    Label(modelRemovalErrorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(MuesliTheme.captionMedium())
                        .foregroundStyle(MuesliTheme.destructive)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if downloadedTranscriptionModels.isEmpty {
                    Text("No transcription models are stored locally.")
                        .font(MuesliTheme.callout())
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .padding(.vertical, MuesliTheme.spacing4)
                } else {
                    ForEach(Array(downloadedTranscriptionModels.enumerated()), id: \.element.id) { index, model in
                        if index > 0 {
                            Divider().overlay(MuesliTheme.surfaceBorder)
                        }
                        downloadedModelRow(model)
                    }
                }

                if !coordinator.canRemoveDownloadedModels,
                   modelBeingRemoved == nil,
                   !downloadedTranscriptionModels.isEmpty {
                    Text("Finish the current recording, transcription, or model download before removing a model.")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(MuesliTheme.spacing16)
        }
    }

    private func downloadedModelRow(_ model: LocalTranscriptionModel) -> some View {
        HStack(spacing: MuesliTheme.spacing12) {
            Image(systemName: model.family == .whisper ? "waveform" : "waveform.path.ecg")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(MuesliTheme.accent)
                .frame(width: 34, height: 34)
                .background(MuesliTheme.accentSubtle)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))

            VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                HStack(spacing: MuesliTheme.spacing4) {
                    Text(model.displayName)
                        .font(MuesliTheme.headline())
                        .foregroundStyle(MuesliTheme.textPrimary)
                        .lineLimit(1)
                    if model == coordinator.selectedTranscriptionModel {
                        Text("Active")
                            .font(MuesliTheme.captionMedium())
                            .foregroundStyle(MuesliTheme.accent)
                            .padding(.horizontal, MuesliTheme.spacing8)
                            .padding(.vertical, 2)
                            .background(MuesliTheme.accentSubtle)
                            .clipShape(Capsule())
                    }
                }
                Text(model.estimatedSizeLabel)
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textSecondary)
            }

            Spacer(minLength: MuesliTheme.spacing8)

            if modelBeingRemoved == model {
                ProgressView()
                    .tint(MuesliTheme.destructive)
                    .frame(width: 36, height: 36)
                    .accessibilityLabel("Removing \(model.displayName)")
            } else {
                Button {
                    modelRemovalErrorMessage = nil
                    modelPendingRemoval = model
                    isModelRemovalConfirmationPresented = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(MuesliTheme.destructive)
                        .frame(width: 36, height: 36)
                        .background(MuesliTheme.destructive.opacity(0.10))
                        .clipShape(Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!coordinator.canRemoveDownloadedModels)
                .accessibilityLabel("Remove \(model.displayName)")
                .accessibilityIdentifier("model.remove.\(model.rawValue)")
            }
        }
    }

    private var downloadedTranscriptionModels: [LocalTranscriptionModel] {
        LocalTranscriptionModel.allCases.filter { model in
            model.isDownloaded
                || (model == coordinator.selectedTranscriptionModel && coordinator.modelPreparation.isReady)
        }
    }

    private func modelRemovalConfirmationMessage(for model: LocalTranscriptionModel) -> String {
        let storage = "This permanently removes \(model.displayName) from this iPhone and frees its local storage."
        guard model == coordinator.selectedTranscriptionModel else { return storage }
        return "\(storage) It remains selected but unavailable until you select it again to download it."
    }

    private func removeDownloadedModel(_ model: LocalTranscriptionModel) {
        modelBeingRemoved = model
        modelRemovalErrorMessage = nil
        Task {
            do {
                try await coordinator.removeDownloadedModel(model)
            } catch {
                modelRemovalErrorMessage = error.localizedDescription
            }
            modelBeingRemoved = nil
        }
    }

    private var syncPrivacySettings: some View {
        MuesliSurface {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                SettingsToggleRow(
                    icon: "icloud",
                    title: "Sync with Mac",
                    detail: "Sync voice note text, meeting transcripts, notes, and summaries through your private iCloud account. Audio is never synced.",
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

                Button {
                    isSyncQRCodeScannerPresented = true
                    AppTelemetry.signal("bridge_qr_scan_started", parameters: ["platform": "ios", "source": "settings"])
                } label: {
                    Label("Scan Mac QR", systemImage: "qrcode.viewfinder")
                        .font(MuesliTheme.headline())
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .foregroundStyle(MuesliTheme.accent)
                        .background(MuesliTheme.accentSubtle)
                        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                        .contentShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                }
                .buttonStyle(.plain)

                Button {
                    coordinator.syncICloudTextIfEnabled(reason: "settings_manual")
                } label: {
                    Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                        .font(MuesliTheme.headline())
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .foregroundStyle(iCloudSyncEnabled ? .white : MuesliTheme.textTertiary)
                        .background(iCloudSyncEnabled ? MuesliTheme.accent : MuesliTheme.surfacePrimary)
                        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                        .contentShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                }
                .buttonStyle(.plain)
                .disabled(!iCloudSyncEnabled)

                Text(appleSyncStatusText ?? appleSyncSnapshot.detail)
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if let syncStatus = coordinator.iCloudSyncStatusText {
                    Text(syncStatus)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
                            .foregroundStyle(.white)
                            .background(chatGPTSignedIn ? MuesliTheme.success : MuesliTheme.accent)
                            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                            .contentShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                    }
                    .buttonStyle(.plain)
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

    private func refreshSummarySettings() {
        openRouterAPIKey = MeetingSummaryClient.storedOpenRouterAPIKey()
        chatGPTSignedIn = ChatGPTAuthManager.shared.isAuthenticated
    }

    private func refreshVisibleSettingsIfNeeded() {
        guard isActive else { return }
        refreshKeyboardStatus()
        refreshSummarySettings()
        refreshAppleSyncSettings()
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
            guard isActive else { return }
            appleSyncSnapshot = await AppleSyncAccountManager.shared.snapshot()
            guard isActive else { return }
            if iCloudSyncEnabled && !appleSyncSnapshot.isICloudAvailable {
                appleSyncStatusText = "Sign in to iCloud on this iPhone before enabling Muesli sync."
            } else if iCloudSyncEnabled {
                if let remoteDeviceName = MuesliBridgeDeviceIdentity.remoteDeviceDisplayName {
                    appleSyncStatusText = "Private iCloud sync is on with \(remoteDeviceName)."
                } else {
                    appleSyncStatusText = "Private iCloud sync is on. Your Muesli text history follows this iPhone and Mac."
                }
            } else {
                appleSyncStatusText = nil
            }
        }
    }

    @discardableResult
    private func enablePrivateICloudSyncFromQR() -> Bool {
        guard appleSyncSnapshot.isICloudAvailable else {
            appleSyncStatusText = "Sign in to iCloud on this iPhone, then scan the Mac QR again."
            return false
        }
        AppTelemetry.signal("bridge_enable_started", parameters: ["platform": "ios", "source": "settings_qr"])
        if !iCloudSyncEnabled {
            isApplyingQRCodeSyncEnable = true
        }
        iCloudSyncEnabled = true
        appleSyncStatusText = "Syncing your text history through private iCloud..."
        coordinator.syncICloudTextIfEnabled(reason: "settings_qr")
        refreshAppleSyncSettings()
        return true
    }

    private func openRequestedSyncPrivacySection() {
        guard openSyncPrivacyRequest != nil else { return }
        selectedSettingsSection = .syncPrivacy
        coordinator.syncSetupRequestID = nil
    }

    private func openRequestedInputSection() {
        guard openInputRequest != nil else { return }
        selectedSettingsSection = .input
        coordinator.inputSettingsNavigationRequestID = nil
    }

}

enum SettingsSection: String, CaseIterable, Identifiable {
    case input
    case meetings
    case dictionary
    case models
    case aiSummaries
    case syncPrivacy
    case appearance
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .input:
            "Voice Notes"
        case .meetings:
            "Meetings"
        case .dictionary:
            "Dictionary"
        case .models:
            "Models"
        case .aiSummaries:
            "AI Summaries"
        case .syncPrivacy:
            "Sync & Privacy"
        case .appearance:
            "Appearance"
        case .about:
            "About"
        }
    }

    var detail: String {
        switch self {
        case .input:
            "Recording retention, live activities, keyboard setup, and voice note sessions."
        case .meetings:
            "Recording, audio retention, live activities, and note templates."
        case .dictionary:
            "Filler word removal, custom phrases, names, and acronyms."
        case .models:
            "Choose and automatically download local Parakeet or Whisper models."
        case .aiSummaries:
            "Meeting summary providers, auth, and model selection."
        case .syncPrivacy:
            "Private iCloud sync between this iPhone and your Mac."
        case .appearance:
            "Color theme, light and dark mode, and app accent."
        case .about:
            "Version, source code, privacy, and open-source acknowledgements."
        }
    }

    var icon: String {
        switch self {
        case .input:
            "keyboard"
        case .meetings:
            "person.2.wave.2"
        case .dictionary:
            "character.book.closed"
        case .models:
            "cpu"
        case .aiSummaries:
            "sparkles"
        case .syncPrivacy:
            "icloud"
        case .appearance:
            "paintpalette"
        case .about:
            "info.circle"
        }
    }

}

private struct LongVoiceNoteSettingsRow: View {
    @Binding var isEnabled: Bool
    @Binding var thresholdSeconds: Int
    @State private var customText = ""
    @FocusState private var isCustomFieldFocused: Bool

    private let commonValues = [30, 60, 90, 120]

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            SettingsToggleRow(
                icon: "waveform.path.ecg",
                title: "Long Voice Note Mode",
                detail: "Switch to memo mode after longer recordings.",
                isOn: $isEnabled
            )

            if isEnabled {
                HStack(spacing: MuesliTheme.spacing12) {
                    Text("Switch after")
                        .font(MuesliTheme.captionMedium())
                        .foregroundStyle(MuesliTheme.textSecondary)

                    Spacer()

                    Menu {
                        ForEach(commonValues, id: \.self) { value in
                            Button(MuesliPreferences.longVoiceNoteThresholdLabel(value)) {
                                thresholdSeconds = value
                                customText = String(value)
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(MuesliPreferences.longVoiceNoteThresholdLabel(thresholdSeconds))
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .font(MuesliTheme.captionMedium())
                        .foregroundStyle(MuesliTheme.accent)
                        .frame(minHeight: 44)
                    }
                }

                HStack(spacing: MuesliTheme.spacing8) {
                    TextField("Seconds", text: $customText)
                        .keyboardType(.numberPad)
                        .focused($isCustomFieldFocused)
                        .font(MuesliTheme.body())
                        .foregroundStyle(MuesliTheme.textPrimary)
                        .padding(.horizontal, MuesliTheme.spacing12)
                        .frame(height: 44)
                        .background(MuesliTheme.surfacePrimary)
                        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall, style: .continuous))
                        .onSubmit(commitCustomValue)

                    Stepper("Threshold seconds", value: $thresholdSeconds, in: 30...600, step: 5)
                        .labelsHidden()
                }

                Text("30 seconds to 10 minutes")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
            }
        }
        .onAppear {
            thresholdSeconds = MuesliPreferences.clampedLongVoiceNoteThreshold(thresholdSeconds)
            customText = String(thresholdSeconds)
        }
        .onChange(of: thresholdSeconds) { _, value in
            let clamped = MuesliPreferences.clampedLongVoiceNoteThreshold(value)
            if thresholdSeconds != clamped {
                thresholdSeconds = clamped
                return
            }
            customText = String(clamped)
            signalThresholdChanged(clamped)
        }
        .onChange(of: isEnabled) { _, enabled in
            AppTelemetry.signal(
                "long_voice_note_mode_toggled",
                parameters: ["enabled": enabled ? "true" : "false"]
            )
        }
        .onChange(of: customText) { _, value in
            guard value.count > 4 else { return }
            customText = String(value.prefix(4))
        }
        .onChange(of: isCustomFieldFocused) { _, focused in
            if !focused {
                commitCustomValue()
            }
        }
    }

    private func commitCustomValue() {
        let value = Int(customText) ?? thresholdSeconds
        thresholdSeconds = MuesliPreferences.clampedLongVoiceNoteThreshold(value)
        customText = String(thresholdSeconds)
    }

    private func signalThresholdChanged(_ seconds: Int) {
        AppTelemetry.signal(
            "long_voice_note_threshold_changed",
            parameters: ["threshold_bucket": MuesliPreferences.longVoiceNoteThresholdLabel(seconds)]
        )
    }
}

private struct AppearanceSettingsContent: View {
    @AppStorage(MuesliPreferences.appearanceModeKey) private var appearanceMode = MuesliAppearanceMode.system.rawValue
    @AppStorage(MuesliPreferences.accentThemeKey) private var accentTheme = MuesliAccentTheme.blue.rawValue

    private var selectedAppearanceMode: MuesliAppearanceMode {
        MuesliAppearanceMode(rawValue: appearanceMode) ?? .system
    }

    private var selectedAccentTheme: MuesliAccentTheme {
        MuesliAccentTheme.resolved(rawValue: accentTheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
            MuesliSurface {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                    SettingsAppearanceModePicker(selection: $appearanceMode)
                    Divider().overlay(MuesliTheme.surfaceBorder)
                    SettingsAccentThemePicker(selection: $accentTheme)
                }
                .padding(MuesliTheme.spacing16)
            }

            MuesliSurface {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                    Text("Preview")
                        .font(MuesliTheme.headline())
                        .foregroundStyle(MuesliTheme.textPrimary)

                    appearancePreviewSurface
                }
                .padding(MuesliTheme.spacing16)
            }
        }
    }

    private var appearancePreviewSurface: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            HStack(spacing: MuesliTheme.spacing12) {
                MuesliTheme.accent
                    .frame(width: 44, height: 44)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1))

                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    Text(selectedAccentTheme.label)
                        .font(MuesliTheme.headline())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text("\(selectedAppearanceMode.label) appearance")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                }

                Spacer()
            }

            HStack(spacing: MuesliTheme.spacing8) {
                previewMetric("3", "streak", tint: Color(hex: 0xFF9F2D))
                previewMetric("152", "WPM", tint: MuesliTheme.success)
                previewRecorderButton
            }
        }
        .padding(MuesliTheme.spacing12)
        .background(MuesliTheme.surfacePrimary)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
    }

    private func previewMetric(_ value: String, _ label: String, tint: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(MuesliTheme.headline())
                .monospacedDigit()
                .foregroundStyle(MuesliTheme.textPrimary)
            Text(label)
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .background(tint.opacity(0.10))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall, style: .continuous)
                .strokeBorder(tint.opacity(0.28), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall, style: .continuous))
    }

    private var previewRecorderButton: some View {
        HStack(spacing: MuesliTheme.spacing8) {
            Image(systemName: "mic.fill")
                .font(.system(size: 15, weight: .semibold))
            Text("Record")
                .font(MuesliTheme.captionMedium())
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .background(MuesliTheme.accent)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall, style: .continuous))
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.sectionRow.\(section.rawValue)")
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
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
    var accessibilityID: String? = nil

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
                .accessibilityIdentifier(accessibilityID ?? "")
        }
    }
}

private struct SettingsMicrophonePicker: View {
    @Binding var selection: String

    private var availableOptions: [RecordingMicrophonePreference] {
        let options = AudioInputRouteManager.availablePreferenceOptions()
        guard !options.contains(preference) else { return options }
        return options + [preference]
    }

    private var preference: RecordingMicrophonePreference {
        RecordingMicrophonePreference(rawValue: selection) ?? .automatic
    }

    var body: some View {
        HStack(alignment: .top, spacing: MuesliTheme.spacing12) {
            Image(systemName: "mic")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(MuesliTheme.accent)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                Text("Microphone")
                    .font(MuesliTheme.headline())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Text(preference.detail)
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: MuesliTheme.spacing12)

            Picker("Microphone", selection: $selection) {
                ForEach(availableOptions) { option in
                    Text(option.label).tag(option.rawValue)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
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

private struct SettingsAppearanceModePicker: View {
    @Binding var selection: String

    private var selectedMode: MuesliAppearanceMode {
        MuesliAppearanceMode(rawValue: selection) ?? .system
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            HStack(spacing: MuesliTheme.spacing12) {
                Image(systemName: "circle.lefthalf.filled")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(MuesliTheme.accent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    Text("Color Scheme")
                        .font(MuesliTheme.headline())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text("Currently \(selectedMode.label.lowercased()).")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                }
            }

            Picker("Color Scheme", selection: $selection) {
                ForEach(MuesliAppearanceMode.allCases) { mode in
                    Text(mode.label).tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)
        }
        .onAppear(perform: normalizeSelectionIfNeeded)
        .onChange(of: selection) { _, _ in
            normalizeSelectionIfNeeded()
        }
    }

    private func normalizeSelectionIfNeeded() {
        guard MuesliAppearanceMode(rawValue: selection) == nil else { return }
        selection = MuesliAppearanceMode.system.rawValue
    }
}

private struct SettingsAccentThemePicker: View {
    @Binding var selection: String

    private var selectedTheme: MuesliAccentTheme {
        MuesliAccentTheme.resolved(rawValue: selection)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            HStack(spacing: MuesliTheme.spacing12) {
                Image(systemName: "paintpalette")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(MuesliTheme.accent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    Text("Accent")
                        .font(MuesliTheme.headline())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text(selectedTheme.label)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                }
            }

            HStack(spacing: MuesliTheme.spacing8) {
                ForEach(MuesliAccentTheme.allCases) { theme in
                    Button {
                        selection = theme.rawValue
                    } label: {
                        MuesliTheme.color(for: theme)
                            .frame(width: 44, height: 44)
                            .clipShape(Circle())
                            .overlay {
                                Circle()
                                    .strokeBorder(
                                        selectedTheme == theme ? MuesliTheme.textPrimary : MuesliTheme.surfaceBorder,
                                        lineWidth: selectedTheme == theme ? 2 : 1
                                    )
                            }
                            .overlay {
                                if selectedTheme == theme {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(theme.label) accent")
                }
            }
        }
        .onAppear(perform: normalizeSelectionIfNeeded)
        .onChange(of: selection) { _, _ in
            normalizeSelectionIfNeeded()
        }
    }

    private func normalizeSelectionIfNeeded() {
        let resolved = MuesliAccentTheme.resolved(rawValue: selection)
        guard selection != resolved.rawValue else { return }
        selection = resolved.rawValue
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
    let detail: String
    let isICloudAvailable: Bool

    static let checking = AppleSyncAccountSnapshot(
        iCloudStatusLabel: "Checking",
        detail: "Checking iCloud status.",
        isICloudAvailable: false
    )
}

@MainActor
final class AppleSyncAccountManager {
    static let shared = AppleSyncAccountManager()

    private init() {}

    func snapshot() async -> AppleSyncAccountSnapshot {
        let cloud = await iCloudStatus()

        let detail: String
        if !cloud.isAvailable {
            detail = "Sign in to iCloud on this iPhone to sync text with your Mac."
        } else {
            detail = "Ready for private iCloud text sync. Voice notes, transcripts, notes, and summaries will sync through your iCloud account."
        }

        return AppleSyncAccountSnapshot(
            iCloudStatusLabel: cloud.label,
            detail: detail,
            isICloudAvailable: cloud.isAvailable
        )
    }

    private func iCloudStatus() async -> (label: String, isAvailable: Bool) {
        // UI tests intentionally use an unsigned app bundle. CloudKit aborts
        // that process before invoking its completion handler because the
        // signed iCloud entitlements are absent.
        if ProcessInfo.processInfo.arguments.contains(MuesliAppConstants.uiTestingLaunchArgument) {
            return ("Unavailable", false)
        }

        return await withCheckedContinuation { continuation in
            CKContainer(identifier: ICloudTextSyncEngine.containerIdentifier)
                .accountStatus { status, error in
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
