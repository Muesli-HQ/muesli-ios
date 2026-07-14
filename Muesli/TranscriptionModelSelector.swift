import SwiftUI

struct TranscriptionModelSelector: View {
    @Binding var selection: LocalTranscriptionModel
    var showsHeader = true
    var preparation: ModelPreparationState? = nil
    var onSelect: ((LocalTranscriptionModel) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            if showsHeader {
                HStack(alignment: .center, spacing: MuesliTheme.spacing12) {
                    Image(systemName: "waveform.badge.magnifyingglass")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(MuesliTheme.accent)
                        .frame(width: 28, height: 28)
                        .background(MuesliTheme.accentSubtle)
                        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))

                    VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                        Text("Choose model")
                            .font(MuesliTheme.headline())
                            .foregroundStyle(MuesliTheme.textPrimary)
                        Text("Tap to switch local transcription model.")
                            .font(MuesliTheme.caption())
                            .foregroundStyle(MuesliTheme.textSecondary)
                    }

                    Spacer(minLength: MuesliTheme.spacing12)
                }
            }

            Menu {
                ForEach(LocalTranscriptionModelFamily.allCases) { family in
                    Section(family.title) {
                        ForEach(family.models) { model in
                            Button {
                                withAnimation(.snappy(duration: 0.18)) {
                                    if let onSelect {
                                        onSelect(model)
                                    } else {
                                        selection = model
                                    }
                                }
                            } label: {
                                Label(
                                    "\(model.displayName) · \(catalogState(for: model).menuLabel)",
                                    systemImage: catalogState(for: model).icon
                                )
                            }
                        }
                    }
                }
            } label: {
                HStack(alignment: .center, spacing: MuesliTheme.spacing12) {
                    Image(systemName: catalogState(for: selection).icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(MuesliTheme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))

                    VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                        Text("Active model")
                            .font(MuesliTheme.captionMedium())
                            .foregroundStyle(MuesliTheme.textSecondary)
                        Text(selection.displayName)
                            .font(MuesliTheme.headline())
                            .foregroundStyle(MuesliTheme.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                        Text(catalogState(for: selection).statusLabel)
                            .font(MuesliTheme.captionMedium())
                            .foregroundStyle(catalogState(for: selection).tint)
                    }

                    Spacer(minLength: MuesliTheme.spacing8)

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(MuesliTheme.accent)
                }
                .padding(MuesliTheme.spacing12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(MuesliTheme.accent.opacity(0.10))
                .muesliGlassSurface(cornerRadius: MuesliTheme.cornerMedium, tint: MuesliTheme.accent, isInteractive: true)
                .overlay(
                    RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium, style: .continuous)
                        .strokeBorder(MuesliTheme.accent.opacity(0.34), lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium, style: .continuous))
            }
            .menuOrder(.fixed)

            SelectedTranscriptionModelDetails(
                model: selection,
                state: catalogState(for: selection)
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Transcription model")
        .accessibilityValue("\(selection.displayName), \(catalogState(for: selection).statusLabel)")
    }

    private func catalogState(for model: LocalTranscriptionModel) -> ModelCatalogState {
        guard model == selection, let preparation else {
            return model.isDownloaded ? .ready : .needsDownload
        }
        switch preparation.phase {
        case .ready:
            return .ready
        case .downloading:
            return .downloading
        case .preparing:
            return .preparing
        case .failed:
            return .failed
        case .idle:
            return model.isDownloaded ? .ready : .needsDownload
        }
    }
}

private struct SelectedTranscriptionModelDetails: View {
    let model: LocalTranscriptionModel
    let state: ModelCatalogState

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing10) {
            Text(model.detail)
                .font(MuesliTheme.callout())
                .foregroundStyle(MuesliTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: MuesliTheme.spacing8) {
                    ForEach(model.selectorBadges, id: \.label) { badge in
                        TranscriptionModelBadge(icon: badge.icon, label: badge.label)
                    }
                }

                VStack(alignment: .leading, spacing: MuesliTheme.spacing6) {
                    ForEach(model.selectorBadges, id: \.label) { badge in
                        TranscriptionModelBadge(icon: badge.icon, label: badge.label)
                    }
                }
            }

            Label(state.detailLabel, systemImage: state.icon)
                .font(MuesliTheme.captionMedium())
                .foregroundStyle(state.tint)
        }
        .padding(MuesliTheme.spacing12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .muesliGlassSurface(cornerRadius: MuesliTheme.cornerMedium)
    }
}

private struct TranscriptionModelBadge: View {
    let icon: String
    let label: String

    var body: some View {
        Label(label, systemImage: icon)
            .font(MuesliTheme.captionMedium())
            .foregroundStyle(MuesliTheme.textSecondary)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, MuesliTheme.spacing8)
            .padding(.vertical, MuesliTheme.spacing4)
            .muesliGlassSurface(cornerRadius: 14)
    }
}

private extension MuesliTheme {
    static let spacing6: CGFloat = 6
    static let spacing10: CGFloat = 10
}

private extension LocalTranscriptionModel {
    var selectorBadges: [(icon: String, label: String)] {
        var badges: [(icon: String, label: String)] = [
            ("textformat", capabilityLabel),
            ("internaldrive", estimatedSizeLabel)
        ]

        if supportsRealtimeStreaming {
            badges.insert(("waveform.path.ecg", "Streaming"), at: 0)
        }

        return badges
    }
}

private enum ModelCatalogState {
    case ready
    case needsDownload
    case downloading
    case preparing
    case failed

    var icon: String {
        switch self {
        case .ready:
            "checkmark.circle.fill"
        case .needsDownload:
            "arrow.down.circle"
        case .downloading:
            "arrow.down.circle.fill"
        case .preparing:
            "gearshape.2.fill"
        case .failed:
            "exclamationmark.triangle.fill"
        }
    }

    var menuLabel: String {
        switch self {
        case .ready:
            "Downloaded"
        case .needsDownload:
            "Download"
        case .downloading:
            "Downloading"
        case .preparing:
            "Preparing"
        case .failed:
            "Retry needed"
        }
    }

    var statusLabel: String {
        switch self {
        case .ready:
            "Downloaded and ready"
        case .needsDownload:
            "Downloads automatically when selected"
        case .downloading:
            "Downloading automatically"
        case .preparing:
            "Optimizing for this iPhone"
        case .failed:
            "Download paused"
        }
    }

    var detailLabel: String {
        switch self {
        case .ready:
            "Stored locally on this iPhone"
        case .needsDownload:
            "Select to download and prepare automatically"
        case .downloading:
            "You can leave this screen while the download continues"
        case .preparing:
            "The downloaded model is being compiled for this device"
        case .failed:
            "Check your connection, then use the retry option below"
        }
    }

    var tint: Color {
        switch self {
        case .ready:
            MuesliTheme.success
        case .failed:
            MuesliTheme.destructive
        case .needsDownload, .downloading, .preparing:
            MuesliTheme.accent
        }
    }
}
