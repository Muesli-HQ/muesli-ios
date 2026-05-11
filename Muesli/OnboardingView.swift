import AVFoundation
import SwiftUI
import UIKit

struct OnboardingView: View {
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
                    case .model:
                        modelStep
                    case .test:
                        testStep
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
            refreshMicrophoneStatus()
            AppTelemetry.signal("onboarding_viewed")
            AppTelemetry.signal("onboarding_step_viewed", parameters: ["step": currentStep.telemetryName])
            if currentStep == .model {
                coordinator.prepareModelForOnboarding()
            }
        }
        .onChange(of: currentStep) { _, step in
            UserDefaults.standard.set(step.rawValue, forKey: OnboardingPreferenceKeys.currentStep)
            AppTelemetry.signal("onboarding_step_viewed", parameters: ["step": step.telemetryName])
            if step == .model {
                coordinator.prepareModelForOnboarding()
            }
        }
        .onChange(of: keyboardEnabledConfirmed) { _, confirmed in
            UserDefaults.standard.set(confirmed, forKey: OnboardingPreferenceKeys.keyboardEnabledConfirmed)
        }
        .onChange(of: fullAccessConfirmed) { _, confirmed in
            UserDefaults.standard.set(confirmed, forKey: OnboardingPreferenceKeys.fullAccessConfirmed)
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
                ForEach(OnboardingStep.allCases, id: \.self) { step in
                    Capsule()
                        .fill(step.index <= currentStep.index ? MuesliTheme.accent : MuesliTheme.surfacePrimary)
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
                    detail: "Return here after adding Muesli Keyboard",
                    isComplete: keyboardEnabledConfirmed,
                    buttonTitle: keyboardEnabledConfirmed ? "Done" : "I Added It"
                ) {
                    keyboardEnabledConfirmed = true
                }

                permissionRow(
                    icon: "network",
                    title: "Full Access",
                    detail: "Return here after enabling Full Access for Muesli Keyboard",
                    isComplete: fullAccessConfirmed,
                    buttonTitle: fullAccessConfirmed ? "Done" : "I Enabled It"
                ) {
                    fullAccessConfirmed = true
                }
            }
        }
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

    private var modelStep: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing20) {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                Text("Prepare Model")
                    .font(MuesliTheme.title1())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Text("Parakeet v3 runs on CoreML / ANE. First setup downloads and compiles the model for this iPhone.")
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textSecondary)
            }

            modelPanel
        }
    }

    private var modelPanel: some View {
        MuesliSurface(cornerRadius: MuesliTheme.cornerLarge) {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
                HStack(alignment: .top, spacing: MuesliTheme.spacing12) {
                    modelStatusIcon

                    VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                        Text("Parakeet v3")
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
                            coordinator.isOnboardingTestRecording ? "Stop Recording" : "Start Test",
                            systemImage: coordinator.isOnboardingTestRecording ? "stop.fill" : "mic.fill"
                        )
                        .font(MuesliTheme.headline())
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(coordinator.isOnboardingTestRecording ? MuesliTheme.recording : MuesliTheme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                    .disabled(!coordinator.modelPreparation.isReady)

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

    private var footer: some View {
        HStack(spacing: MuesliTheme.spacing12) {
            if currentStep != .profile {
                Button {
                    goBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 44, height: 48)
                }
                .buttonStyle(.plain)
                .foregroundStyle(MuesliTheme.textSecondary)
                .background(MuesliTheme.backgroundRaised)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
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
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(canContinue ? MuesliTheme.accent : MuesliTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
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
        case .model:
            coordinator.modelPreparation.isReady ? "Continue" : "Skip for Now"
        case .test:
            "Finish"
        }
    }

    private var canContinue: Bool {
        switch currentStep {
        case .profile:
            !nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .permissions:
            microphoneGranted && (!useCaseDraft.needsKeyboardSetup || (keyboardEnabledConfirmed && fullAccessConfirmed))
        case .model:
            !coordinator.modelPreparation.isPreparing
        case .test:
            !coordinator.isOnboardingTestRecording && !coordinator.onboardingTestTranscript.isEmpty
        }
    }

    private func primaryAction() {
        switch currentStep {
        case .profile:
            coordinator.saveOnboardingProfile(name: nameDraft, useCase: useCaseDraft)
            currentStep = .permissions
        case .permissions:
            currentStep = .model
        case .model:
            currentStep = .test
        case .test:
            OnboardingPreferenceKeys.clear()
            coordinator.completeOnboarding()
        }
    }

    private func goBack() {
        guard let previous = OnboardingStep(rawValue: currentStep.index - 1) else { return }
        currentStep = previous
    }

    private func refreshMicrophoneStatus() {
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
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
    case model
    case test

    var index: Int { rawValue }

    var telemetryName: String {
        switch self {
        case .profile:
            "profile"
        case .permissions:
            "permissions"
        case .model:
            "model"
        case .test:
            "test"
        }
    }

    var subtitle: String {
        switch self {
        case .profile:
            "Tell Muesli how you plan to use it."
        case .permissions:
            "Grant only what the selected workflow needs."
        case .model:
            "Download and compile local transcription."
        case .test:
            "Confirm dictation works on this device."
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
