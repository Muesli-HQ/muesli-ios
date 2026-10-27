import SwiftUI

struct TranscriptionModelSelector: View {
    @Binding var selection: LocalTranscriptionModel
    var downloadedModels: Set<LocalTranscriptionModel>
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
                ForEach(LocalTranscriptionModelFamily.allCases.filter { !$0.models.isEmpty }) { family in
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
                                    model.displayName,
                                    systemImage: catalogState(for: model).icon
                                )
                            }
                            .accessibilityValue(catalogState(for: model).menuLabel)
                        }
                    }
                }
            } label: {
                HStack(alignment: .center, spacing: MuesliTheme.spacing12) {
                    TranscriptionModelLogo(model: selection)
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: catalogState(for: selection).icon)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(catalogState(for: selection).tint)
                                .background(Circle().fill(MuesliTheme.backgroundBase))
                                .offset(x: 4, y: 4)
                        }

                    VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                        Text(preparation?.isReady == true && downloadedModels.contains(selection) ? "Active model" : "Selected model")
                            .font(MuesliTheme.captionMedium())
                            .foregroundStyle(MuesliTheme.textSecondary)
                        Text(selection.displayName)
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            .foregroundStyle(MuesliTheme.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                        Text(selection == .appleSpeech ? (preparation?.isReady == true ? "Ready on this iPhone" : "Language setup managed by iOS") : catalogState(for: selection).statusLabel)
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
        ModelCatalogState.resolve(isDownloaded: downloadedModels.contains(model),
                                  preparation: model == selection ? preparation : nil)
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

            Label(model == .appleSpeech ? "Language assets managed by iOS" : state.detailLabel, systemImage: state.icon)
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

enum ModelCatalogState: Equatable {
    case ready
    case needsDownload
    case downloading
    case preparing
    case failed

    static func resolve(isDownloaded: Bool, preparation: ModelPreparationState?) -> Self {
        switch preparation?.phase {
        case .downloading: return .downloading
        case .preparing: return .preparing
        case .failed: return .failed
        case .ready, .idle, nil: return isDownloaded ? .ready : .needsDownload
        }
    }

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
            "Setup needs attention"
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
            "Review the setup message below, then retry"
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

/// Provider branding is independent of download and runtime readiness.
struct TranscriptionModelLogo: View {
    let model: LocalTranscriptionModel

    var body: some View {
        Group {
            if model.family == .apple {
                Image(systemName: "apple.logo").font(.title2)
            } else if model.family == .parakeet {
                Image("NvidiaLogo")
                    .resizable()
                    .scaledToFit()
                    .padding(4)
                    .background(.white)
            } else {
                OpenAILogoShape()
                    .fill(MuesliTheme.textPrimary)
                    .frame(width: 25, height: 25)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
    }
}

// Same scalable OpenAI mark used by the macOS model picker.
private struct OpenAILogoShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 24
        let sy = rect.height / 24
        var p = Path()
        p.move(to: CGPoint(x: 22.2819 * sx, y: 9.8211 * sy))
        p.addCurve(to: CGPoint(x: 21.7662 * sx, y: 4.9103 * sy), control1: CGPoint(x: 22.8248 * sx, y: 8.1862 * sy), control2: CGPoint(x: 22.6369 * sx, y: 6.3967 * sy))
        p.addCurve(to: CGPoint(x: 15.2564 * sx, y: 2.0103 * sy), control1: CGPoint(x: 20.4571 * sx, y: 2.6316 * sy), control2: CGPoint(x: 17.8260 * sx, y: 1.4595 * sy))
        p.addCurve(to: CGPoint(x: 4.9807 * sx, y: 4.1818 * sy), control1: CGPoint(x: 12.1364 * sx, y: -1.4602 * sy), control2: CGPoint(x: 6.4298 * sx, y: -0.2543 * sy))
        p.addCurve(to: CGPoint(x: 0.9830 * sx, y: 7.0818 * sy), control1: CGPoint(x: 3.2928 * sx, y: 4.5279 * sy), control2: CGPoint(x: 1.8360 * sx, y: 5.5847 * sy))
        p.addCurve(to: CGPoint(x: 1.7257 * sx, y: 14.1784 * sy), control1: CGPoint(x: -0.3404 * sx, y: 9.3568 * sy), control2: CGPoint(x: -0.0401 * sx, y: 12.2267 * sy))
        p.addCurve(to: CGPoint(x: 2.2367 * sx, y: 19.0891 * sy), control1: CGPoint(x: 1.1808 * sx, y: 15.8125 * sy), control2: CGPoint(x: 1.3670 * sx, y: 17.6022 * sy))
        p.addCurve(to: CGPoint(x: 8.7513 * sx, y: 21.9892 * sy), control1: CGPoint(x: 3.5475 * sx, y: 21.3686 * sy), control2: CGPoint(x: 6.1803 * sx, y: 22.5406 * sy))
        p.addCurve(to: CGPoint(x: 13.2599 * sx, y: 24.0000 * sy), control1: CGPoint(x: 9.8948 * sx, y: 23.2770 * sy), control2: CGPoint(x: 11.5377 * sx, y: 24.0097 * sy))
        p.addCurve(to: CGPoint(x: 19.0317 * sx, y: 19.7942 * sy), control1: CGPoint(x: 15.8937 * sx, y: 24.0024 * sy), control2: CGPoint(x: 18.2271 * sx, y: 22.3021 * sy))
        p.addCurve(to: CGPoint(x: 23.0294 * sx, y: 16.8941 * sy), control1: CGPoint(x: 20.7194 * sx, y: 19.4475 * sy), control2: CGPoint(x: 22.1760 * sx, y: 18.3908 * sy))
        p.addCurve(to: CGPoint(x: 22.2819 * sx, y: 9.8212 * sy), control1: CGPoint(x: 24.3368 * sx, y: 14.6231 * sy), control2: CGPoint(x: 24.0351 * sx, y: 11.7688 * sy))
        p.closeSubpath()
        p.move(to: CGPoint(x: 13.2599 * sx, y: 22.4292 * sy))
        p.addCurve(to: CGPoint(x: 10.3835 * sx, y: 21.3884 * sy), control1: CGPoint(x: 12.2086 * sx, y: 22.4309 * sy), control2: CGPoint(x: 11.1903 * sx, y: 22.0624 * sy))
        p.addLine(to: CGPoint(x: 10.5254 * sx, y: 21.3080 * sy))
        p.addLine(to: CGPoint(x: 15.3037 * sx, y: 18.5498 * sy))
        p.addCurve(to: CGPoint(x: 15.6964 * sx, y: 17.8685 * sy), control1: CGPoint(x: 15.5456 * sx, y: 18.4079 * sy), control2: CGPoint(x: 15.6949 * sx, y: 18.1490 * sy))
        p.addLine(to: CGPoint(x: 15.6964 * sx, y: 11.1316 * sy))
        p.addLine(to: CGPoint(x: 17.7164 * sx, y: 12.3002 * sy))
        p.addCurve(to: CGPoint(x: 17.7544 * sx, y: 12.3522 * sy), control1: CGPoint(x: 17.7367 * sx, y: 12.3105 * sy), control2: CGPoint(x: 17.7508 * sx, y: 12.3298 * sy))
        p.addLine(to: CGPoint(x: 17.7544 * sx, y: 17.9348 * sy))
        p.addCurve(to: CGPoint(x: 13.2599 * sx, y: 22.4292 * sy), control1: CGPoint(x: 17.7491 * sx, y: 20.4148 * sy), control2: CGPoint(x: 15.7399 * sx, y: 22.4240 * sy))
        p.closeSubpath()
        p.move(to: CGPoint(x: 3.5992 * sx, y: 18.3038 * sy))
        p.addCurve(to: CGPoint(x: 3.0646 * sx, y: 15.2901 * sy), control1: CGPoint(x: 3.0720 * sx, y: 17.3934 * sy), control2: CGPoint(x: 2.8827 * sx, y: 16.3263 * sy))
        p.addLine(to: CGPoint(x: 3.2066 * sx, y: 15.3753 * sy))
        p.addLine(to: CGPoint(x: 7.9896 * sx, y: 18.1335 * sy))
        p.addCurve(to: CGPoint(x: 8.7702 * sx, y: 18.1335 * sy), control1: CGPoint(x: 8.2306 * sx, y: 18.2749 * sy), control2: CGPoint(x: 8.5292 * sx, y: 18.2749 * sy))
        p.addLine(to: CGPoint(x: 14.6130 * sx, y: 14.7650 * sy))
        p.addLine(to: CGPoint(x: 14.6130 * sx, y: 17.0974 * sy))
        p.addCurve(to: CGPoint(x: 14.5798 * sx, y: 17.1589 * sy), control1: CGPoint(x: 14.6119 * sx, y: 17.1219 * sy), control2: CGPoint(x: 14.5997 * sx, y: 17.1445 * sy))
        p.addLine(to: CGPoint(x: 9.7400 * sx, y: 19.9502 * sy))
        p.addCurve(to: CGPoint(x: 3.5992 * sx, y: 18.3038 * sy), control1: CGPoint(x: 7.5893 * sx, y: 21.1891 * sy), control2: CGPoint(x: 4.8416 * sx, y: 20.4525 * sy))
        p.closeSubpath()
        p.move(to: CGPoint(x: 2.3408 * sx, y: 7.8956 * sy))
        p.addCurve(to: CGPoint(x: 4.7063 * sx, y: 5.9228 * sy), control1: CGPoint(x: 2.8717 * sx, y: 6.9794 * sy), control2: CGPoint(x: 3.7096 * sx, y: 6.2805 * sy))
        p.addLine(to: CGPoint(x: 4.7063 * sx, y: 11.6000 * sy))
        p.addCurve(to: CGPoint(x: 5.0942 * sx, y: 12.2765 * sy), control1: CGPoint(x: 4.7026 * sx, y: 11.8793 * sy), control2: CGPoint(x: 4.8513 * sx, y: 12.1386 * sy))
        p.addLine(to: CGPoint(x: 10.9086 * sx, y: 15.6308 * sy))
        p.addLine(to: CGPoint(x: 8.8885 * sx, y: 16.7993 * sy))
        p.addCurve(to: CGPoint(x: 8.8175 * sx, y: 16.7993 * sy), control1: CGPoint(x: 8.8663 * sx, y: 16.8111 * sy), control2: CGPoint(x: 8.8397 * sx, y: 16.8111 * sy))
        p.addLine(to: CGPoint(x: 3.9872 * sx, y: 14.0128 * sy))
        p.addCurve(to: CGPoint(x: 2.3408 * sx, y: 7.8720 * sy), control1: CGPoint(x: 1.8408 * sx, y: 12.7686 * sy), control2: CGPoint(x: 1.1047 * sx, y: 10.0230 * sy))
        p.closeSubpath()
        p.move(to: CGPoint(x: 18.9371 * sx, y: 11.7514 * sy))
        p.addLine(to: CGPoint(x: 13.1038 * sx, y: 8.3640 * sy))
        p.addLine(to: CGPoint(x: 15.1192 * sx, y: 7.2000 * sy))
        p.addCurve(to: CGPoint(x: 15.1902 * sx, y: 7.2000 * sy), control1: CGPoint(x: 15.1414 * sx, y: 7.1882 * sy), control2: CGPoint(x: 15.1680 * sx, y: 7.1882 * sy))
        p.addLine(to: CGPoint(x: 20.0205 * sx, y: 9.9913 * sy))
        p.addCurve(to: CGPoint(x: 19.3440 * sx, y: 18.0955 * sy), control1: CGPoint(x: 23.3136 * sx, y: 11.8915 * sy), control2: CGPoint(x: 22.9065 * sx, y: 16.7676 * sy))
        p.addLine(to: CGPoint(x: 19.3440 * sx, y: 12.4183 * sy))
        p.addCurve(to: CGPoint(x: 18.9370 * sx, y: 11.7513 * sy), control1: CGPoint(x: 19.3355 * sx, y: 12.1397 * sy), control2: CGPoint(x: 19.1808 * sx, y: 11.8863 * sy))
        p.closeSubpath()
        p.move(to: CGPoint(x: 20.9478 * sx, y: 8.7283 * sy))
        p.addLine(to: CGPoint(x: 20.8058 * sx, y: 8.6431 * sy))
        p.addLine(to: CGPoint(x: 16.0323 * sx, y: 5.8613 * sy))
        p.addCurve(to: CGPoint(x: 15.2469 * sx, y: 5.8613 * sy), control1: CGPoint(x: 15.7898 * sx, y: 5.7190 * sy), control2: CGPoint(x: 15.4894 * sx, y: 5.7190 * sy))
        p.addLine(to: CGPoint(x: 9.4090 * sx, y: 9.2297 * sy))
        p.addLine(to: CGPoint(x: 9.4090 * sx, y: 6.8974 * sy))
        p.addCurve(to: CGPoint(x: 9.4374 * sx, y: 6.8359 * sy), control1: CGPoint(x: 9.4065 * sx, y: 6.8732 * sy), control2: CGPoint(x: 9.4174 * sx, y: 6.8496 * sy))
        p.addLine(to: CGPoint(x: 14.2677 * sx, y: 4.0493 * sy))
        p.addCurve(to: CGPoint(x: 20.9479 * sx, y: 8.7093 * sy), control1: CGPoint(x: 17.5693 * sx, y: 2.1473 * sy), control2: CGPoint(x: 21.5928 * sx, y: 4.9539 * sy))
        p.closeSubpath()
        p.move(to: CGPoint(x: 8.3065 * sx, y: 12.8630 * sy))
        p.addLine(to: CGPoint(x: 6.2865 * sx, y: 11.6992 * sy))
        p.addCurve(to: CGPoint(x: 6.2485 * sx, y: 11.6425 * sy), control1: CGPoint(x: 6.2660 * sx, y: 11.6869 * sy), control2: CGPoint(x: 6.2521 * sx, y: 11.6661 * sy))
        p.addLine(to: CGPoint(x: 6.2485 * sx, y: 6.0742 * sy))
        p.addCurve(to: CGPoint(x: 13.6242 * sx, y: 2.6205 * sy), control1: CGPoint(x: 6.2535 * sx, y: 2.2647 * sy), control2: CGPoint(x: 10.6950 * sx, y: 0.1849 * sy))
        p.addLine(to: CGPoint(x: 13.4822 * sx, y: 2.7010 * sy))
        p.addLine(to: CGPoint(x: 8.7040 * sx, y: 5.4590 * sy))
        p.addCurve(to: CGPoint(x: 8.3113 * sx, y: 6.1403 * sy), control1: CGPoint(x: 8.4621 * sx, y: 5.6009 * sy), control2: CGPoint(x: 8.3128 * sx, y: 5.8598 * sy))
        p.closeSubpath()
        // Inner hexagon
        p.move(to: CGPoint(x: 9.4041 * sx, y: 10.4976 * sy))
        p.addLine(to: CGPoint(x: 12.0061 * sx, y: 8.9978 * sy))
        p.addLine(to: CGPoint(x: 14.6130 * sx, y: 10.4976 * sy))
        p.addLine(to: CGPoint(x: 14.6130 * sx, y: 13.4970 * sy))
        p.addLine(to: CGPoint(x: 12.0156 * sx, y: 14.9967 * sy))
        p.addLine(to: CGPoint(x: 9.4089 * sx, y: 13.4970 * sy))
        p.closeSubpath()
        return p
    }
}
