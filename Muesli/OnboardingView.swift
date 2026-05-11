import SwiftUI

struct OnboardingView: View {
    @Bindable var coordinator: DictationCoordinator
    @State private var telemetryEnabled = AppTelemetry.isEnabled

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing24) {
                header
                modelPanel
                telemetryPanel
                continueButton
            }
            .padding(.horizontal, MuesliTheme.spacing20)
            .padding(.top, MuesliTheme.spacing32)
            .padding(.bottom, MuesliTheme.spacing24)
        }
        .background(MuesliTheme.backgroundBase)
        .tint(MuesliTheme.accent)
        .onAppear {
            AppTelemetry.signal("onboarding_viewed")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            HStack(spacing: MuesliTheme.spacing12) {
                Image("MuesliAppIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    Text("Set up muesli")
                        .font(MuesliTheme.title1())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text("Private voice input, prepared on this iPhone.")
                        .font(MuesliTheme.callout())
                        .foregroundStyle(MuesliTheme.textSecondary)
                }
            }
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

                Button {
                    coordinator.prepareModelForOnboarding()
                } label: {
                    HStack(spacing: MuesliTheme.spacing8) {
                        Image(systemName: modelActionIcon)
                        Text(modelActionTitle)
                    }
                    .font(MuesliTheme.headline())
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(modelButtonColor)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                .disabled(coordinator.modelPreparation.isPreparing || coordinator.modelPreparation.isReady)
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

    private var telemetryPanel: some View {
        MuesliSurface {
            Toggle(isOn: $telemetryEnabled) {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    Text("Share anonymous telemetry")
                        .font(MuesliTheme.headline())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text("Setup progress, model readiness, and feature usage. No audio or transcript text.")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                }
            }
            .toggleStyle(.switch)
            .padding(MuesliTheme.spacing16)
        }
    }

    private var continueButton: some View {
        Button {
            coordinator.completeOnboarding(telemetryEnabled: telemetryEnabled)
        } label: {
            HStack(spacing: MuesliTheme.spacing8) {
                Image(systemName: "arrow.right")
                Text(coordinator.modelPreparation.isReady ? "Continue" : "Skip for Now")
            }
            .font(MuesliTheme.headline())
            .frame(maxWidth: .infinity)
            .frame(height: 50)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(MuesliTheme.accent)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
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
