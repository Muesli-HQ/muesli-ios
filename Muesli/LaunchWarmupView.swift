import SwiftUI

struct LaunchWarmupContainer<Content: View>: View {
    @Bindable var coordinator: DictationCoordinator
    @State private var isShowingWarmup = true
    @State private var didRunWarmup = false
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            content

            if isShowingWarmup && coordinator.shouldShowLaunchWarmup {
                LaunchWarmupView(
                    phase: coordinator.modelPreparation.phase,
                    status: coordinator.modelPreparation.status,
                    detail: coordinator.modelPreparation.detail,
                    modelName: coordinator.selectedTranscriptionModel.shortName
                )
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .task {
            await runLaunchWarmup()
        }
    }

    private func runLaunchWarmup() async {
        guard !didRunWarmup else { return }
        didRunWarmup = true

        guard coordinator.shouldShowLaunchWarmup else {
            isShowingWarmup = false
            return
        }

        let startedAt = ContinuousClock.now
        coordinator.prewarmModelIfNeeded(reason: "launch_screen")

        while !Task.isCancelled {
            let elapsed = startedAt.duration(to: .now)
            let maximumDisplayReached = elapsed >= .seconds(5)
            let warmupFinished = !coordinator.isModelPrewarmInProgress && !coordinator.modelPreparation.isPreparing

            if warmupFinished || maximumDisplayReached {
                break
            }

            try? await Task.sleep(for: .milliseconds(120))
        }

        guard !Task.isCancelled else { return }
        await MainActor.run {
            withAnimation(.easeOut(duration: 0.32)) {
                isShowingWarmup = false
            }
        }
    }
}

private struct LaunchWarmupView: View {
    let phase: ModelPreparationPhase
    let status: String
    let detail: String
    let modelName: String

    @State private var isAnimating = false

    var body: some View {
        ZStack {
            background
                .ignoresSafeArea()

            brandMark
                .offset(y: -18)

            VStack {
                Spacer()
                warmupStatus
                    .padding(.bottom, 78)
            }

            VStack {
                Spacer()
                Text(versionText)
                    .font(MuesliTheme.caption())
                    .foregroundStyle(.white.opacity(0.24))
                    .padding(.bottom, 18)
                    .accessibilityHidden(true)
            }
            .ignoresSafeArea(.keyboard)
        }
        .task(id: phase) {
            updateAnimation(for: phase)
        }
    }

    private func updateAnimation(for phase: ModelPreparationPhase) {
        if phase.isLaunchWarmupActive {
            withAnimation(.linear(duration: 1.15).repeatForever(autoreverses: false)) {
                isAnimating = true
            }
        } else {
            isAnimating = false
        }
    }

    private var background: some View {
        LinearGradient(
            colors: [
                Color(hex: 0x030711),
                Color(hex: 0x07111F),
                Color(hex: 0x02040A)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            LinearGradient(
                colors: [
                    MuesliTheme.brandBlue.opacity(0.16),
                    .clear,
                    MuesliTheme.syncGreen.opacity(0.10)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var brandMark: some View {
        VStack(spacing: MuesliTheme.spacing16) {
            Image("MuesliAppIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 74, height: 74)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: MuesliTheme.brandBlue.opacity(0.48), radius: 24, x: 0, y: 0)

            Text("muesli")
                .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                .foregroundStyle(.white.opacity(0.94))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("muesli")
    }

    private var warmupStatus: some View {
        VStack(spacing: MuesliTheme.spacing16) {
            HStack(spacing: MuesliTheme.spacing12) {
                if phase == .failed {
                    Image(systemName: "pause.circle")
                        .foregroundStyle(.white.opacity(0.68))
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .tint(MuesliTheme.syncGreen)
                }

                Text(displayStatus)
                    .font(MuesliTheme.callout())
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, MuesliTheme.spacing20)

            WarmupPulseLine(isAnimating: isAnimating)
                .frame(width: 176, height: 3)
                .accessibilityHidden(true)

            Text(displayDetail)
                .font(MuesliTheme.caption())
                .foregroundStyle(.white.opacity(0.38))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(displayStatus). \(displayDetail). \(versionText)")
    }

    private var displayStatus: String {
        let trimmedStatus = status.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedStatus.localizedCaseInsensitiveContains("ready") {
            return "Transcription engine ready"
        }
        if phase == .failed {
            return trimmedStatus.isEmpty ? "Warmup paused" : trimmedStatus
        }
        return "Warming up the transcription engine..."
    }

    private var displayDetail: String {
        let trimmedDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedDetail.isEmpty || trimmedDetail.localizedCaseInsensitiveContains("not downloaded") {
            let trimmedStatus = status.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedStatus.isEmpty ? modelName : trimmedStatus
        }
        return trimmedDetail
    }

    private var versionText: String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return build.isEmpty ? "v\(version)" : "v\(version) (\(build))"
    }
}

private extension ModelPreparationPhase {
    var isLaunchWarmupActive: Bool {
        self == .downloading || self == .preparing
    }
}

private struct WarmupPulseLine: View {
    let isAnimating: Bool

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.10))

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                MuesliTheme.brandBlue.opacity(0.25),
                                MuesliTheme.syncGreen,
                                MuesliTheme.brandBlue.opacity(0.25)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: width * 0.36)
                    .offset(x: isAnimating ? width * 0.64 : 0)
            }
        }
        .clipShape(Capsule())
    }
}
