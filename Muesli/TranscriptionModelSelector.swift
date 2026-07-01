import SwiftUI

struct TranscriptionModelSelector: View {
    @Binding var selection: LocalTranscriptionModel
    var showsHeader = true

    private let models = LocalTranscriptionModel.allCases

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
                ForEach(models) { model in
                    Button {
                        withAnimation(.snappy(duration: 0.18)) {
                            selection = model
                        }
                    } label: {
                        Label(
                            model.displayName,
                            systemImage: selection == model ? "checkmark" : model.selectorIcon
                        )
                    }
                }
            } label: {
                HStack(alignment: .center, spacing: MuesliTheme.spacing12) {
                    Image(systemName: selection.selectorIcon)
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

            SelectedTranscriptionModelDetails(model: selection)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Transcription model")
        .accessibilityValue(selection.displayName)
    }
}

private struct SelectedTranscriptionModelDetails: View {
    let model: LocalTranscriptionModel

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
    var selectorIcon: String {
        switch self {
        case .parakeetTdtCtc110m:
            "bolt.fill"
        case .parakeetRealtimeEou120m:
            "dot.radiowaves.left.and.right"
        case .parakeetV3:
            "globe"
        }
    }

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
