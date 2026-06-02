import AVFoundation
import SwiftUI
import UIKit

struct MeetingsView: View {
    @Bindable var coordinator: DictationCoordinator
    @State private var meetingTitle = ""
    @State private var sessionPendingDelete: RecordingSession?
    @AppStorage(MuesliPreferences.meetingTemplateKey) private var selectedMeetingTemplate = MeetingTemplatePreset.general.rawValue

    private var meetingSessions: [RecordingSession] {
        coordinator.recordingSessions.filter { $0.kind == .meeting }
    }

    private var meetingTemplate: MeetingTemplatePreset {
        MeetingTemplatePreset(rawValue: selectedMeetingTemplate) ?? .general
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
                        audioURL: coordinator.audioFileURL(for: session),
                        onTranscribe: { coordinator.transcribeSession(session) },
                        onCopy: { text, tab in
                            coordinator.copyText(
                                text,
                                telemetryName: "meeting_\(tab.telemetryName)_copied"
                            )
                        },
                        onDelete: {
                            coordinator.deleteMeeting(session)
                        }
                    )
                } else {
                    MeetingMissingDetailView()
                }
            }
            .confirmationDialog(
                "Delete this meeting?",
                isPresented: Binding(
                    get: { sessionPendingDelete != nil },
                    set: { if !$0 { sessionPendingDelete = nil } }
                ),
                titleVisibility: .visible,
                presenting: sessionPendingDelete
            ) { session in
                Button("Delete Meeting", role: .destructive) {
                    coordinator.deleteMeeting(session)
                    sessionPendingDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    sessionPendingDelete = nil
                }
            } message: { _ in
                Text("This removes the meeting, transcript, notes, and any retained audio from local history.")
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

                meetingTemplatePicker

                if coordinator.isMeetingRecording || coordinator.isMeetingTranscribing {
                    VStack(spacing: MuesliTheme.spacing8) {
                        MuesliInlineWaveformView(
                            mode: coordinator.isMeetingRecording ? .level : .waiting,
                            color: statusColor,
                            level: coordinator.isMeetingRecording ? coordinator.inputLevel : nil,
                            barCount: 24
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .padding(.horizontal, MuesliTheme.spacing16)

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
                    .foregroundStyle(.white)
                    .background(statusColor)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                    .contentShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                }
                .buttonStyle(.plain)
                .disabled(coordinator.isMeetingTranscribing)
            }
            .padding(MuesliTheme.spacing16)
        }
    }

    private var meetingTemplatePicker: some View {
        Menu {
            ForEach(MeetingTemplatePreset.allCases) { template in
                Button {
                    selectedMeetingTemplate = template.rawValue
                    AppTelemetry.signal("meeting_template_selected", parameters: [
                        "template": template.rawValue
                    ])
                } label: {
                    Label(template.label, systemImage: selectedMeetingTemplate == template.rawValue ? "checkmark" : "doc.text")
                }
            }
        } label: {
            HStack(spacing: MuesliTheme.spacing12) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(MuesliTheme.accent)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    Text(meetingTemplate.label)
                        .font(MuesliTheme.headline())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text(meetingTemplate.detail)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MuesliTheme.textTertiary)
            }
            .padding(MuesliTheme.spacing12)
            .background(MuesliTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .contentShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        }
        .buttonStyle(.plain)
        .disabled(coordinator.isMeetingRecording || coordinator.isMeetingTranscribing)
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
                        ZStack(alignment: .topTrailing) {
                            NavigationLink(value: session.id) {
                                MeetingSessionRow(
                                    session: session,
                                    transcript: coordinator.transcript(for: session)
                                )
                                .padding(.trailing, 44)
                            }
                            .buttonStyle(.plain)
                            .contentShape(Rectangle())

                            Button {
                                sessionPendingDelete = session
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 8, weight: .semibold))
                                    .frame(width: 36, height: 36)
                                    .foregroundStyle(MuesliTheme.recording)
                                    .background(MuesliTheme.recording.opacity(0.12))
                                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                                    .contentShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                            }
                            .buttonStyle(.plain)
                            .padding(.top, MuesliTheme.spacing16)
                            .padding(.trailing, MuesliTheme.spacing16)
                            .accessibilityLabel("Delete meeting")
                        }
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
    let audioURL: URL?
    let onTranscribe: () -> Void
    let onCopy: (String, MeetingContentTab) -> Void
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedContent: MeetingContentTab = .notes
    @State private var sharePayload: MeetingSharePayload?
    @State private var isConfirmingDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing20) {
                detailHeader
                retainedAudioSection
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
        .sheet(item: $sharePayload) { payload in
            MeetingShareSheet(items: payload.items)
        }
        .confirmationDialog(
            "Delete this meeting?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Meeting", role: .destructive) {
                onDelete()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the meeting, transcript, notes, and any retained audio from local history.")
        }
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
    private var retainedAudioSection: some View {
        if session.hasRetainedAudio, let audioURL {
            MuesliSurface(cornerRadius: MuesliTheme.cornerLarge) {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                    HStack(alignment: .top, spacing: MuesliTheme.spacing12) {
                        Image(systemName: "waveform.path.ecg.rectangle")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(MuesliTheme.accent)
                            .frame(width: 28)

                        VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                            Text("Saved Audio")
                                .font(MuesliTheme.headline())
                                .foregroundStyle(MuesliTheme.textPrimary)
                            Text(audioURL.lastPathComponent)
                                .font(MuesliTheme.caption())
                                .foregroundStyle(MuesliTheme.textTertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        Spacer()
                    }

                    SavedAudioWaveformView(audioURL: audioURL)
                        .frame(height: 52)
                        .padding(.horizontal, MuesliTheme.spacing12)
                        .padding(.vertical, MuesliTheme.spacing12)
                        .background(MuesliTheme.accent.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))

                    Button {
                        sharePayload = MeetingSharePayload(items: [audioURL])
                        AppTelemetry.signal("meeting_audio_shared")
                    } label: {
                        Label("Save Audio to Files", systemImage: "folder.badge.plus")
                            .font(MuesliTheme.headline())
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .foregroundStyle(MuesliTheme.accent)
                            .background(MuesliTheme.accentSubtle)
                            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                            .contentShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                    }
                    .buttonStyle(.plain)
                }
                .padding(MuesliTheme.spacing16)
            }
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
                    .foregroundStyle(.white)
                    .background(MuesliTheme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                    .contentShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            }
            .buttonStyle(.plain)
        } else if let transcript {
            VStack(spacing: MuesliTheme.spacing8) {
                Button {
                    onCopy(copyText(for: transcript), resolvedContent(for: transcript))
                } label: {
                    Label("Copy \(resolvedContent(for: transcript).copyLabel)", systemImage: "doc.on.doc")
                        .font(MuesliTheme.headline())
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .foregroundStyle(MuesliTheme.accent)
                        .background(MuesliTheme.accentSubtle)
                        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                        .contentShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                }
                .buttonStyle(.plain)

                Menu {
                    ForEach(MeetingShareKind.available(for: transcript)) { kind in
                        Button {
                            share(kind, transcript: transcript)
                        } label: {
                            Label(kind.label, systemImage: kind.systemImage)
                        }
                    }
                } label: {
                    Label("Share Meeting", systemImage: "square.and.arrow.up")
                        .font(MuesliTheme.headline())
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .foregroundStyle(MuesliTheme.accent)
                        .background(MuesliTheme.surfacePrimary)
                        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                        .contentShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                }
                .buttonStyle(.plain)
            }
        }

        Button {
            isConfirmingDelete = true
        } label: {
            Label("Delete Meeting", systemImage: "trash")
            .font(MuesliTheme.headline())
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .foregroundStyle(MuesliTheme.recording)
            .background(MuesliTheme.recording.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .contentShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        }
        .buttonStyle(.plain)
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

    private func share(_ kind: MeetingShareKind, transcript: Transcript) {
        sharePayload = MeetingSharePayload(
            items: [MeetingExportFormatter.text(for: kind, session: session, transcript: transcript)]
        )
        AppTelemetry.signal("meeting_\(kind.telemetryName)_shared")
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

private enum MeetingShareKind: String, CaseIterable, Identifiable {
    case notes
    case transcript
    case full

    var id: String { rawValue }

    var label: String {
        switch self {
        case .notes:
            "Share Notes"
        case .transcript:
            "Share Transcript"
        case .full:
            "Share Full Meeting"
        }
    }

    var systemImage: String {
        switch self {
        case .notes:
            "sparkles"
        case .transcript:
            "text.bubble"
        case .full:
            "doc.richtext"
        }
    }

    var telemetryName: String {
        switch self {
        case .notes:
            "notes"
        case .transcript:
            "transcript"
        case .full:
            "full_meeting"
        }
    }

    static func available(for transcript: Transcript) -> [MeetingShareKind] {
        allCases.filter { kind in
            switch kind {
            case .notes:
                !(transcript.summaryText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            case .transcript, .full:
                !transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
    }
}

private struct MeetingSharePayload: Identifiable {
    let id = UUID()
    let items: [Any]
}

private struct MeetingShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private enum MeetingExportFormatter {
    static func text(for kind: MeetingShareKind, session: RecordingSession, transcript: Transcript) -> String {
        switch kind {
        case .notes:
            notes(session: session, transcript: transcript)
        case .transcript:
            transcriptText(session: session, transcript: transcript)
        case .full:
            fullMeeting(session: session, transcript: transcript)
        }
    }

    private static func notes(session: RecordingSession, transcript: Transcript) -> String {
        """
        # \(title(for: session))

        \(dateString(for: session))

        \(transcript.summaryText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "No meeting notes available.")
        """
    }

    private static func transcriptText(session: RecordingSession, transcript: Transcript) -> String {
        let body = transcript.speakerTranscript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? transcript.speakerTranscript!
            : transcript.text
        return """
        # \(title(for: session)) Transcript

        \(dateString(for: session))

        \(body.trimmingCharacters(in: .whitespacesAndNewlines))
        """
    }

    private static func fullMeeting(session: RecordingSession, transcript: Transcript) -> String {
        let notes = transcript.summaryText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let speakers = transcript.speakerTranscript?.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        # \(title(for: session))

        \(dateString(for: session))

        ## Notes
        \(notes?.isEmpty == false ? notes! : "None available.")

        ## Speaker Transcript
        \(speakers?.isEmpty == false ? speakers! : "None available.")

        ## Raw Transcript
        \(transcript.text.trimmingCharacters(in: .whitespacesAndNewlines))
        """
    }

    private static func title(for session: RecordingSession) -> String {
        let title = session.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? session.kind.title : title
    }

    private static func dateString(for session: RecordingSession) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Recorded \(formatter.string(from: session.createdAt))"
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

private struct SavedAudioWaveformView: View {
    let audioURL: URL
    @State private var samples: [CGFloat] = AudioWaveformSampler.placeholderSamples(count: 36)

    var body: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = 3
            let barWidth = max(2, (geometry.size.width - spacing * CGFloat(samples.count - 1)) / CGFloat(samples.count))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                    RoundedRectangle(cornerRadius: barWidth / 2, style: .continuous)
                        .fill(MuesliTheme.accent)
                        .frame(
                            width: barWidth,
                            height: max(4, geometry.size.height * sample)
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: audioURL) {
            samples = await AudioWaveformSampler.samples(from: audioURL, count: 36)
        }
    }
}

private enum AudioWaveformSampler {
    static func placeholderSamples(count: Int) -> [CGFloat] {
        let preset: [CGFloat] = [0.24, 0.38, 0.56, 0.78, 0.62, 0.34, 0.46, 0.84, 0.70, 0.42, 0.28, 0.52]
        return (0..<count).map { preset[$0 % preset.count] }
    }

    static func samples(from url: URL, count: Int) async -> [CGFloat] {
        await Task.detached(priority: .utility) {
            guard let samples = try? makeSamples(from: url, count: count), !samples.isEmpty else {
                return placeholderSamples(count: count)
            }
            return samples
        }.value
    }

    private static func makeSamples(from url: URL, count: Int) throws -> [CGFloat] {
        let file = try AVAudioFile(forReading: url)
        let totalFrames = file.length
        guard totalFrames > 0, count > 0 else { return placeholderSamples(count: count) }

        let format = file.processingFormat
        let windowSize = AVAudioFrameCount(min(4096, max(512, totalFrames / Int64(max(count, 1)))))
        var values: [CGFloat] = []
        values.reserveCapacity(count)

        for index in 0..<count {
            let fraction = count == 1 ? 0 : Double(index) / Double(count - 1)
            let position = AVAudioFramePosition(Double(max(totalFrames - 1, 0)) * fraction)
            let framesAvailable = max(0, totalFrames - position)
            let framesToRead = AVAudioFrameCount(min(Int64(windowSize), framesAvailable))
            guard framesToRead > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesToRead) else {
                values.append(0.1)
                continue
            }

            file.framePosition = position
            try file.read(into: buffer, frameCount: framesToRead)
            values.append(averageMagnitude(in: buffer))
        }

        let peak = values.max() ?? 1
        guard peak > 0 else { return placeholderSamples(count: count) }
        return values.map { max(0.12, min(1, $0 / peak)) }
    }

    private static func averageMagnitude(in buffer: AVAudioPCMBuffer) -> CGFloat {
        guard let channelData = buffer.floatChannelData else { return 0.1 }
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        guard channelCount > 0, frameLength > 0 else { return 0.1 }

        var total: Float = 0
        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for frame in 0..<frameLength {
                total += abs(samples[frame])
            }
        }

        return CGFloat(total / Float(channelCount * frameLength))
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
