import SwiftUI

/// Shared preflight status for every local transcription runtime.
struct ModelReadinessView: View {
    let state: ModelPreparationState
    let modelName: String
    let retry: () -> Void

    var body: some View {
        if !state.isReady {
            HStack(alignment: .top, spacing: MuesliTheme.spacing12) {
                if state.isPreparing {
                    ProgressView().tint(MuesliTheme.accent)
                } else {
                    Image(systemName: state.phase == .failed ? "exclamationmark.circle" : "cpu")
                        .foregroundStyle(MuesliTheme.accent)
                }
                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    Text(title).font(MuesliTheme.headline())
                    Text(message)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                    if state.isPreparing {
                        Text("Recording will be available automatically when setup finishes.")
                            .font(MuesliTheme.caption())
                            .foregroundStyle(MuesliTheme.textTertiary)
                        if let progress = state.progress {
                            ProgressView(value: progress)
                                .tint(MuesliTheme.accent)
                            if state.phase == .downloading {
                                Text(progress, format: .percent.precision(.fractionLength(0)))
                                    .font(MuesliTheme.captionMedium())
                            }
                        }
                    }
                    if state.phase == .failed {
                        Button("Retry Model Setup", action: retry)
                            .frame(minHeight: 44)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(MuesliTheme.spacing12)
            .background(MuesliTheme.accentSubtle)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .accessibilityIdentifier("model.readinessStatus")
        }
    }

    private var message: String {
        switch state.phase {
        case .idle: "Choose a model in Settings. Setup starts automatically."
        case .failed: state.detail
        case .downloading, .preparing:
            state.detail.isEmpty || state.detail == modelName ? state.status : state.detail
        case .ready: "Ready to record"
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
