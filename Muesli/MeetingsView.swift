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
            .navigationDestination(for: UUID.self) { sessionID in
                if let session = coordinator.recordingSessions.first(where: { $0.id == sessionID }) {
                    MeetingSessionDetailView(
                        session: session,
                        transcript: coordinator.transcript(for: session),
                        onTranscribe: { coordinator.transcribeSession(session) },
                        onCopy: { text, tab in
                            coordinator.copyText(
                                text,
                                telemetryName: "meeting_\(tab.telemetryName)_copied"
                            )
                        }
                    )
                } else {
                    MeetingMissingDetailView()
                }
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
                        NavigationLink(value: session.id) {
                            MeetingSessionRow(
                                session: session,
                                transcript: coordinator.transcript(for: session)
                            )
                        }
                        .buttonStyle(.plain)
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
                        if session.hasRetainedAudio {
                            Label("Audio saved", systemImage: "waveform.path.ecg.rectangle")
                                .font(MuesliTheme.caption())
                                .foregroundStyle(MuesliTheme.textTertiary)
                        }
                        if let transcript, transcript.diarizationState == .completed {
                            Label("Speakers separated", systemImage: "person.2.wave.2")
                                .font(MuesliTheme.caption())
                                .foregroundStyle(MuesliTheme.textTertiary)
                        }
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .frame(width: 32, height: 32)
                }

                Text(previewText)
                    .font(MuesliTheme.body())
                    .foregroundStyle(previewColor)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(MuesliTheme.spacing16)
        }
    }

    private var previewText: String {
        if let summary = transcript?.summaryText?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            return summary.replacingOccurrences(of: "\n", with: " ")
        }
        if let speakerTranscript = transcript?.speakerTranscript?.trimmingCharacters(in: .whitespacesAndNewlines), !speakerTranscript.isEmpty {
            return speakerTranscript.replacingOccurrences(of: "\n", with: " ")
        }
        if let text = transcript?.text.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return text
        }
        if let error = session.errorMessage, !error.isEmpty {
            return error
        }
        return session.phase.description
    }

    private var previewColor: Color {
        session.errorMessage == nil ? MuesliTheme.textSecondary : MuesliTheme.recording
    }

    fileprivate static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private struct MeetingSessionDetailView: View {
    let session: RecordingSession
    let transcript: Transcript?
    let onTranscribe: () -> Void
    let onCopy: (String, MeetingContentTab) -> Void
    @State private var selectedContent: MeetingContentTab = .notes

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing20) {
                detailHeader
                detailActions
                contentSection
            }
            .padding(.horizontal, MuesliTheme.spacing20)
            .padding(.top, MuesliTheme.spacing16)
            .padding(.bottom, MuesliTheme.spacing24)
        }
        .background(MuesliTheme.backgroundBase)
        .navigationTitle("Meeting")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var detailHeader: some View {
        MuesliSurface(cornerRadius: MuesliTheme.cornerLarge) {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                HStack(alignment: .top, spacing: MuesliTheme.spacing12) {
                    Image(systemName: "person.2.wave.2")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(session.phase.tint)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                        Text(session.title ?? session.kind.title)
                            .font(MuesliTheme.title3())
                            .foregroundStyle(MuesliTheme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(session.createdAt, formatter: MeetingSessionRow.dateFormatter)
                            .font(MuesliTheme.captionMedium())
                            .foregroundStyle(MuesliTheme.textSecondary)
                    }

                    Spacer()

                    Text(session.phase.title)
                        .font(MuesliTheme.captionMedium())
                        .foregroundStyle(session.phase.tint)
                        .padding(.horizontal, MuesliTheme.spacing8)
                        .padding(.vertical, MuesliTheme.spacing4)
                        .background(session.phase.tint.opacity(0.12))
                        .clipShape(Capsule())
                }

                HStack(spacing: MuesliTheme.spacing8) {
                    if session.hasRetainedAudio {
                        detailBadge("Audio saved", systemImage: "waveform.path.ecg.rectangle")
                    }
                    if transcript?.diarizationState == .completed {
                        detailBadge("Diarized", systemImage: "person.2.wave.2")
                    }
                    if transcript?.summaryState == .completed {
                        detailBadge("Notes", systemImage: "sparkles")
                    }
                }
            }
            .padding(MuesliTheme.spacing16)
        }
    }

    @ViewBuilder
    private var detailActions: some View {
        if session.phase == .transcriptionQueued {
            Button(action: onTranscribe) {
                Label("Transcribe Meeting", systemImage: "waveform.badge.magnifyingglass")
                    .font(MuesliTheme.headline())
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(MuesliTheme.accent)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        } else if let transcript {
            Button {
                onCopy(copyText(for: transcript), resolvedContent(for: transcript))
            } label: {
                Label("Copy \(resolvedContent(for: transcript).copyLabel)", systemImage: "doc.on.doc")
                    .font(MuesliTheme.headline())
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(MuesliTheme.accent)
            .background(MuesliTheme.accentSubtle)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        }
    }

    @ViewBuilder
    private var contentSection: some View {
        MuesliSurface(cornerRadius: MuesliTheme.cornerLarge) {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                Text("Meeting Note")
                    .font(MuesliTheme.title3())
                    .foregroundStyle(MuesliTheme.textPrimary)

                if let transcript {
                    MeetingTranscriptContent(
                        transcript: transcript,
                        selectedContent: $selectedContent
                    )
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

    private func detailBadge(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(MuesliTheme.captionMedium())
            .foregroundStyle(MuesliTheme.textSecondary)
            .padding(.horizontal, MuesliTheme.spacing8)
            .padding(.vertical, MuesliTheme.spacing4)
            .background(MuesliTheme.surfacePrimary)
            .clipShape(Capsule())
    }

    private func resolvedContent(for transcript: Transcript) -> MeetingContentTab {
        transcript.availableMeetingTabs.contains(selectedContent)
            ? selectedContent
            : (transcript.availableMeetingTabs.first ?? .raw)
    }

    private func copyText(for transcript: Transcript) -> String {
        transcript.text(for: resolvedContent(for: transcript))
    }
}

private struct MeetingMissingDetailView: View {
    var body: some View {
        VStack(spacing: MuesliTheme.spacing12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(MuesliTheme.transcribing)
            Text("Meeting not found")
                .font(MuesliTheme.headline())
                .foregroundStyle(MuesliTheme.textPrimary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MuesliTheme.backgroundBase)
    }
}

private enum MeetingContentTab: String, CaseIterable {
    case notes = "Notes"
    case speakers = "Speakers"
    case raw = "Raw"

    var copyLabel: String {
        switch self {
        case .notes:
            "Notes"
        case .speakers:
            "Speaker Transcript"
        case .raw:
            "Raw Transcript"
        }
    }

    var telemetryName: String {
        switch self {
        case .notes:
            "notes"
        case .speakers:
            "speaker_transcript"
        case .raw:
            "raw_transcript"
        }
    }
}

private struct MeetingTranscriptContent: View {
    let transcript: Transcript
    @Binding var selectedContent: MeetingContentTab

    private var availableTabs: [MeetingContentTab] {
        transcript.availableMeetingTabs
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            if availableTabs.count > 1 {
                HStack(spacing: MuesliTheme.spacing4) {
                    ForEach(availableTabs, id: \.self) { tab in
                        Button {
                            selectedContent = tab
                        } label: {
                            Text(tab.rawValue)
                                .font(MuesliTheme.captionMedium())
                                .foregroundStyle(selectedContent == tab ? MuesliTheme.accent : MuesliTheme.textSecondary)
                                .frame(maxWidth: .infinity)
                                .frame(height: 32)
                                .background(selectedContent == tab ? MuesliTheme.surfaceSelected : Color.clear)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
                .background(MuesliTheme.surfacePrimary)
                .clipShape(Capsule())
            }

            switch resolvedSelection {
            case .notes:
                MarkdownLikeText(text: transcript.summaryText ?? "")
            case .speakers:
                SpeakerTranscriptView(text: transcript.speakerTranscript ?? "")
            case .raw:
                Text(transcript.text.isEmpty ? "No speech detected." : transcript.text)
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = statusError {
                Text(error)
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            if !availableTabs.contains(selectedContent) {
                selectedContent = availableTabs.first ?? .raw
            }
        }
    }

    private var resolvedSelection: MeetingContentTab {
        availableTabs.contains(selectedContent) ? selectedContent : (availableTabs.first ?? .raw)
    }

    private var statusError: String? {
        if transcript.summaryState == .failed, let message = transcript.summaryErrorMessage {
            return "Summary failed: \(message)"
        }
        if transcript.diarizationState == .failed, let message = transcript.diarizationErrorMessage {
            return "Diarization failed: \(message)"
        }
        return nil
    }
}

private extension Transcript {
    var availableMeetingTabs: [MeetingContentTab] {
        MeetingContentTab.allCases.filter { tab in
            switch tab {
            case .notes:
                return !(summaryText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            case .speakers:
                return !(speakerTranscript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            case .raw:
                return true
            }
        }
    }

    func text(for tab: MeetingContentTab) -> String {
        switch tab {
        case .notes:
            return summaryText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? text
        case .speakers:
            return speakerTranscript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? text
        case .raw:
            return text
        }
    }
}

private struct SpeakerTranscriptView: View {
    let text: String

    private var turns: [SpeakerTurn] {
        text.components(separatedBy: .newlines).compactMap(SpeakerTurn.init(line:))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            if turns.isEmpty {
                Text(text)
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(turns) { turn in
                    VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                        HStack(spacing: MuesliTheme.spacing4) {
                            Text(turn.speaker)
                                .font(MuesliTheme.captionMedium())
                                .foregroundStyle(MuesliTheme.accent)
                            Text(turn.timestamp)
                                .font(MuesliTheme.caption())
                                .foregroundStyle(MuesliTheme.textTertiary)
                        }
                        Text(turn.text)
                            .font(MuesliTheme.body())
                            .foregroundStyle(MuesliTheme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(MuesliTheme.spacing12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(MuesliTheme.surfacePrimary)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                }
            }
        }
    }
}

private struct MarkdownLikeText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            ForEach(Array(text.components(separatedBy: .newlines).enumerated()), id: \.offset) { _, line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("## ") {
                    Text(String(trimmed.dropFirst(3)))
                        .font(MuesliTheme.headline())
                        .foregroundStyle(MuesliTheme.textPrimary)
                        .padding(.top, MuesliTheme.spacing4)
                } else if trimmed.hasPrefix("- ") {
                    Text(trimmed)
                        .font(MuesliTheme.body())
                        .foregroundStyle(MuesliTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if trimmed.isEmpty {
                    EmptyView()
                } else {
                    Text(trimmed)
                        .font(MuesliTheme.body())
                        .foregroundStyle(MuesliTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct SpeakerTurn: Identifiable {
    let id = UUID()
    let timestamp: String
    let speaker: String
    let text: String

    init?(line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["),
              let closeBracket = trimmed.firstIndex(of: "]"),
              let colon = trimmed[trimmed.index(after: closeBracket)...].firstIndex(of: ":") else {
            return nil
        }
        timestamp = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closeBracket])
        speaker = String(trimmed[trimmed.index(closeBracket, offsetBy: 2)..<colon])
        text = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
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

private extension RecordingSession {
    var hasRetainedAudio: Bool {
        phase == .completed && keepsAudioRecording && audioFileName != nil
    }
}
