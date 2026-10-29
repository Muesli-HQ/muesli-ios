import SwiftUI

/// Shared preflight status for every local transcription runtime.
struct ModelReadinessView: View {
    let state: ModelPreparationState
    let modelName: String
    let retry: () -> Void

    var body: some View {
        if !state.isReady {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if state.isPreparing {
                        ProgressView().controlSize(.small).tint(MuesliTheme.accent)
                    } else {
                        Image(systemName: state.phase == .failed ? "exclamationmark.circle" : "cpu")
                            .foregroundStyle(MuesliTheme.accent)
                    }
                    Text(title)
                        .font(MuesliTheme.captionMedium())
                        .foregroundStyle(MuesliTheme.textSecondary)
                    Spacer(minLength: 0)
                    if state.phase == .downloading, let progress = state.progress {
                        Text(progress, format: .percent.precision(.fractionLength(0)))
                            .font(MuesliTheme.captionMedium())
                    }
                    if state.phase == .failed {
                        Button("Retry", action: retry).font(MuesliTheme.captionMedium())
                    }
                }
                if state.phase == .downloading, let progress = state.progress {
                    ProgressView(value: progress).tint(MuesliTheme.accent)
                }
                if state.phase == .failed {
                    Text(state.detail).font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textSecondary)
                }
            }
            .padding(MuesliTheme.spacing12)
            .background(MuesliTheme.accentSubtle)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .accessibilityIdentifier("model.readinessStatus")
        }
    }

    private var title: String {
        switch state.phase {
        case .preparing: "Loading \(modelName)…"
        case .downloading: "Downloading \(modelName)…"
        case .failed: "Model setup needs attention"
        case .idle: "Choose a model to record"
        case .ready: "Ready"
        }
    }
}
