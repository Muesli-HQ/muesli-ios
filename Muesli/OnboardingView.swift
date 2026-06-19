import AVFoundation
import Combine
import SwiftUI
import UIKit

struct OnboardingView: View {
    private enum BridgeState {
        case notConfigured
        case checkingICloud
        case readyToEnable
        case syncing
        case active
        case needsICloud
        case error
    }

    @Environment(\.scenePhase) private var scenePhase
    @Bindable var coordinator: DictationCoordinator
    @State private var currentStep: OnboardingStep = OnboardingStep(
        rawValue: UserDefaults.standard.integer(forKey: OnboardingPreferenceKeys.currentStep)
    ) ?? .profile
    @State private var nameDraft = ""
    @State private var useCaseDraft: OnboardingUseCase = .keyboardDictation
    @State private var microphoneGranted = false
    @State private var keyboardEnabledConfirmed = UserDefaults.standard.bool(
        forKey: OnboardingPreferenceKeys.keyboardEnabledConfirmed
    )
    @State private var fullAccessConfirmed = UserDefaults.standard.bool(
        forKey: OnboardingPreferenceKeys.fullAccessConfirmed
    )
    @State private var meetingSummariesEnabled = UserDefaults.standard.object(
        forKey: MuesliPreferences.meetingSummariesEnabledKey
    ) == nil ? true : UserDefaults.standard.bool(forKey: MuesliPreferences.meetingSummariesEnabledKey)
    @State private var summaryBackend = MuesliPreferences.meetingSummaryBackend
    @State private var openRouterAPIKey = MeetingSummaryClient.storedOpenRouterAPIKey()
    @State private var chatGPTSignedIn = ChatGPTAuthManager.shared.isAuthenticated
    @State private var isSigningInChatGPT = false
    @State private var summaryStatusText: String?
    @State private var keyboardExtensionLastSeenAt: Date?
    @State private var permissionPollingError: String?
    @AppStorage(MuesliPreferences.iCloudSyncEnabledKey) private var iCloudSyncEnabled = false
    @State private var appleSyncSnapshot = AppleSyncAccountSnapshot.checking
    @State private var appleSyncStatusText: String?
    @State private var bridgePromptSeen = false
    private let permissionPoller = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    private var orderedSteps: [OnboardingStep] {
        OnboardingStep.orderedSteps(for: useCaseDraft)
    }

    var body: some View {
        VStack(spacing: 0) {
            progressHeader

            ScrollView {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing24) {
                    switch currentStep {
                    case .profile:
                        profileStep
                    case .permissions:
                        permissionsStep
                    case .sync:
                        privateSyncStep
                    case .model:
                        modelStep
                    case .test:
                        testStep
                    case .summary:
                        meetingSummaryStep
                    }
                }
                .padding(.horizontal, MuesliTheme.spacing20)
                .padding(.top, MuesliTheme.spacing24)
                .padding(.bottom, MuesliTheme.spacing24)
            }

            footer
        }
        .background(MuesliTheme.backgroundBase)
        .tint(MuesliTheme.accent)
        .onAppear {
            nameDraft = coordinator.userName
            useCaseDraft = coordinator.selectedUseCase
            refreshPermissionStatus()
            refreshSummaryStatus()
            AppTelemetry.signal("onboarding_viewed")
            AppTelemetry.signal("onboarding_step_viewed", parameters: ["step": currentStep.telemetryName])
            if currentStep == .model {
                coordinator.prepareModelForOnboarding()
            }
            if currentStep == .sync {
                markBridgePromptSeen()
                refreshAppleSyncStatus()
            }
        }
        .onChange(of: currentStep) { _, step in
            UserDefaults.standard.set(step.rawValue, forKey: OnboardingPreferenceKeys.currentStep)
            AppTelemetry.signal("onboarding_step_viewed", parameters: ["step": step.telemetryName])
            if step == .sync {
                markBridgePromptSeen()
                refreshAppleSyncStatus()
            }
            if step == .model {
                coordinator.prepareModelForOnboarding()
            }
            if step == .summary {
                refreshSummaryStatus()
            }
            if step == .permissions {
                refreshPermissionStatus()
            }
        }
        .onChange(of: keyboardEnabledConfirmed) { _, confirmed in
            UserDefaults.standard.set(confirmed, forKey: OnboardingPreferenceKeys.keyboardEnabledConfirmed)
        }
        .onChange(of: fullAccessConfirmed) { _, confirmed in
            UserDefaults.standard.set(confirmed, forKey: OnboardingPreferenceKeys.fullAccessConfirmed)
        }
        .onChange(of: useCaseDraft) { _, useCase in
            if !OnboardingStep.orderedSteps(for: useCase).contains(currentStep) {
                currentStep = OnboardingStep.orderedSteps(for: useCase).first ?? .profile
            }
        }
        .onChange(of: iCloudSyncEnabled) { _, enabled in
            AppTelemetry.signal(
                "onboarding_icloud_sync_toggled",
                parameters: ["enabled": enabled ? "true" : "false"]
            )
            appleSyncStatusText = enabled
                ? "Syncing through your private iCloud account. Audio stays local."
                : "Sync is off. Dictations and meetings stay local on this iPhone."
            refreshAppleSyncStatus()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            refreshPermissionStatus()
        }
        .onReceive(permissionPoller) { _ in
            guard currentStep == .permissions else { return }
            refreshPermissionStatus()
        }
    }

    private var progressHeader: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            HStack(spacing: MuesliTheme.spacing12) {
                Image("MuesliAppIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    Text("Set up muesli")
                        .font(MuesliTheme.title2())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text(currentStep.subtitle)
                        .font(MuesliTheme.callout())
                        .foregroundStyle(MuesliTheme.textSecondary)
                }
            }

            HStack(spacing: MuesliTheme.spacing8) {
                ForEach(orderedSteps, id: \.self) { step in
                    Capsule()
                        .fill(
                            step.position(in: orderedSteps) <= currentStep.position(in: orderedSteps)
                                ? MuesliTheme.accent
                                : MuesliTheme.surfacePrimary
                        )
                        .frame(height: 4)
                }
            }
        }
        .padding(.horizontal, MuesliTheme.spacing20)
        .padding(.top, MuesliTheme.spacing20)
        .padding(.bottom, MuesliTheme.spacing12)
        .background(MuesliTheme.backgroundBase)
    }

    private var profileStep: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing20) {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                Text("Welcome")
                    .font(MuesliTheme.title1())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Text("A few details help Muesli choose the right first-run setup.")
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textSecondary)
            }

            VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                Text("Your name")
                    .font(MuesliTheme.captionMedium())
                    .foregroundStyle(MuesliTheme.textTertiary)
                TextField("Enter your name", text: $nameDraft)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.next)
                    .padding(.horizontal, MuesliTheme.spacing12)
                    .frame(height: 46)
                    .background(MuesliTheme.backgroundRaised)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                    .overlay(
                        RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                            .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                    )
            }

            VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                Text("What will you use Muesli for?")
                    .font(MuesliTheme.captionMedium())
                    .foregroundStyle(MuesliTheme.textTertiary)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: MuesliTheme.spacing12) {
                    ForEach(OnboardingUseCase.allCases, id: \.self) { useCase in
                        useCaseCard(useCase)
                    }
                }
            }
        }
    }

    private func useCaseCard(_ useCase: OnboardingUseCase) -> some View {
        let selected = useCaseDraft == useCase
        return Button {
            useCaseDraft = useCase
        } label: {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                Image(systemName: useCase.icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(selected ? MuesliTheme.accent : MuesliTheme.textSecondary)
                Text(useCase.title)
                    .font(MuesliTheme.headline())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Text(useCase.subtitle)
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .padding(MuesliTheme.spacing12)
            .background(selected ? MuesliTheme.surfaceSelected : MuesliTheme.backgroundRaised)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                    .strokeBorder(selected ? MuesliTheme.accent : MuesliTheme.surfaceBorder, lineWidth: selected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing20) {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                Text("Permissions")
                    .font(MuesliTheme.title1())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Text("Muesli needs microphone access. Keyboard setup is required only if you want dictation from text fields.")
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textSecondary)
            }

            permissionRow(
                icon: "mic.fill",
                title: "Microphone",
                detail: "Record speech for local transcription",
                isComplete: microphoneGranted,
                buttonTitle: microphoneGranted ? "Granted" : "Grant"
            ) {
                requestMicrophonePermission()
            }

            if useCaseDraft.needsKeyboardSetup {
                Button {
                    openAppSettings()
                } label: {
                    Label("Open Keyboard Settings", systemImage: "arrow.up.right")
                        .font(MuesliTheme.headline())
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                }
                .buttonStyle(.plain)
                .foregroundStyle(MuesliTheme.accent)
                .background(MuesliTheme.backgroundRaised)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                .overlay(
                    RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                        .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                )

                permissionRow(
                    icon: "keyboard.fill",
                    title: "Keyboard",
                    detail: keyboardPermissionDetail,
                    isComplete: keyboardEnabledConfirmed,
                    buttonTitle: keyboardEnabledConfirmed ? "Done" : "I Added It"
                ) {
                    keyboardEnabledConfirmed = true
                }

                permissionRow(
                    icon: "network",
                    title: "Full Access",
                    detail: fullAccessPermissionDetail,
                    isComplete: fullAccessConfirmed,
                    buttonTitle: fullAccessConfirmed ? "Done" : "I Enabled It"
                ) {
                    fullAccessConfirmed = true
                }

                if let permissionPollingError {
                    Text(permissionPollingError)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Muesli checks these permissions automatically while this screen is open. After enabling Full Access, open the Muesli Keyboard once so iOS lets it report back.")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var keyboardPermissionDetail: String {
        if fullAccessConfirmed {
            return "Muesli Keyboard was detected."
        }
        if let keyboardExtensionLastSeenAt {
            return "Detected \(keyboardExtensionLastSeenAt.formatted(date: .omitted, time: .shortened))."
        }
        return "Muesli checks automatically after you add and open the keyboard."
    }

    private var fullAccessPermissionDetail: String {
        if fullAccessConfirmed {
            return "Full Access verified from the keyboard extension."
        }
        if keyboardEnabledConfirmed {
            return "Enable Full Access, then open Muesli Keyboard once."
        }
        return "Waiting for the keyboard extension to report Full Access."
    }

    private func permissionRow(
        icon: String,
        title: String,
        detail: String,
        isComplete: Bool,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        MuesliSurface {
            HStack(spacing: MuesliTheme.spacing12) {
                Image(systemName: isComplete ? "checkmark.circle.fill" : icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isComplete ? MuesliTheme.success : MuesliTheme.accent)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    Text(title)
                        .font(MuesliTheme.headline())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text(detail)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .lineLimit(2)
                }

                Spacer()

                Button(buttonTitle, action: action)
                    .font(MuesliTheme.captionMedium())
                    .buttonStyle(.borderedProminent)
                    .disabled(isComplete)
            }
            .padding(MuesliTheme.spacing16)
        }
    }

    private var privateSyncStep: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing20) {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                Text("Sync with your Mac")
                    .font(MuesliTheme.title1())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Text("Your Muesli history follows you through private iCloud. Dictations, meeting transcripts, notes, and summaries sync as text. Audio stays local.")
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            MuesliSurface(cornerRadius: MuesliTheme.cornerLarge) {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
                    VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                        Text(iCloudSyncEnabled ? "Private iCloud sync is on" : "Continue with private iCloud sync")
                            .font(MuesliTheme.headline())
                            .foregroundStyle(MuesliTheme.textPrimary)
                        Text("Muesli uses the iCloud account already signed in on this iPhone. No extra account sign-in is required.")
                            .font(MuesliTheme.caption())
                            .foregroundStyle(MuesliTheme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider().overlay(MuesliTheme.surfaceBorder)

                    syncStatusRow(
                        icon: "icloud",
                        title: "iCloud",
                        value: appleSyncSnapshot.iCloudStatusLabel,
                        isComplete: appleSyncSnapshot.isICloudAvailable
                    )

                    Button {
                        enablePrivateICloudBridge()
                    } label: {
                        Label(bridgeSyncButtonTitle, systemImage: bridgeSyncButtonIcon)
                            .font(MuesliTheme.headline())
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .foregroundStyle(bridgeActionDisabled ? MuesliTheme.textTertiary : .white)
                            .background(bridgeActionDisabled ? MuesliTheme.surfacePrimary : MuesliTheme.accent)
                            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                            .contentShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                    }
                    .buttonStyle(.plain)
                    .disabled(bridgeActionDisabled)

                    Text(appleSyncStatusText ?? appleSyncSnapshot.detail)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(MuesliTheme.spacing16)
            }

            Text("You can skip this now and enable iCloud Sync later in Settings.")
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textTertiary)
        }
    }

    private var bridgeState: BridgeState {
        let status = coordinator.iCloudSyncStatusText?.lowercased() ?? ""
        if appleSyncSnapshot.iCloudStatusLabel == "Checking" {
            return .checkingICloud
        }
        if status.contains("syncing") {
            return .syncing
        }
        if status.contains("failed") {
            return .error
        }
        if !appleSyncSnapshot.isICloudAvailable {
            return .needsICloud
        }
        if iCloudSyncEnabled {
            return .active
        }
        return .readyToEnable
    }

    private var bridgeSyncButtonTitle: String {
        switch bridgeState {
        case .active:
            return "Private iCloud sync on"
        case .checkingICloud:
            return "Checking iCloud"
        case .syncing:
            return "Syncing"
        case .needsICloud:
            return "Sign in to iCloud on this iPhone"
        case .error:
            return "Try again"
        case .notConfigured, .readyToEnable:
            return "Continue with private iCloud sync"
        }
    }

    private var bridgeSyncButtonIcon: String {
        switch bridgeState {
        case .active:
            return "checkmark.icloud"
        case .checkingICloud, .syncing, .error:
            return "arrow.triangle.2.circlepath"
        case .needsICloud:
            return "exclamationmark.icloud"
        case .notConfigured, .readyToEnable:
            return "icloud"
        }
    }

    private var bridgeActionDisabled: Bool {
        switch bridgeState {
        case .checkingICloud, .syncing, .active, .needsICloud:
            return true
        case .notConfigured, .readyToEnable, .error:
            return false
        }
    }

    private func syncStatusRow(icon: String, title: String, value: String, isComplete: Bool) -> some View {
        HStack(spacing: MuesliTheme.spacing12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isComplete ? MuesliTheme.success : MuesliTheme.accent)
                .frame(width: 24)

            Text(title)
                .font(MuesliTheme.headline())
                .foregroundStyle(MuesliTheme.textPrimary)

            Spacer(minLength: MuesliTheme.spacing12)

            Text(value)
                .font(MuesliTheme.callout())
                .foregroundStyle(isComplete ? MuesliTheme.success : MuesliTheme.textTertiary)
                .multilineTextAlignment(.trailing)
        }
    }

    private var modelStep: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing20) {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                Text("Prepare Model")
                    .font(MuesliTheme.title1())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Text("\(coordinator.selectedTranscriptionModel.shortName) runs on CoreML / ANE. First setup downloads and compiles the model for this iPhone.")
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textSecondary)
            }

            modelPicker
            modelPanel
        }
    }

    private var modelPicker: some View {
        MuesliSurface(cornerRadius: MuesliTheme.cornerLarge) {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                HStack(spacing: MuesliTheme.spacing12) {
                    Image(systemName: "cpu")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(MuesliTheme.accent)
                        .frame(width: 30)
                    VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                        Text("Transcription Model")
                            .font(MuesliTheme.headline())
                            .foregroundStyle(MuesliTheme.textPrimary)
                        Text(coordinator.selectedTranscriptionModel.detail)
                            .font(MuesliTheme.caption())
                            .foregroundStyle(MuesliTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }

                Picker("Transcription Model", selection: $coordinator.selectedTranscriptionModel) {
                    ForEach(LocalTranscriptionModel.allCases) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: MuesliTheme.spacing8) {
                    modelBadge(coordinator.selectedTranscriptionModel.capabilityLabel, icon: "textformat")
                    modelBadge(coordinator.selectedTranscriptionModel.estimatedSizeLabel, icon: "internaldrive")
                }
            }
            .padding(MuesliTheme.spacing16)
        }
    }

    private func modelBadge(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(MuesliTheme.captionMedium())
            .foregroundStyle(MuesliTheme.accent)
            .padding(.horizontal, MuesliTheme.spacing8)
            .padding(.vertical, MuesliTheme.spacing4)
            .background(MuesliTheme.accent.opacity(0.12))
            .clipShape(Capsule())
    }

    private var modelPanel: some View {
        MuesliSurface(cornerRadius: MuesliTheme.cornerLarge) {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
                HStack(alignment: .top, spacing: MuesliTheme.spacing12) {
                    modelStatusIcon

                    VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                        Text(coordinator.selectedTranscriptionModel.shortName)
                            .font(MuesliTheme.title3())
                            .foregroundStyle(MuesliTheme.textPrimary)
                        Text(coordinator.modelPreparation.status)
                            .font(MuesliTheme.callout())
                            .foregroundStyle(MuesliTheme.textSecondary)
                        Text(coordinator.modelPreparation.detail)
                            .font(MuesliTheme.caption())
                            .foregroundStyle(MuesliTheme.textTertiary)
                    }

                    Spacer()
                }

                modelProgress

                if coordinator.modelPreparation.phase == .failed || coordinator.modelPreparation.phase == .idle {
                    Button {
                        coordinator.prepareModelForOnboarding()
                    } label: {
                        Label(modelActionTitle, systemImage: modelActionIcon)
                            .font(MuesliTheme.headline())
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(modelButtonColor)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                }
            }
            .padding(MuesliTheme.spacing16)
        }
    }

    @ViewBuilder
    private var modelStatusIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                .fill(modelButtonColor.opacity(0.14))
                .frame(width: 46, height: 46)

            if coordinator.modelPreparation.isPreparing {
                ProgressView()
                    .controlSize(.regular)
            } else {
                Image(systemName: modelActionIcon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(modelButtonColor)
            }
        }
    }

    @ViewBuilder
    private var modelProgress: some View {
        switch coordinator.modelPreparation.phase {
        case .idle:
            EmptyView()
        case .downloading:
            if let progress = coordinator.modelPreparation.progress {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                    ProgressView(value: progress, total: 1)
                    Text("\(Int((progress * 100).rounded()))% complete")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                }
            }
        case .preparing:
            VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                IndeterminatePreparationBar()
                    .frame(height: 7)
                RotatingPreparationHint(messages: [
                    "Compiling CoreML assets for this device.",
                    "First launch takes longer; later dictation starts faster.",
                    "Audio and transcripts stay on device."
                ])
            }
        case .ready:
            Label("Ready for dictation", systemImage: "checkmark.circle.fill")
                .font(MuesliTheme.captionMedium())
                .foregroundStyle(MuesliTheme.success)
        case .failed:
            Label("Model setup needs another try", systemImage: "exclamationmark.triangle.fill")
                .font(MuesliTheme.captionMedium())
                .foregroundStyle(MuesliTheme.recording)
        }
    }

    private var testStep: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing20) {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                Text(useCaseDraft == .voiceNotes ? "Test Voice Note" : "Test Dictation")
                    .font(MuesliTheme.title1())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Text("Try saying: \"testing this one out\"")
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textSecondary)
            }

            MuesliSurface(cornerRadius: MuesliTheme.cornerLarge) {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
                    if isOnboardingTestActive {
                        VStack(spacing: MuesliTheme.spacing8) {
                            MuesliInlineWaveformView(
                                mode: coordinator.isOnboardingTestRecording ? .level : .waiting,
                                color: onboardingTestColor,
                                level: coordinator.isOnboardingTestRecording ? coordinator.onboardingTestInputLevel : nil,
                                barCount: 24
                            )
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .padding(.horizontal, MuesliTheme.spacing16)

                            Text(coordinator.isOnboardingTestRecording ? "Listening" : "Transcribing")
                                .font(MuesliTheme.captionMedium())
                                .foregroundStyle(MuesliTheme.textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, MuesliTheme.spacing16)
                        .background(onboardingTestColor.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                    }

                    Text(coordinator.onboardingTestTranscript.isEmpty ? "Your transcription will appear here." : coordinator.onboardingTestTranscript)
                        .font(coordinator.onboardingTestTranscript.isEmpty ? MuesliTheme.body() : .system(size: 14, design: .monospaced))
                        .foregroundStyle(coordinator.onboardingTestTranscript.isEmpty ? MuesliTheme.textTertiary : MuesliTheme.textPrimary)
                        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)

                    if let error = coordinator.onboardingTestError {
                        Text(error)
                            .font(MuesliTheme.caption())
                            .foregroundStyle(MuesliTheme.recording)
                    }

                    Button {
                        if coordinator.isOnboardingTestRecording {
                            coordinator.stopOnboardingTestDictation()
                        } else {
                            coordinator.startOnboardingTestDictation()
                        }
                    } label: {
                        Label(
                            onboardingTestButtonTitle,
                            systemImage: onboardingTestButtonIcon
                        )
                        .font(MuesliTheme.headline())
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(onboardingTestColor)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                    .disabled(!coordinator.modelPreparation.isReady || coordinator.isOnboardingTestTranscribing)

                    if !coordinator.modelPreparation.isReady {
                        Text("The test unlocks after model preparation completes.")
                            .font(MuesliTheme.caption())
                            .foregroundStyle(MuesliTheme.textTertiary)
                    }
                }
                .padding(MuesliTheme.spacing16)
            }
        }
        .onAppear {
            if !coordinator.modelPreparation.isReady {
                coordinator.prepareModelForOnboarding()
            }
        }
    }

    private var meetingSummaryStep: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing20) {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                Text("Meeting Summaries")
                    .font(MuesliTheme.title1())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Text("Connect ChatGPT or OpenRouter now so meeting recordings can become structured notes after local transcription and diarization.")
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            MuesliSurface(cornerRadius: MuesliTheme.cornerLarge) {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
                    Toggle(isOn: $meetingSummariesEnabled) {
                        VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                            Text("Generate Meeting Notes")
                                .font(MuesliTheme.headline())
                                .foregroundStyle(MuesliTheme.textPrimary)
                            Text("You can skip this and configure summaries later in Settings.")
                                .font(MuesliTheme.caption())
                                .foregroundStyle(MuesliTheme.textTertiary)
                        }
                    }
                    .tint(MuesliTheme.accent)

                    Divider().overlay(MuesliTheme.surfaceBorder)

                    Picker("Summary Provider", selection: $summaryBackend) {
                        ForEach(MeetingSummaryBackend.allCases) { backend in
                            Text(backend.label).tag(backend)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(!meetingSummariesEnabled)

                    if summaryBackend == .chatGPT {
                        chatGPTSummarySetup
                    } else {
                        openRouterSummarySetup
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
    }

    private var chatGPTSummarySetup: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            HStack(spacing: MuesliTheme.spacing12) {
                Image(systemName: chatGPTSignedIn ? "checkmark.circle.fill" : "person.crop.circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(chatGPTSignedIn ? MuesliTheme.success : MuesliTheme.accent)

                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    Text("ChatGPT")
                        .font(MuesliTheme.headline())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text(chatGPTSignedIn ? "Signed in for meeting summaries" : "Use your ChatGPT subscription for summary generation")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                }

                Spacer()
            }

            Button(action: toggleChatGPTSignIn) {
                HStack(spacing: MuesliTheme.spacing8) {
                    if isSigningInChatGPT {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: chatGPTSignedIn ? "checkmark.circle.fill" : "person.crop.circle.badge.plus")
                    }
                    Text(chatGPTSignedIn ? "Signed in · Sign Out" : "Sign In with ChatGPT")
                }
                .font(MuesliTheme.headline())
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .foregroundStyle(.white)
                .background(chatGPTSignedIn ? MuesliTheme.success : MuesliTheme.accent)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                .contentShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            }
            .buttonStyle(.plain)
            .disabled(!meetingSummariesEnabled || isSigningInChatGPT)

            SettingsModelPickerRow(
                icon: "cpu",
                title: "ChatGPT Model",
                selection: Binding(
                    get: { MuesliPreferences.chatGPTModel },
                    set: { UserDefaults.standard.set($0, forKey: MuesliPreferences.chatGPTModelKey) }
                ),
                presets: SummaryModelPreset.chatGPTModels,
                preserveCustomValue: false,
                fallbackSelection: MeetingSummaryBackend.defaultChatGPTModel
            )
            .disabled(!meetingSummariesEnabled)
        }
    }

    private var openRouterSummarySetup: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            Text("OpenRouter supports several hosted model providers through one API key.")
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

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
                selection: Binding(
                    get: { MuesliPreferences.openRouterModel },
                    set: { UserDefaults.standard.set($0, forKey: MuesliPreferences.openRouterModelKey) }
                ),
                presets: SummaryModelPreset.openRouterModels
            )
            .disabled(!meetingSummariesEnabled)
        }
        .onChange(of: openRouterAPIKey) { _, apiKey in
            saveOpenRouterAPIKey(apiKey)
        }
    }

    private var footer: some View {
        HStack(spacing: MuesliTheme.spacing12) {
            if currentStep != .profile {
                Button {
                    goBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 44, height: 48)
                        .foregroundStyle(MuesliTheme.textSecondary)
                        .background(MuesliTheme.backgroundRaised)
                        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                        .contentShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                }
                .buttonStyle(.plain)
            }

            Button {
                primaryAction()
            } label: {
                HStack(spacing: MuesliTheme.spacing8) {
                    Image(systemName: currentStep == .test ? "checkmark" : "arrow.right")
                    Text(primaryButtonTitle)
                }
                .font(MuesliTheme.headline())
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .foregroundStyle(.white)
                .background(canContinue ? MuesliTheme.accent : MuesliTheme.surfacePrimary)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                .contentShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            }
            .buttonStyle(.plain)
            .disabled(!canContinue)
        }
        .padding(.horizontal, MuesliTheme.spacing20)
        .padding(.top, MuesliTheme.spacing12)
        .padding(.bottom, MuesliTheme.spacing20)
        .background(MuesliTheme.backgroundBase)
    }

    private var primaryButtonTitle: String {
        switch currentStep {
        case .profile:
            "Continue"
        case .permissions:
            "Continue"
        case .sync:
            iCloudSyncEnabled ? "Continue" : "Skip for Now"
        case .model:
            coordinator.modelPreparation.isReady ? "Continue" : "Skip for Now"
        case .test:
            isLastStep ? "Finish" : "Continue"
        case .summary:
            isLastStep ? "Finish" : "Continue"
        }
    }

    private var canContinue: Bool {
        switch currentStep {
        case .profile:
            !nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .permissions:
            microphoneGranted && (!useCaseDraft.needsKeyboardSetup || (keyboardEnabledConfirmed && fullAccessConfirmed))
        case .sync:
            true
        case .model:
            !coordinator.modelPreparation.isPreparing
        case .test:
            !isOnboardingTestActive && !coordinator.onboardingTestTranscript.isEmpty
        case .summary:
            !isSigningInChatGPT
        }
    }

    private var isLastStep: Bool {
        currentStep.position(in: orderedSteps) == orderedSteps.count - 1
    }

    private var isOnboardingTestActive: Bool {
        coordinator.isOnboardingTestRecording || coordinator.isOnboardingTestTranscribing
    }

    private var onboardingTestColor: Color {
        if coordinator.isOnboardingTestRecording {
            MuesliTheme.recording
        } else if coordinator.isOnboardingTestTranscribing {
            MuesliTheme.transcribing
        } else {
            MuesliTheme.accent
        }
    }

    private var onboardingTestButtonTitle: String {
        if coordinator.isOnboardingTestTranscribing {
            "Transcribing"
        } else if coordinator.isOnboardingTestRecording {
            "Stop Recording"
        } else {
            "Start Test"
        }
    }

    private var onboardingTestButtonIcon: String {
        if coordinator.isOnboardingTestTranscribing {
            "waveform"
        } else if coordinator.isOnboardingTestRecording {
            "stop.fill"
        } else {
            "mic.fill"
        }
    }

    private func primaryAction() {
        if currentStep == .profile {
            coordinator.saveOnboardingProfile(name: nameDraft, useCase: useCaseDraft)
        }

        if currentStep == .summary {
            saveSummaryConfiguration()
        }

        if currentStep == .sync {
            AppTelemetry.signal("onboarding_icloud_sync_configured", parameters: [
                "enabled": iCloudSyncEnabled ? "true" : "false",
                "icloud_available": appleSyncSnapshot.isICloudAvailable ? "true" : "false"
            ])
        }

        if isLastStep {
            OnboardingPreferenceKeys.clear()
            coordinator.completeOnboarding()
        } else if let nextStep = currentStep.next(in: orderedSteps) {
            currentStep = nextStep
        }
    }

    private func goBack() {
        guard let previous = currentStep.previous(in: orderedSteps) else { return }
        currentStep = previous
    }

    private func refreshPermissionStatus() {
        refreshMicrophoneStatus()
        refreshKeyboardPermissionStatus()
    }

    private func refreshMicrophoneStatus() {
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    private func refreshKeyboardPermissionStatus() {
        guard useCaseDraft.needsKeyboardSetup else { return }

        do {
            permissionPollingError = nil
            guard let status = try SharedStore().keyboardExtensionStatus() else { return }
            keyboardExtensionLastSeenAt = status.lastSeenAt
            if status.hasOpenAccess {
                keyboardEnabledConfirmed = true
                fullAccessConfirmed = true
            }
        } catch {
            permissionPollingError = "Keyboard status will update after the Muesli Keyboard is opened with Full Access."
        }
    }

    private func requestMicrophonePermission() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in
                microphoneGranted = granted
                AppTelemetry.signal("onboarding_permission_result", parameters: [
                    "permission": "microphone",
                    "granted": granted ? "true" : "false"
                ])
            }
        }
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func refreshSummaryStatus() {
        openRouterAPIKey = MeetingSummaryClient.storedOpenRouterAPIKey()
        chatGPTSignedIn = ChatGPTAuthManager.shared.isAuthenticated
    }

    private func refreshAppleSyncStatus() {
        Task {
            appleSyncSnapshot = await AppleSyncAccountManager.shared.snapshot()
            AppTelemetry.signal(
                "onboarding_icloud_sync_status_checked",
                parameters: ["icloud_available": appleSyncSnapshot.isICloudAvailable ? "true" : "false"]
            )
            if iCloudSyncEnabled && !appleSyncSnapshot.isICloudAvailable {
                appleSyncStatusText = "Sign in to iCloud on this iPhone before enabling Muesli sync."
            } else if iCloudSyncEnabled {
                appleSyncStatusText = "Private iCloud sync is on. Open Muesli on your Mac to see the same text history."
            } else {
                appleSyncStatusText = nil
            }
        }
    }

    private func enablePrivateICloudBridge() {
        guard appleSyncSnapshot.isICloudAvailable else {
            appleSyncStatusText = "Sign in to iCloud on this iPhone, then return to Muesli."
            return
        }
        AppTelemetry.signal("bridge_enable_started", parameters: ["platform": "ios", "source": "onboarding"])
        iCloudSyncEnabled = true
        appleSyncStatusText = "Syncing your text history through private iCloud..."
        coordinator.syncICloudTextIfEnabled(reason: "onboarding_bridge")
        refreshAppleSyncStatus()
    }

    private func markBridgePromptSeen() {
        guard !bridgePromptSeen else { return }
        bridgePromptSeen = true
        AppTelemetry.signal("bridge_prompt_seen", parameters: ["platform": "ios"])
    }

    private func saveSummaryConfiguration() {
        UserDefaults.standard.set(meetingSummariesEnabled, forKey: MuesliPreferences.meetingSummariesEnabledKey)
        UserDefaults.standard.set(summaryBackend.rawValue, forKey: MuesliPreferences.meetingSummaryBackendKey)
        if summaryBackend == .openRouter {
            saveOpenRouterAPIKey(openRouterAPIKey)
        }
        AppTelemetry.signal("onboarding_summary_configured", parameters: [
            "enabled": meetingSummariesEnabled ? "true" : "false",
            "backend": summaryBackend.rawValue,
            "chatgpt_signed_in": chatGPTSignedIn ? "true" : "false",
            "openrouter_key_present": MeetingSummaryClient.storedOpenRouterAPIKey().isEmpty ? "false" : "true"
        ])
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

        isSigningInChatGPT = true
        summaryStatusText = nil
        Task {
            do {
                try await ChatGPTAuthManager.shared.signIn()
                chatGPTSignedIn = ChatGPTAuthManager.shared.isAuthenticated
                summaryStatusText = "Signed in to ChatGPT."
            } catch {
                chatGPTSignedIn = ChatGPTAuthManager.shared.isAuthenticated
                summaryStatusText = error.localizedDescription
            }
            isSigningInChatGPT = false
        }
    }

    private var modelActionTitle: String {
        switch coordinator.modelPreparation.phase {
        case .idle:
            "Download & Prepare"
        case .downloading:
            "Downloading"
        case .preparing:
            "Preparing"
        case .ready:
            "Ready"
        case .failed:
            "Try Again"
        }
    }

    private var modelActionIcon: String {
        switch coordinator.modelPreparation.phase {
        case .idle:
            "square.and.arrow.down"
        case .downloading, .preparing:
            "arrow.triangle.2.circlepath"
        case .ready:
            "checkmark"
        case .failed:
            "arrow.clockwise"
        }
    }

    private var modelButtonColor: Color {
        switch coordinator.modelPreparation.phase {
        case .ready:
            MuesliTheme.success
        case .failed:
            MuesliTheme.recording
        case .preparing:
            MuesliTheme.transcribing
        default:
            MuesliTheme.accent
        }
    }
}

private enum OnboardingStep: Int, CaseIterable {
    case profile
    case permissions
    case sync
    case model
    case test
    case summary

    var index: Int { rawValue }

    static func orderedSteps(for useCase: OnboardingUseCase) -> [OnboardingStep] {
        var steps: [OnboardingStep] = [.profile, .permissions, .sync, .model]
        if useCase.includesDictationTest {
            steps.append(.test)
        }
        if useCase.includesMeetingWorkflow {
            steps.append(.summary)
        }
        return steps
    }

    func position(in steps: [OnboardingStep]) -> Int {
        steps.firstIndex(of: self) ?? 0
    }

    func next(in steps: [OnboardingStep]) -> OnboardingStep? {
        let index = position(in: steps)
        guard index < steps.count - 1 else { return nil }
        return steps[index + 1]
    }

    func previous(in steps: [OnboardingStep]) -> OnboardingStep? {
        let index = position(in: steps)
        guard index > 0 else { return nil }
        return steps[index - 1]
    }

    var telemetryName: String {
        switch self {
        case .profile:
            "profile"
        case .permissions:
            "permissions"
        case .sync:
            "sync"
        case .model:
            "model"
        case .test:
            "test"
        case .summary:
            "summary"
        }
    }

    var subtitle: String {
        switch self {
        case .profile:
            "Tell Muesli how you plan to use it."
        case .permissions:
            "Grant only what the selected workflow needs."
        case .sync:
            "Optional private text sync."
        case .model:
            "Download and compile local transcription."
        case .test:
            "Confirm dictation works on this device."
        case .summary:
            "Connect meeting summary providers."
        }
    }
}

private struct IndeterminatePreparationBar: View {
    @State private var isAnimating = false

    var body: some View {
        GeometryReader { geometry in
            let trackWidth = geometry.size.width
            let segmentWidth = max(trackWidth * 0.32, 64)
            let travel = max(trackWidth - segmentWidth, 0)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(MuesliTheme.surfaceBorder)

                Capsule()
                    .fill(MuesliTheme.textSecondary.opacity(0.9))
                    .frame(width: segmentWidth)
                    .offset(x: isAnimating ? travel : 0)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.05).repeatForever(autoreverses: true)) {
                isAnimating = true
            }
        }
    }
}

private struct RotatingPreparationHint: View {
    let messages: [String]
    @State private var index = 0
    private let timer = Timer.publish(every: 6, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(messages.isEmpty ? "" : messages[index % messages.count])
            .font(MuesliTheme.caption())
            .foregroundStyle(MuesliTheme.textTertiary)
            .lineLimit(2)
            .id(index)
            .transition(.opacity)
            .onReceive(timer) { _ in
                guard messages.count > 1 else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    index = (index + 1) % messages.count
                }
            }
            .onChange(of: messages) { _, _ in
                index = 0
            }
    }
}
