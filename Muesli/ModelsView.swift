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
                    showsHeader: false,
                    preparation: coordinator.modelPreparation,
                    onSelect: coordinator.selectTranscriptionModel
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
    }

    private var runtimePanel: some View {
        MuesliSurface {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                ModelInfoRow(
                    icon: "cpu",
                    title: "Runtime",
                    value: coordinator.selectedTranscriptionModel.family == .whisper
                        ? "WhisperKit / CoreML"
                        : "FluidAudio / CoreML"
                )
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
            MuesliTheme.destructive
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
