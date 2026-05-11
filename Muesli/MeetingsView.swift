import SwiftUI

struct MeetingsView: View {
    @Bindable var coordinator: DictationCoordinator
    @State private var meetingTitle = ""

    private var meetingSessions: [RecordingSession] {
        coordinator.recordingSessions.filter { $0.kind == .meeting }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing20) {
                    header
                    recorderPanel
                    sessionsSection
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
            Text("Meetings")
                .font(MuesliTheme.title1())
                .foregroundStyle(MuesliTheme.textPrimary)
            Text("Record offline conversations and transcribe them locally when you are ready.")
                .font(MuesliTheme.callout())
                .foregroundStyle(MuesliTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var recorderPanel: some View {
        MuesliSurface(cornerRadius: MuesliTheme.cornerLarge) {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
                HStack(alignment: .top, spacing: MuesliTheme.spacing12) {
                    VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                        Text("Meeting Recorder")
                            .font(MuesliTheme.title3())
                            .foregroundStyle(MuesliTheme.textPrimary)
                        Text(coordinator.meetingStatusText)
                            .font(MuesliTheme.callout())
                            .foregroundStyle(statusColor)
                    }

                    Spacer()

                    Image(systemName: coordinator.isMeetingRecording ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(statusColor)
                }

                TextField("Meeting title", text: $meetingTitle)
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textPrimary)
                    .padding(.horizontal, MuesliTheme.spacing12)
                    .frame(height: 44)
                    .background(MuesliTheme.surfacePrimary)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                    .disabled(coordinator.isMeetingRecording || coordinator.isMeetingTranscribing)

                if coordinator.isMeetingRecording || coordinator.isMeetingTranscribing {
                    VStack(spacing: MuesliTheme.spacing8) {
                        MuesliWaveformView(
                            isActive: coordinator.isMeetingRecording,
                            color: statusColor,
                            level: coordinator.isMeetingRecording ? coordinator.inputLevel : nil,
                            barCount: 13,
                            spacing: 4
                        )
                        .frame(width: 132, height: 42)

                        Text(coordinator.isMeetingRecording ? "Recording" : "Transcribing")
                            .font(MuesliTheme.captionMedium())
                            .foregroundStyle(MuesliTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, MuesliTheme.spacing16)
                    .background(statusColor.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                }

                Button {
                    if coordinator.isMeetingRecording {
                        coordinator.stopMeetingRecording(queueForTranscription: true)
                    } else {
                        coordinator.startMeetingRecording(title: meetingTitle)
                    }
                } label: {
                    Label(
                        coordinator.isMeetingRecording ? "Stop and Queue" : "Start Meeting",
                        systemImage: coordinator.isMeetingRecording ? "stop.fill" : "mic.fill"
                    )
                    .font(MuesliTheme.headline())
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(statusColor)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                .disabled(coordinator.isMeetingTranscribing)
            }
            .padding(MuesliTheme.spacing16)
        }
    }

    @ViewBuilder
    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    Text("Meeting Sessions")
                        .font(MuesliTheme.title3())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text("\(meetingSessions.count) saved")
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

            if meetingSessions.isEmpty {
                emptyState
            } else {
                LazyVStack(spacing: MuesliTheme.spacing12) {
                    ForEach(meetingSessions) { session in
                        MeetingSessionRow(
                            session: session,
                            transcript: coordinator.transcript(for: session),
                            onTranscribe: { coordinator.transcribeSession(session) },
                            onCopy: { transcript in coordinator.copyTranscript(transcript) }
                        )
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        MuesliSurface {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                Image(systemName: "person.2.wave.2")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(MuesliTheme.accent)

                Text("No meetings yet")
                    .font(MuesliTheme.headline())
                    .foregroundStyle(MuesliTheme.textPrimary)

                Text("Recorded meetings stay on this iPhone and can be transcribed later with the local model.")
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(MuesliTheme.spacing16)
        }
    }

    private var statusColor: Color {
        if coordinator.isMeetingRecording {
            MuesliTheme.recording
        } else if coordinator.isMeetingTranscribing {
            MuesliTheme.transcribing
        } else {
            MuesliTheme.accent
        }
    }
}

private struct MeetingSessionRow: View {
    let session: RecordingSession
    let transcript: Transcript?
    let onTranscribe: () -> Void
    let onCopy: (Transcript) -> Void

    var body: some View {
        MuesliSurface {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                HStack(alignment: .top, spacing: MuesliTheme.spacing12) {
                    VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                        Text(session.title ?? session.kind.title)
                            .font(MuesliTheme.headline())
                            .foregroundStyle(MuesliTheme.textPrimary)
                        Text(session.createdAt, formatter: Self.dateFormatter)
                            .font(MuesliTheme.captionMedium())
                            .foregroundStyle(MuesliTheme.textSecondary)
                        Text(session.phase.title)
                            .font(MuesliTheme.caption())
                            .foregroundStyle(session.phase.tint)
                    }

                    Spacer()

                    if session.phase == .transcriptionQueued {
                        Button(action: onTranscribe) {
                            Label("Transcribe", systemImage: "waveform.badge.magnifyingglass")
                                .labelStyle(.iconOnly)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(MuesliTheme.accent)
                                .frame(width: 44, height: 44)
                                .background(MuesliTheme.accentSubtle)
                                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                        }
                        .buttonStyle(.plain)
                    } else if let transcript {
                        Button {
                            onCopy(transcript)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(MuesliTheme.accent)
                                .frame(width: 44, height: 44)
                                .background(MuesliTheme.accentSubtle)
                                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                        }
                        .buttonStyle(.plain)
                    }
                }

                if let transcript {
                    Text(transcript.text.isEmpty ? "No speech detected." : transcript.text)
                        .font(MuesliTheme.body())
                        .foregroundStyle(MuesliTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let error = session.errorMessage {
                    Text(error)
                        .font(MuesliTheme.body())
                        .foregroundStyle(MuesliTheme.recording)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(session.phase.description)
                        .font(MuesliTheme.body())
                        .foregroundStyle(MuesliTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(MuesliTheme.spacing16)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private extension RecordingSessionPhase {
    var title: String {
        switch self {
        case .recording:
            "Recording"
        case .transcriptionQueued:
            "Queued"
        case .transcribing:
            "Transcribing"
        case .completed:
            "Completed"
        case .failed:
            "Failed"
        case .cancelled:
            "Cancelled"
        }
    }

    var description: String {
        switch self {
        case .recording:
            "Recording is still active."
        case .transcriptionQueued:
            "Audio is saved locally and ready for delayed transcription."
        case .transcribing:
            "Muesli is transcribing this recording locally."
        case .completed:
            "Transcript saved."
        case .failed:
            "Transcription failed."
        case .cancelled:
            "Recording was cancelled."
        }
    }

    var tint: Color {
        switch self {
        case .recording, .failed, .cancelled:
            MuesliTheme.recording
        case .transcriptionQueued, .transcribing:
            MuesliTheme.transcribing
        case .completed:
            MuesliTheme.success
        }
    }
}
