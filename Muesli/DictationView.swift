import SwiftUI

struct DictationView: View {
    @Bindable var coordinator: DictationCoordinator

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing20) {
                    header
                    recorderPanel
                    historySection
                }
                .padding(.horizontal, MuesliTheme.spacing20)
                .padding(.top, MuesliTheme.spacing24)
                .padding(.bottom, MuesliTheme.spacing24)
            }
            .background(MuesliTheme.backgroundBase)
            .toolbar(.hidden, for: .navigationBar)
            .onAppear {
                coordinator.refreshHistory()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
            HStack(spacing: MuesliTheme.spacing12) {
                Image("MuesliAppIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 42, height: 42)
                Text("muesli")
                    .font(MuesliTheme.title2())
                    .foregroundStyle(MuesliTheme.textPrimary)
            }

            Text("Local-first dictation history for iOS")
                .font(MuesliTheme.callout())
                .foregroundStyle(MuesliTheme.textSecondary)
        }
    }

    private var recorderPanel: some View {
        MuesliSurface(cornerRadius: MuesliTheme.cornerLarge) {
            VStack(spacing: MuesliTheme.spacing20) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                        Text("Dictation")
                            .font(MuesliTheme.title3())
                            .foregroundStyle(MuesliTheme.textPrimary)
                        Text(coordinator.statusText)
                            .font(MuesliTheme.callout())
                            .foregroundStyle(statusColor)
                    }

                    Spacer()
                }

                if isWaveformActive {
                    VStack(spacing: MuesliTheme.spacing8) {
                        MuesliInlineWaveformView(
                            mode: coordinator.isRecording ? .level : .waiting,
                            color: statusColor,
                            level: coordinator.isRecording ? coordinator.inputLevel : nil,
                            barCount: 24
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .padding(.horizontal, MuesliTheme.spacing16)

                        Text(coordinator.isRecording ? "Listening" : "Transcribing")
                            .font(MuesliTheme.captionMedium())
                            .foregroundStyle(MuesliTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, MuesliTheme.spacing16)
                    .background(statusColor.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                }

                if shouldShowRealtimeTranscript {
                    VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                        HStack(spacing: MuesliTheme.spacing8) {
                            Image(systemName: "text.bubble")
                            Text("Live Transcript")
                        }
                        .font(MuesliTheme.captionMedium())
                        .foregroundStyle(MuesliTheme.accent)

                        Text(coordinator.liveDictationTranscript)
                            .font(MuesliTheme.body())
                            .foregroundStyle(MuesliTheme.textPrimary)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(MuesliTheme.spacing12)
                    .background(MuesliTheme.surfacePrimary)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                }

                Button {
                    coordinator.toggleRecording()
                } label: {
                    HStack(spacing: MuesliTheme.spacing8) {
                        Image(systemName: dictationButtonIcon)
                        Text(dictationButtonTitle)
                    }
                    .font(MuesliTheme.headline())
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .foregroundStyle(isDictationButtonDisabled ? MuesliTheme.textTertiary : .white)
                    .background(isDictationButtonDisabled ? MuesliTheme.surfacePrimary : statusColor)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                    .contentShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                }
                .buttonStyle(.plain)
                .disabled(isDictationButtonDisabled)
                .accessibilityIdentifier("dictation.primaryButton")
            }
            .padding()
        }
        .accessibilityIdentifier("dictation.recorderPanel")
    }

    @ViewBuilder
    private var historySection: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    Text("Recent Dictations")
                        .font(MuesliTheme.title3())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text("\(coordinator.dictationHistory.count) saved")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                }

                Spacer()

                if let status = coordinator.clipboardStatusText {
                    Label(status, systemImage: "checkmark")
                        .font(MuesliTheme.captionMedium())
                        .foregroundStyle(MuesliTheme.success)
                }
            }

            if coordinator.dictationHistory.isEmpty {
                emptyHistory
            } else {
                LazyVStack(spacing: MuesliTheme.spacing12) {
                    ForEach(coordinator.dictationHistory) { result in
                        DictationHistoryRow(
                            result: result,
                            onCopy: { coordinator.copyToClipboard(result) },
                            onDelete: { coordinator.deleteDictation(result) }
                        )
                    }
                }
            }
        }
    }

    private var emptyHistory: some View {
        MuesliSurface {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                Image(systemName: "text.badge.plus")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(MuesliTheme.accent)

                Text("No dictations yet")
                    .font(MuesliTheme.headline())
                    .foregroundStyle(MuesliTheme.textPrimary)

                Text("Recorded dictations from the app will appear here as a timeline.")
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(MuesliTheme.spacing16)
        }
    }

    private var statusColor: Color {
        if coordinator.isRecording {
            MuesliTheme.recording
        } else if coordinator.statusText == "Transcribing" {
            MuesliTheme.transcribing
        } else {
            MuesliTheme.accent
        }
    }

    private var isWaveformActive: Bool {
        coordinator.isRecording || coordinator.statusText == "Transcribing"
    }

    private var isTranscribing: Bool {
        coordinator.statusText == "Transcribing"
    }

    private var shouldShowRealtimeTranscript: Bool {
        coordinator.selectedTranscriptionModel.supportsRealtimeStreaming
            && isWaveformActive
            && !coordinator.liveDictationTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isDictationButtonDisabled: Bool {
        isTranscribing
    }

    private var dictationButtonTitle: String {
        if coordinator.isRecording {
            "Stop Recording"
        } else if isTranscribing {
            "Transcribing"
        } else {
            "Start Dictation"
        }
    }

    private var dictationButtonIcon: String {
        if coordinator.isRecording {
            "stop.fill"
        } else if isTranscribing {
            "waveform"
        } else {
            "mic.fill"
        }
    }
}

private struct DictationHistoryRow: View {
    let result: DictationResult
    let onCopy: () -> Void
    let onDelete: () -> Void
    @State private var isConfirmingDelete = false

    var body: some View {
        MuesliSwipeActionRow(
            leadingAction: .init(
                title: "Delete",
                systemImage: "trash",
                tint: MuesliTheme.recording,
                perform: { isConfirmingDelete = true }
            ),
            trailingAction: .init(
                title: "Copy",
                systemImage: "doc.on.doc",
                tint: MuesliTheme.success,
                perform: onCopy
            )
        ) {
            MuesliSurface {
                rowContent
                    .padding(MuesliTheme.spacing16)
            }
        }
        .confirmationDialog(
            "Delete this dictation?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Dictation", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the dictation from local history.")
        }
    }

    private var rowContent: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                Text(result.createdAt, formatter: Self.dateFormatter)
                    .font(MuesliTheme.captionMedium())
                    .foregroundStyle(MuesliTheme.textSecondary)
                Text(TranscriptionDisplayName.engineName(for: result.engineIdentifier))
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .lineLimit(1)
            }

            Text(result.text)
                .font(MuesliTheme.body())
                .foregroundStyle(MuesliTheme.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
