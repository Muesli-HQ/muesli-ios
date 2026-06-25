import SwiftUI

struct ModelsView: View {
    @Bindable var coordinator: DictationCoordinator

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing20) {
                    header
                    activeModelPanel
                    runtimePanel
                }
                .padding(.horizontal, MuesliTheme.spacing20)
                .padding(.top, MuesliTheme.spacing24)
                .padding(.bottom, MuesliTheme.spacing24)
            }
            .background(MuesliTheme.backgroundBase)
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
            Text("Models")
                .font(MuesliTheme.title1())
                .foregroundStyle(MuesliTheme.textPrimary)
            Text("Manage local transcription models that run on this iPhone.")
                .font(MuesliTheme.callout())
                .foregroundStyle(MuesliTheme.textSecondary)
        }
    }

    private var activeModelPanel: some View {
        MuesliSurface(cornerRadius: MuesliTheme.cornerLarge) {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
                HStack(alignment: .top, spacing: MuesliTheme.spacing12) {
                    Image(systemName: modelIcon)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(modelTint)
                        .frame(width: 42, height: 42)
                        .background(modelTint.opacity(0.14))
                        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))

                    VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                        Text(coordinator.selectedTranscriptionModel.shortName)
                            .font(MuesliTheme.title3())
                            .foregroundStyle(MuesliTheme.textPrimary)
                        Text("CoreML / ANE")
                            .font(MuesliTheme.captionMedium())
                            .foregroundStyle(MuesliTheme.textSecondary)
                    }

                    Spacer()

                    Text(modelBadge)
                        .font(MuesliTheme.captionMedium())
                        .foregroundStyle(modelTint)
                        .padding(.horizontal, MuesliTheme.spacing8)
                        .padding(.vertical, MuesliTheme.spacing4)
                        .background(modelTint.opacity(0.12))
                        .clipShape(Capsule())
                }

                TranscriptionModelSelector(
                    selection: $coordinator.selectedTranscriptionModel,
                    showsHeader: false
                )

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

    private var runtimePanel: some View {
        MuesliSurface {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                ModelInfoRow(icon: "cpu", title: "Runtime", value: "CoreML / ANE")
                Divider().overlay(MuesliTheme.surfaceBorder)
                ModelInfoRow(icon: "waveform", title: "Engine", value: coordinator.selectedTranscriptionModel.shortName)
                Divider().overlay(MuesliTheme.surfaceBorder)
                ModelInfoRow(icon: "textformat", title: "Language", value: coordinator.selectedTranscriptionModel.capabilityLabel)
                Divider().overlay(MuesliTheme.surfaceBorder)
                ModelInfoRow(icon: "iphone", title: "Execution", value: "On device")
            }
            .padding(MuesliTheme.spacing16)
        }
    }

    private var modelIcon: String {
        switch coordinator.modelPreparation.phase {
        case .ready:
            "checkmark.seal.fill"
        case .downloading, .preparing:
            "arrow.down.circle.fill"
        case .failed:
            "exclamationmark.triangle.fill"
        case .idle:
            "square.and.arrow.down"
        }
    }

    private var modelTint: Color {
        switch coordinator.modelPreparation.phase {
        case .ready:
            MuesliTheme.success
        case .failed:
            MuesliTheme.recording
        case .downloading, .preparing:
            MuesliTheme.transcribing
        case .idle:
            MuesliTheme.accent
        }
    }

    private var modelBadge: String {
        switch coordinator.modelPreparation.phase {
        case .ready:
            "Ready"
        case .downloading:
            "Downloading"
        case .preparing:
            "Preparing"
        case .failed:
            "Paused"
        case .idle:
            "Not prepared"
        }
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
}

private struct ModelInfoRow: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: MuesliTheme.spacing12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(MuesliTheme.accent)
                .frame(width: 22)
            Text(title)
                .font(MuesliTheme.headline())
                .foregroundStyle(MuesliTheme.textPrimary)
            Spacer()
            Text(value)
                .font(MuesliTheme.callout())
                .foregroundStyle(MuesliTheme.textTertiary)
        }
    }
}
