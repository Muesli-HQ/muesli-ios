import AVFoundation
import SwiftUI
import UIKit

struct MeetingsView: View {
    @Bindable var coordinator: DictationCoordinator
    var isActive = true
    @State private var meetingTitle = ""
    @State private var sessionPendingDelete: RecordingSession?
    @State private var navigationPath: [UUID] = []
    @State private var searchText = ""
    @State private var selectedSourceFilter: MeetingSourceFilter = .all
    @State private var selectedStatusFilter: MeetingStatusFilter = .all
    @State private var selectedSort: MeetingSortOrder = .newest
    @State private var isSyncSetupPromptPresented = false
    @AppStorage(MuesliPreferences.iCloudSyncEnabledKey) private var iCloudSyncEnabled = false
    @AppStorage(MuesliPreferences.meetingTemplateKey) private var selectedMeetingTemplate = MeetingTemplatePreset.general.rawValue

    private var meetingTemplate: MeetingTemplatePreset {
        MeetingTemplatePreset(rawValue: selectedMeetingTemplate) ?? .general
    }

    private var meetingBrowserState: MeetingBrowserState {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var totalCount = 0
        var filteredItems: [MeetingBrowserItem] = []
        filteredItems.reserveCapacity(coordinator.recordingSessions.count)

        for session in coordinator.recordingSessions where session.kind == .meeting {
            totalCount += 1
            guard selectedSourceFilter.includes(session),
                  selectedStatusFilter.includes(session) else {
                continue
            }

            let item = MeetingBrowserItem(
                session: session,
                transcript: coordinator.transcript(for: session)
            )

            guard query.isEmpty || item.containsSearchQuery(query) else {
                continue
            }

            filteredItems.append(item)
        }

        filteredItems.sort { lhs, rhs in
            switch selectedSort {
            case .newest:
                lhs.session.createdAt > rhs.session.createdAt
            case .oldest:
                lhs.session.createdAt < rhs.session.createdAt
            }
        }

        return MeetingBrowserState(totalCount: totalCount, filteredItems: filteredItems)
    }

    private func browserResultSummary(_ state: MeetingBrowserState) -> String {
        guard state.totalCount > 0 else { return "No saved meetings" }
        if state.filteredItems.count == state.totalCount {
            return "\(state.totalCount) saved"
        }
        return "\(state.filteredItems.count) of \(state.totalCount)"
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ScrollView {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing20) {
                    header
                    startMeetingPanel
                    sessionsSection
                }
                .padding(.horizontal, MuesliTheme.spacing20)
                .padding(.top, MuesliTheme.spacing24)
                .padding(.bottom, 112)
            }
            .background(MuesliTheme.backgroundBase)
            .toolbar(.hidden, for: .navigationBar)
            .confirmationDialog(
                "Turn on private iCloud sync?",
                isPresented: $isSyncSetupPromptPresented,
                titleVisibility: .visible
            ) {
                Button("Open Sync Setup") {
                    coordinator.requestSyncSetup(source: "meetings_sync")
                }
                Button("Not Now", role: .cancel) {
                    coordinator.iCloudSyncStatusText = nil
                }
            } message: {
                Text("Muesli will sync meeting transcripts, notes, and summaries with your Mac through your private iCloud account. Audio stays local.")
            }
            .onAppear {
                refreshVisibleStateIfNeeded()
            }
            .onChange(of: isActive) { _, active in
                guard active else { return }
                refreshVisibleStateIfNeeded()
            }
            .navigationDestination(for: UUID.self) { sessionID in
                if let session = coordinator.meetingSession(id: sessionID) {
                    MeetingSessionDetailView(
                        session: session,
                        transcript: coordinator.transcript(for: session),
                        audioURL: coordinator.audioFileURL(for: session),
                        isActiveRecording: coordinator.isActivelyRecordingMeeting(sessionID: session.id),
                        canStopRecording: coordinator.canStopMeetingCapture(sessionID: session.id),
                        isRecoveryNeeded: coordinator.meetingNeedsRecovery(sessionID: session.id),
                        isProcessingCurrentMeeting: session.phase == .transcribing,
                        inputLevel: coordinator.inputLevel,
                        statusText: coordinator.activeMeetingSessionID == session.id ? coordinator.effectiveMeetingStatusText : session.phase.title,
                        actionStatusText: coordinator.clipboardStatusText,
                        onTranscribe: { coordinator.transcribeSession(session) },
                        onStopRecording: { coordinator.stopCurrentMeetingRecording() },
                        onDiscardRecording: {
                            coordinator.cancelCurrentMeetingRecording()
                            navigationPath.removeAll { $0 == session.id }
                        },
                        onCopy: { text, tab in
                            coordinator.copyText(
                                text,
                                telemetryName: "meeting_\(tab.telemetryName)_copied"
                            )
                        },
                        onDelete: {
                            coordinator.deleteMeeting(session)
                        },
                        onDeleteAudio: {
                            coordinator.deleteMeetingAudio(for: session)
                        },
                        onRename: { title in
                            coordinator.updateMeetingTitle(sessionID: session.id, title: title)
                        },
                        onManualNotesChange: { notes in
                            coordinator.updateMeetingManualNotes(sessionID: session.id, notes: notes)
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
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            HStack(spacing: MuesliTheme.spacing8) {
                Image("MuesliAppIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 26, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text("muesli")
                    .font(MuesliTheme.headline())
                    .foregroundStyle(MuesliTheme.textPrimary)
            }

            VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                Text("Meetings")
                    .font(.system(.largeTitle, design: .default, weight: .bold))
                    .foregroundStyle(MuesliTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.86)

                Text("Record, write, review.")
                    .font(MuesliTheme.callout())
                    .foregroundStyle(MuesliTheme.textSecondary)
            }
        }
    }

    private var startMeetingPanel: some View {
        MeetingPanel(tint: statusColor, isProminent: coordinator.hasMeetingRecordingInProgress) {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                HStack(alignment: .center, spacing: MuesliTheme.spacing12) {
                    MeetingIconTile(systemImage: coordinator.hasMeetingRecordingInProgress ? "waveform" : "mic.fill", tint: statusColor, size: 34)

                    Text(
                        coordinator.isMeetingRecoveryNeeded
                            ? "Meeting needs recovery"
                            : (coordinator.isMeetingTranscribing
                                ? "Meeting processing"
                                : (coordinator.isMeetingCaptureVisible ? "Live meeting" : "Start a new meeting"))
                    )
                        .font(MuesliTheme.headline())
                        .foregroundStyle(coordinator.hasMeetingRecordingInProgress ? statusColor : MuesliTheme.accent)

                    Spacer(minLength: MuesliTheme.spacing8)
                }

                if coordinator.hasMeetingRecordingInProgress {
                    Button {
                        if let sessionID = coordinator.activeMeetingSessionID {
                            openMeeting(sessionID)
                        }
                    } label: {
                        Label("Return to Meeting", systemImage: "arrow.up.forward.square")
                            .font(MuesliTheme.headline())
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .foregroundStyle(.white)
                            .background(statusColor)
                            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                            .contentShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                    }
                    .buttonStyle(.plain)
                    .disabled(coordinator.activeMeetingSessionID == nil)
                } else {
                    TextField("Meeting title", text: $meetingTitle)
                        .font(MuesliTheme.body())
                        .foregroundStyle(MuesliTheme.textPrimary)
                        .padding(.horizontal, MuesliTheme.spacing12)
                        .frame(height: 44)
                        .meetingInputSurface()
                        .disabled(coordinator.isMeetingTranscribing)

                    meetingTemplatePicker

                    Button {
                        if let sessionID = coordinator.startMeetingRecording(title: meetingTitle) {
                            openMeeting(sessionID)
                            meetingTitle = ""
                        }
                    } label: {
                        Label(
                            "Start Meeting",
                            systemImage: "mic.fill"
                        )
                        .font(MuesliTheme.headline())
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .foregroundStyle(meetingPrimaryButtonTextColor)
                        .background(meetingPrimaryButtonBackground)
                        .overlay(meetingPrimaryButtonBorder)
                        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                        .contentShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                    }
                    .buttonStyle(.plain)
                    .disabled(isPrimaryMeetingActionDisabled)
                    .sensoryFeedback(.impact, trigger: coordinator.hasMeetingRecordingInProgress)
                    .accessibilityIdentifier("meetings.primaryButton")
                }
            }
            .padding(MuesliTheme.spacing16)
        }
        .accessibilityIdentifier("meetings.startMeetingPanel")
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
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(MuesliTheme.accent)
                    .frame(width: 20)

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
            .meetingInputSurface(tint: MuesliTheme.accent)
            .contentShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(coordinator.hasMeetingRecordingInProgress || coordinator.isMeetingTranscribing)
    }

    @ViewBuilder
    private var sessionsSection: some View {
        let browserState = meetingBrowserState
        let browserItems = browserState.filteredItems

        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    Text("Recent Meetings")
                        .font(MuesliTheme.title3())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text(browserResultSummary(browserState))
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                }

                Spacer()

                ICloudSyncStatusButton(
                    isEnabled: iCloudSyncEnabled,
                    isSyncing: coordinator.isICloudSyncInProgress,
                    hasError: syncStatusIsError,
                    action: triggerMeetingSync
                )

                if let status = coordinator.clipboardStatusText {
                    MeetingActionStatusLabel(statusText: status)
                }
            }

            if browserState.totalCount > 0 {
                MeetingSourceFilterPicker(selection: $selectedSourceFilter)
            }

            browserControls

            if browserState.totalCount == 0 {
                emptyState
            } else if browserItems.isEmpty {
                emptySearchState
            } else {
                LazyVStack(spacing: MuesliTheme.spacing12) {
                    ForEach(browserItems) { item in
                        MuesliSwipeActionRow(
                            leadingAction: .init(
                                title: "Delete",
                                systemImage: "trash",
                                tint: MuesliTheme.destructive,
                                perform: { sessionPendingDelete = item.session }
                            ),
                            trailingAction: .init(
                                title: "Copy",
                                systemImage: "doc.on.doc",
                                tint: MuesliTheme.success,
                                perform: {
                                    coordinator.copyText(
                                        item.copyText,
                                        telemetryName: "meeting_row_copied"
                                    )
                                }
                            )
                        ) {
                            NavigationLink(value: item.session.id) {
                                MeetingSessionRow(
                                    session: item.session,
                                    transcript: item.transcript
                                )
                            }
                            .buttonStyle(.plain)
                            .contentShape(Rectangle())
                        }
                    }
                }
            }
        }
    }

    private var browserControls: some View {
        HStack(spacing: MuesliTheme.spacing8) {
            HStack(spacing: MuesliTheme.spacing8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(MuesliTheme.textTertiary)
                TextField("Search meetings", text: $searchText)
                    .font(MuesliTheme.body())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .foregroundStyle(MuesliTheme.textPrimary)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(MuesliTheme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear meeting search")
                }
            }
            .padding(.horizontal, MuesliTheme.spacing12)
            .frame(height: 44)
            .background(MuesliTheme.backgroundRaised.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium, style: .continuous)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
            )

            Menu {
                ForEach(MeetingStatusFilter.allCases) { filter in
                    Button {
                        selectedStatusFilter = filter
                    } label: {
                        Label(filter.label, systemImage: selectedStatusFilter == filter ? "checkmark" : filter.systemImage)
                    }
                }

                Divider()

                ForEach(MeetingSortOrder.allCases) { sort in
                    Button {
                        selectedSort = sort
                    } label: {
                        Label(sort.label, systemImage: selectedSort == sort ? "checkmark" : sort.systemImage)
                    }
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(MuesliTheme.textPrimary)
                    .frame(width: 44, height: 44)
                    .background(MuesliTheme.backgroundRaised.opacity(0.72))
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Filter and sort meetings")
        }
    }

    private func refreshVisibleStateIfNeeded() {
        guard isActive else { return }
        coordinator.refreshHistory()
    }

    private var syncStatusIsError: Bool {
        coordinator.iCloudSyncStatusText?.localizedCaseInsensitiveContains("sync failed") == true
    }

    private func triggerMeetingSync() {
        if !iCloudSyncEnabled {
            coordinator.iCloudSyncStatusText = nil
            isSyncSetupPromptPresented = true
            return
        }
        coordinator.syncICloudTextIfEnabled(reason: "meetings_manual")
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

    private var emptySearchState: some View {
        MuesliSurface {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(MuesliTheme.textTertiary)
                Text("No matches")
                    .font(MuesliTheme.headline())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Text("Adjust the search, source, or filter to find another meeting.")
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(MuesliTheme.spacing16)
        }
    }

    private var statusColor: Color {
        if coordinator.isMeetingCaptureVisible {
            MuesliTheme.recording
        } else if coordinator.isMeetingTranscribing {
            MuesliTheme.transcribing
        } else {
            MuesliTheme.accent
        }
    }

    private var meetingPrimaryButtonTextColor: Color {
        .white
    }

    private var meetingPrimaryButtonBackground: some View {
        RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall, style: .continuous)
            .fill(coordinator.hasMeetingRecordingInProgress ? MuesliTheme.destructive : statusColor)
    }

    private var meetingPrimaryButtonBorder: some View {
        RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall, style: .continuous)
            .strokeBorder(.clear, lineWidth: 1)
    }

    private var isPrimaryMeetingActionDisabled: Bool {
        coordinator.isMeetingTranscribing
    }

    private func openMeeting(_ sessionID: UUID) {
        guard navigationPath.last != sessionID else { return }
        navigationPath.append(sessionID)
    }

}

private struct MeetingBrowserItem: Identifiable {
    let session: RecordingSession
    let transcript: Transcript?
    let copyText: String

    var id: UUID { session.id }

    init(session: RecordingSession, transcript: Transcript?) {
        self.session = session
        self.transcript = transcript
        copyText = Self.preferredCopyText(for: session, transcript: transcript)
    }

    func containsSearchQuery(_ query: String) -> Bool {
        [
            session.title ?? "",
            session.phase.title,
            session.sourceDisplayName,
            session.manualNotes ?? "",
            transcript?.summaryText ?? "",
            transcript?.speakerTranscript ?? "",
            transcript?.text ?? "",
            session.errorMessage ?? ""
        ]
        .joined(separator: " ")
        .lowercased()
        .contains(query)
    }

    private static func preferredCopyText(for session: RecordingSession, transcript: Transcript?) -> String {
        if let summary = transcript?.summaryText?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            return summary
        }
        if let manualNotes = session.manualNotes?.trimmingCharacters(in: .whitespacesAndNewlines), !manualNotes.isEmpty {
            return manualNotes
        }
        if let speakerTranscript = transcript?.speakerTranscript?.trimmingCharacters(in: .whitespacesAndNewlines), !speakerTranscript.isEmpty {
            return speakerTranscript
        }
        if let text = transcript?.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        return session.errorMessage ?? session.phase.description
    }
}

private struct MeetingBrowserState {
    let totalCount: Int
    let filteredItems: [MeetingBrowserItem]
}

private struct MeetingActionStatusLabel: View {
    let statusText: String

    private var isFailure: Bool {
        statusText.localizedCaseInsensitiveContains("failed")
    }

    var body: some View {
        Label(statusText, systemImage: isFailure ? "exclamationmark.triangle.fill" : "checkmark")
            .font(MuesliTheme.captionMedium())
            .foregroundStyle(isFailure ? MuesliTheme.destructive : MuesliTheme.success)
    }
}

private enum MeetingSourceFilter: String, CaseIterable, Identifiable {
    case all
    case thisIPhone
    case fromMac

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            "All"
        case .thisIPhone:
            "This iPhone"
        case .fromMac:
            "From Mac"
        }
    }

    func includes(_ session: RecordingSession) -> Bool {
        switch self {
        case .all:
            true
        case .thisIPhone:
            session.isFromThisIPhone
        case .fromMac:
            session.isFromMac
        }
    }
}

private enum MeetingStatusFilter: String, CaseIterable, Identifiable {
    case all
    case processing
    case needsAttention

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all:
            "All Statuses"
        case .processing:
            "Processing"
        case .needsAttention:
            "Needs Review"
        }
    }

    var systemImage: String {
        switch self {
        case .all:
            "tray.full"
        case .processing:
            "waveform.badge.magnifyingglass"
        case .needsAttention:
            "exclamationmark.triangle"
        }
    }

    func includes(_ session: RecordingSession) -> Bool {
        switch self {
        case .all:
            true
        case .processing:
            session.phase == .recording || session.phase == .transcriptionQueued || session.phase == .transcribing
        case .needsAttention:
            session.phase == .failed || session.phase == .cancelled
        }
    }
}

private struct MeetingSourceFilterPicker: View {
    @Binding var selection: MeetingSourceFilter

    var body: some View {
        HStack(spacing: MuesliTheme.spacing4) {
            ForEach(MeetingSourceFilter.allCases) { filter in
                Button {
                    withAnimation(.snappy(duration: 0.18)) {
                        selection = filter
                    }
                } label: {
                    Text(filter.title)
                        .font(MuesliTheme.captionMedium())
                        .foregroundStyle(selection == filter ? MuesliTheme.textPrimary : MuesliTheme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(selection == filter ? MuesliTheme.accent.opacity(0.13) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall, style: .continuous))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .contentShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show \(filter.title.lowercased()) meetings")
            }
        }
        .padding(3)
        .muesliGlassSurface(cornerRadius: MuesliTheme.cornerMedium, tint: MuesliTheme.accent)
    }
}

private enum MeetingSortOrder: String, CaseIterable, Identifiable {
    case newest
    case oldest

    var id: String { rawValue }

    var label: String {
        switch self {
        case .newest:
            "Newest"
        case .oldest:
            "Oldest"
        }
    }

    var systemImage: String {
        switch self {
        case .newest:
            "arrow.down"
        case .oldest:
            "arrow.up"
        }
    }
}

private struct MeetingRowBadge: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(MuesliTheme.captionMedium())
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, MuesliTheme.spacing8)
            .frame(height: 26)
            .background(tint.opacity(0.10))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(tint.opacity(0.20), lineWidth: 1)
            )
    }
}

private struct MeetingPanel<Content: View>: View {
    var tint: Color? = nil
    var isProminent = false
    @ViewBuilder var content: Content

    init(
        tint: Color? = nil,
        isProminent: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.tint = tint
        self.isProminent = isProminent
        self.content = content()
    }

    var body: some View {
        content
            .background {
                RoundedRectangle(cornerRadius: MuesliTheme.cornerLarge, style: .continuous)
                    .fill(panelFill)
            }
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerLarge, style: .continuous)
                    .strokeBorder(panelBorder, lineWidth: 1)
            )
            .shadow(color: MuesliTheme.glassShadow.opacity(isProminent ? 0.9 : 0.45), radius: isProminent ? 14 : 8, x: 0, y: isProminent ? 8 : 4)
    }

    private var panelFill: Color {
        isProminent
            ? MuesliTheme.backgroundRaised.opacity(0.84)
            : MuesliTheme.backgroundRaised.opacity(0.64)
    }

    private var panelBorder: Color {
        isProminent
            ? (tint ?? MuesliTheme.accent).opacity(0.38)
            : MuesliTheme.surfaceBorder
    }
}

private struct MeetingIconTile: View {
    let systemImage: String
    var tint: Color = MuesliTheme.accent
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: max(14, size * 0.42), weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.09))
            .clipShape(RoundedRectangle(cornerRadius: min(10, size * 0.26), style: .continuous))
    }
}

private struct MeetingInputSurfaceModifier: ViewModifier {
    var tint: Color? = nil

    func body(content: Content) -> some View {
        content
            .background(MuesliTheme.backgroundDeep.opacity(0.58))
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium, style: .continuous)
                    .strokeBorder((tint ?? MuesliTheme.surfaceBorder).opacity(tint == nil ? 1 : 0.24), lineWidth: 1)
            )
    }
}

private extension View {
    func meetingInputSurface(tint: Color? = nil) -> some View {
        modifier(MeetingInputSurfaceModifier(tint: tint))
    }
}

private struct MeetingSessionRow: View {
    let session: RecordingSession
    let transcript: Transcript?

    var body: some View {
        MeetingPanel(tint: session.phase.tint) {
            HStack(alignment: .center, spacing: MuesliTheme.spacing12) {
                Image(systemName: "person.2.wave.2")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(MuesliTheme.accent)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    Text(session.title ?? session.kind.title)
                        .font(MuesliTheme.headline())
                        .foregroundStyle(MuesliTheme.textPrimary)
                        .lineLimit(1)
                    Text(rowSubtitle)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                        .lineLimit(1)
                    Text(previewText)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(previewColor)
                        .lineLimit(1)
                }

                Spacer(minLength: MuesliTheme.spacing8)

                Text(session.phase.compactTitle)
                    .font(MuesliTheme.captionMedium())
                    .foregroundStyle(session.phase.tint)
                    .lineLimit(1)
                    .padding(.horizontal, MuesliTheme.spacing8)
                    .frame(height: 26)
                    .background(session.phase.tint.opacity(0.12))
                    .clipShape(Capsule())

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MuesliTheme.textTertiary)
            }
            .padding(.horizontal, MuesliTheme.spacing16)
            .padding(.vertical, MuesliTheme.spacing12)
        }
    }

    private var rowSubtitle: String {
        "\(session.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(session.sourceDisplayName)"
    }

    private var previewText: String {
        if session.phase == .recording {
            return "In progress"
        }
        if session.phase == .transcribing {
            return "Creating transcript and notes"
        }
        if let summary = transcript?.summaryText?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            return summary.replacingOccurrences(of: "\n", with: " ")
        }
        if let manualNotes = session.manualNotes?.trimmingCharacters(in: .whitespacesAndNewlines), !manualNotes.isEmpty {
            return manualNotes.replacingOccurrences(of: "\n", with: " ")
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
        session.errorMessage == nil ? MuesliTheme.textSecondary : MuesliTheme.destructive
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
    let isActiveRecording: Bool
    let canStopRecording: Bool
    let isRecoveryNeeded: Bool
    let isProcessingCurrentMeeting: Bool
    let inputLevel: Double
    let statusText: String
    let actionStatusText: String?
    let onTranscribe: () -> Void
    let onStopRecording: () -> Void
    let onDiscardRecording: () -> Void
    let onCopy: (String, MeetingContentTab) -> Void
    let onDelete: () -> Bool
    let onDeleteAudio: () -> Bool
    let onRename: (String) -> Void
    let onManualNotesChange: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedContent: MeetingContentTab = .notes
    @State private var sharePayload: MeetingSharePayload?
    @State private var isConfirmingDelete = false
    @State private var isConfirmingAudioDelete = false
    @State private var isConfirmingDiscardRecording = false
    @State private var editedTitle: String?
    @State private var titleDraft = ""
    @State private var isEditingTitle = false
    @State private var manualNotesDraft = ""
    @State private var manualNotesSaveState: ManualNotesSaveState = .saved
    @State private var manualNotesSaveTask: Task<Void, Never>?
    @State private var isLeavingAfterDestructiveAction = false
    @State private var recordingPulse = false
    @State private var isEditingCompletedManualNotes = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing20) {
                detailHeader
                if let actionStatusText {
                    MeetingActionStatusLabel(statusText: actionStatusText)
                }
                if isCompletedMeeting {
                    contentSection
                    transcriptActionsSection
                    manualNotesSection
                    retainedAudioSection
                    deleteActionSection
                } else {
                    captureStatusSection
                    manualNotesSection
                    contentSection
                    retainedAudioSection
                    detailActions
                }
            }
            .padding(.horizontal, MuesliTheme.spacing20)
            .padding(.top, MuesliTheme.spacing16)
            .padding(.bottom, 112)
        }
        .background(MuesliTheme.backgroundBase)
        .navigationTitle("Meeting")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $sharePayload) { payload in
            MeetingShareSheet(items: payload.items)
        }
        .alert("Edit Meeting Title", isPresented: $isEditingTitle) {
            TextField("Meeting title", text: $titleDraft)
            Button("Save") {
                let title = resolvedTitle(titleDraft)
                editedTitle = title
                onRename(title)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This updates the saved meeting title without changing the transcript or notes.")
        }
        .confirmationDialog(
            "Delete this meeting?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Meeting", role: .destructive) {
                isLeavingAfterDestructiveAction = true
                manualNotesSaveTask?.cancel()
                if onDelete() {
                    dismiss()
                } else {
                    isLeavingAfterDestructiveAction = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the meeting, transcript, notes, and any retained audio from local history.")
        }
        .confirmationDialog(
            "Delete retained audio?",
            isPresented: $isConfirmingAudioDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Audio", role: .destructive) {
                _ = onDeleteAudio()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the saved meeting audio file. The transcript, summary, and manual notes stay in place.")
        }
        .confirmationDialog(
            "Discard this meeting recording?",
            isPresented: $isConfirmingDiscardRecording,
            titleVisibility: .visible
        ) {
            Button("Discard Recording", role: .destructive) {
                isLeavingAfterDestructiveAction = true
                manualNotesSaveTask?.cancel()
                onDiscardRecording()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the in-progress audio recording and meeting notes from local history.")
        }
        .onAppear {
            manualNotesDraft = session.manualNotes ?? ""
        }
        .onChange(of: session.manualNotes ?? "") { _, newValue in
            guard manualNotesSaveState != .saving else { return }
            manualNotesDraft = newValue
        }
        .onChange(of: session.phase) { _, phase in
            if phase == .completed, hasMeetingSummary {
                selectedContent = .notes
            }
        }
        .onChange(of: hasMeetingSummary) { hadSummary, hasSummary in
            if !hadSummary, hasSummary, session.phase == .completed {
                selectedContent = .notes
            }
        }
        .onDisappear {
            guard !isLeavingAfterDestructiveAction else { return }
            flushPendingManualNotes()
        }
    }

    private var detailHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                MeetingIconTile(systemImage: "person.2.wave.2", tint: session.phase.tint, size: 30)

                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    Text(displayTitle)
                        .font(MuesliTheme.title3())
                        .foregroundStyle(MuesliTheme.textPrimary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.86)

                    HStack(spacing: 6) {
                        Circle()
                            .fill(session.phase.tint)
                            .frame(width: 6, height: 6)
                        Text(detailStatusLine)
                            .font(MuesliTheme.captionMedium())
                            .foregroundStyle(session.phase == .completed ? MuesliTheme.success : session.phase.tint)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: MuesliTheme.spacing8)

                Button {
                    titleDraft = displayTitle
                    isEditingTitle = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(MuesliTheme.accent)
                        .frame(width: 38, height: 38)
                        .background(MuesliTheme.surfacePrimary.opacity(0.74))
                        .clipShape(Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit meeting title")
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: MuesliTheme.spacing8) {
                    detailBadge(session.sourceDisplayName, systemImage: session.sourceSystemImage)
                    if shouldShowPostMeetingArtifacts, session.hasRetainedAudio {
                        detailBadge("Audio", systemImage: "waveform.path.ecg.rectangle")
                    }
                    if transcript?.diarizationState == .completed {
                        detailBadge("Speakers", systemImage: "person.2.wave.2")
                    }
                    if transcript?.summaryState == .completed {
                        detailBadge("Notes", systemImage: "sparkles")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var captureStatusSection: some View {
        if canStopRecording || isProcessingCurrentMeeting {
            MeetingPanel(tint: captureTint, isProminent: isActiveRecording) {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
                    HStack(alignment: .center, spacing: MuesliTheme.spacing12) {
                        Circle()
                            .fill(captureTint)
                            .frame(width: 8, height: 8)
                            .opacity(isActiveRecording ? (recordingPulse ? 0.95 : 0.32) : 0.55)
                            .animation(
                                isActiveRecording
                                    ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                                    : .default,
                                value: recordingPulse
                            )
                            .onAppear {
                                recordingPulse = isActiveRecording
                            }
                            .onChange(of: isActiveRecording) { _, isRecording in
                                recordingPulse = isRecording
                            }

                        VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                            Text(captureStatusTitle)
                                .font(MuesliTheme.headline())
                                .foregroundStyle(MuesliTheme.textPrimary)
                            Text(captureStatusCopy)
                                .font(MuesliTheme.captionMedium())
                                .foregroundStyle(MuesliTheme.textSecondary)
                        }

                        Spacer()

                        if canStopRecording {
                            Button(role: .destructive) {
                                isConfirmingDiscardRecording = true
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(MuesliTheme.destructive)
                                    .frame(width: 38, height: 38)
                                    .background(MuesliTheme.destructive.opacity(0.10))
                                    .clipShape(Circle())
                                    .overlay(
                                        Circle()
                                            .strokeBorder(MuesliTheme.destructive.opacity(0.26), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Discard meeting")
                            .accessibilityIdentifier("meetingDetail.discardButton")
                        }
                    }

                    if !isRecoveryNeeded {
                        MuesliInlineWaveformView(
                            mode: isActiveRecording ? .level : .waiting,
                            color: captureTint,
                            level: isActiveRecording ? inputLevel : nil,
                            isActive: isActiveRecording || isProcessingCurrentMeeting,
                            barCount: 34
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: 58)
                        .padding(.horizontal, MuesliTheme.spacing12)
                        .padding(.vertical, MuesliTheme.spacing12)
                        .background(MuesliTheme.backgroundRaised.opacity(0.52))
                        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium, style: .continuous)
                                .strokeBorder(captureTint.opacity(0.18), lineWidth: 1)
                        )
                    }

                    if canStopRecording {
                        Button {
                            flushPendingManualNotes()
                            onStopRecording()
                        } label: {
                            Label(isRecoveryNeeded ? "Stop & Recover" : "Stop Meeting", systemImage: "stop.fill")
                                .font(MuesliTheme.headline())
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                                .background(MuesliTheme.destructive.opacity(0.88))
                                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                                .contentShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("meetingDetail.stopButton")
                    }
                }
                .padding(MuesliTheme.spacing16)
            }
        }
    }

    @ViewBuilder
    private var manualNotesSection: some View {
        MeetingPanel(tint: canEditManualNotes ? MuesliTheme.accent : nil, isProminent: canEditManualNotes && !isCompletedMeeting) {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                HStack(alignment: .center, spacing: MuesliTheme.spacing12) {
                    MeetingIconTile(systemImage: "square.and.pencil", tint: MuesliTheme.accent, size: 34)

                    Text("Manual Notes")
                        .font(MuesliTheme.title3())
                        .foregroundStyle(MuesliTheme.textPrimary)

                    Spacer()

                    manualNotesHeaderAccessory
                }

                manualNotesBody
            }
            .padding(MuesliTheme.spacing16)
        }
    }

    @ViewBuilder
    private var manualNotesHeaderAccessory: some View {
        if isCompletedMeeting {
            Button {
                if isEditingCompletedManualNotes {
                    flushPendingManualNotes()
                }
                isEditingCompletedManualNotes.toggle()
            } label: {
                Text(isEditingCompletedManualNotes ? "Done" : "Edit")
                    .font(MuesliTheme.captionMedium())
                    .foregroundStyle(MuesliTheme.accent)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(MuesliTheme.accentSubtle)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isEditingCompletedManualNotes ? "Finish editing manual notes" : "Edit manual notes")
        } else if canEditManualNotes {
            Text(manualNotesSaveState.label)
                .font(MuesliTheme.captionMedium())
                .foregroundStyle(manualNotesSaveState.tint)
                .padding(.horizontal, MuesliTheme.spacing8)
                .frame(height: 26)
                .background(manualNotesSaveState.tint.opacity(0.10))
                .clipShape(Capsule())
        }
    }

    @ViewBuilder
    private var manualNotesBody: some View {
        if canEditManualNotes {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $manualNotesDraft)
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: session.phase == .recording ? 220 : 140)
                    .padding(MuesliTheme.spacing8)
                    .accessibilityLabel("Meeting manual notes")
                    .onChange(of: manualNotesDraft) { _, _ in
                        scheduleManualNotesSave()
                    }

                if manualNotesDraft.isEmpty {
                    Text("Start typing meeting notes...")
                        .font(MuesliTheme.body())
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .padding(.horizontal, MuesliTheme.spacing12)
                        .padding(.vertical, MuesliTheme.spacing16)
                        .allowsHitTesting(false)
                }
            }
            .background(MuesliTheme.backgroundRaised.opacity(0.62))
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium, style: .continuous)
                    .strokeBorder(MuesliTheme.accent.opacity(0.18), lineWidth: 1)
            )
        } else {
            Text(manualNotesDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No manual notes." : manualNotesDraft)
                .font(MuesliTheme.body())
                .foregroundStyle(manualNotesDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? MuesliTheme.textTertiary : MuesliTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(MuesliTheme.spacing16)
                .background(MuesliTheme.backgroundRaised.opacity(0.48))
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium, style: .continuous)
                        .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                )
        }
    }

    @ViewBuilder
    private var retainedAudioSection: some View {
        if shouldShowPostMeetingArtifacts, session.hasRetainedAudio, let audioURL {
            MeetingPanel {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                    HStack(alignment: .top, spacing: MuesliTheme.spacing12) {
                        MeetingIconTile(systemImage: "waveform.path.ecg.rectangle", tint: MuesliTheme.accent, size: 34)

                        VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                            Text("Audio")
                                .font(MuesliTheme.headline())
                                .foregroundStyle(MuesliTheme.textPrimary)
                            Text("Playback and export")
                                .font(MuesliTheme.captionMedium())
                                .foregroundStyle(MuesliTheme.textSecondary)
                            Text(audioURL.lastPathComponent)
                                .font(MuesliTheme.caption())
                                .foregroundStyle(MuesliTheme.textTertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        Spacer()
                    }

                    SavedAudioPlayerView(audioURL: audioURL)

                    HStack(spacing: MuesliTheme.spacing8) {
                        Button {
                            sharePayload = MeetingSharePayload(items: [audioURL])
                            AppTelemetry.signal("meeting_audio_shared")
                        } label: {
                            Label("Export Audio", systemImage: "square.and.arrow.up")
                                .font(MuesliTheme.headline())
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                                .foregroundStyle(MuesliTheme.accent)
                                .background(MuesliTheme.accentSubtle)
                                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                                .contentShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                        }
                        .buttonStyle(.plain)

                        Button(role: .destructive) {
                            isConfirmingAudioDelete = true
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(MuesliTheme.destructive)
                                .frame(width: 48, height: 44)
                                .background(MuesliTheme.destructive.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                                .contentShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Delete meeting audio")
                    }
                }
                .padding(MuesliTheme.spacing16)
            }
        }
    }

    @ViewBuilder
    private var detailActions: some View {
        if canStopRecording || isProcessingCurrentMeeting {
            EmptyView()
        } else if session.phase == .transcriptionQueued {
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
        } else {
            transcriptActionsSection
        }

        deleteActionSection
    }

    @ViewBuilder
    private var transcriptActionsSection: some View {
        if shouldShowPostMeetingArtifacts, let transcript {
            MeetingPanel {
                HStack(spacing: MuesliTheme.spacing8) {
                    Button {
                        onCopy(copyText(for: transcript), resolvedContent(for: transcript))
                    } label: {
                        Label("Copy Text", systemImage: "doc.on.doc")
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
                .padding(MuesliTheme.spacing8)
            }
        }
    }

    @ViewBuilder
    private var deleteActionSection: some View {
        if !canStopRecording && !isProcessingCurrentMeeting {
            Button {
                isConfirmingDelete = true
            } label: {
                Label("Delete Meeting", systemImage: "trash")
                .font(MuesliTheme.headline())
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .foregroundStyle(MuesliTheme.destructive)
                .background(MuesliTheme.destructive.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                .contentShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var contentSection: some View {
        MeetingPanel(tint: isCompletedMeeting ? MuesliTheme.syncGreen : nil) {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                HStack(spacing: 10) {
                    if isCompletedMeeting {
                        Image(systemName: "sparkles")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(MuesliTheme.syncGreen)
                    } else {
                        Circle()
                            .fill(captureTint)
                            .frame(width: 7, height: 7)
                    }
                    Text(contentSectionTitle)
                        .font(MuesliTheme.title3())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Spacer()
                }

                if let transcript {
                    MeetingTranscriptContent(
                        transcript: transcript,
                        selectedContent: $selectedContent
                    )
                } else if let error = session.errorMessage {
                    Text(error)
                        .font(MuesliTheme.body())
                        .foregroundStyle(MuesliTheme.destructive)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(contentPlaceholder)
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
            .lineLimit(1)
            .padding(.horizontal, MuesliTheme.spacing8)
            .padding(.vertical, MuesliTheme.spacing4)
            .background(MuesliTheme.surfacePrimary)
            .clipShape(Capsule())
    }

    private var captureTint: Color {
        isActiveRecording ? MuesliTheme.recording : MuesliTheme.transcribing
    }

    private var captureStatusTitle: String {
        if isActiveRecording {
            return "Listening"
        }
        if isRecoveryNeeded {
            return "Recording interrupted"
        }
        if canStopRecording {
            return "Preparing microphone"
        }
        return "Processing audio"
    }

    private var detailStatusLine: String {
        "\(session.phase.headerTitle) · \(session.createdAt.formatted(date: .abbreviated, time: .shortened))"
    }

    private var captureStatusCopy: String {
        if isActiveRecording {
            return "Audio is being captured locally"
        }
        if isRecoveryNeeded || canStopRecording {
            return statusText
        }
        if isProcessingCurrentMeeting {
            return "Creating transcript and notes"
        }
        return statusText
    }

    private var shouldShowPostMeetingArtifacts: Bool {
        !canStopRecording && !isProcessingCurrentMeeting && session.phase != .recording && session.phase != .transcribing
    }

    private var isCompletedMeeting: Bool {
        session.phase == .completed
    }

    private var hasMeetingSummary: Bool {
        !(transcript?.summaryText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    private var canEditManualNotes: Bool {
        canStopRecording
            || isProcessingCurrentMeeting
            || session.phase == .transcriptionQueued
            || isEditingCompletedManualNotes
    }

    private var contentSectionTitle: String {
        if transcript?.summaryText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return "Generated Notes"
        }
        if canStopRecording || isProcessingCurrentMeeting || transcript != nil {
            return "Live Transcript"
        }
        return "Meeting Notes"
    }

    private var contentPlaceholder: String {
        if canStopRecording {
            return "Transcript and generated notes will appear after the meeting is processed."
        }
        if isProcessingCurrentMeeting {
            return "Creating transcript and notes."
        }
        return session.phase.description
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
            items: [MeetingExportFormatter.text(
                for: kind,
                session: session,
                transcript: transcript,
                titleOverride: displayTitle
            )]
        )
        AppTelemetry.signal("meeting_\(kind.telemetryName)_shared")
    }

    private func scheduleManualNotesSave() {
        manualNotesSaveTask?.cancel()
        guard manualNotesDraft != (session.manualNotes ?? "") else {
            manualNotesSaveState = .saved
            manualNotesSaveTask = nil
            return
        }
        manualNotesSaveState = .saving
        let draft = manualNotesDraft
        manualNotesSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard !Task.isCancelled else { return }
            onManualNotesChange(draft)
            manualNotesSaveState = .saved
            manualNotesSaveTask = nil
        }
    }

    private func flushPendingManualNotes() {
        manualNotesSaveTask?.cancel()
        persistManualNotesIfChanged()
    }

    private func persistManualNotesIfChanged() {
        guard manualNotesDraft != (session.manualNotes ?? "") else { return }
        onManualNotesChange(manualNotesDraft)
        manualNotesSaveState = .saved
    }

    private var displayTitle: String {
        resolvedTitle(editedTitle ?? session.title ?? session.kind.title)
    }

    private func resolvedTitle(_ title: String) -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitle.isEmpty ? session.kind.title : trimmedTitle
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

private enum ManualNotesSaveState {
    case saved
    case saving

    var label: String {
        switch self {
        case .saved:
            "Saved"
        case .saving:
            "Saving"
        }
    }

    var tint: Color {
        switch self {
        case .saved:
            MuesliTheme.success
        case .saving:
            MuesliTheme.textTertiary
        }
    }
}

private enum MeetingExportFormatter {
    static func text(
        for kind: MeetingShareKind,
        session: RecordingSession,
        transcript: Transcript,
        titleOverride: String? = nil
    ) -> String {
        switch kind {
        case .notes:
            notes(session: session, transcript: transcript, titleOverride: titleOverride)
        case .transcript:
            transcriptText(session: session, transcript: transcript, titleOverride: titleOverride)
        case .full:
            fullMeeting(session: session, transcript: transcript, titleOverride: titleOverride)
        }
    }

    private static func notes(session: RecordingSession, transcript: Transcript, titleOverride: String?) -> String {
        let generatedNotes = transcript.summaryText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let writtenNotes = session.manualNotes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let body: String
        if !generatedNotes.isEmpty, !writtenNotes.isEmpty {
            body = """
            \(generatedNotes)

            ## Written Notes
            \(writtenNotes)
            """
        } else if !generatedNotes.isEmpty {
            body = generatedNotes
        } else if !writtenNotes.isEmpty {
            body = writtenNotes
        } else {
            body = "No meeting notes available."
        }

        return """
        # \(titleOverride ?? title(for: session))

        \(dateString(for: session))

        \(body)
        """
    }

    private static func transcriptText(session: RecordingSession, transcript: Transcript, titleOverride: String?) -> String {
        let body = transcript.speakerTranscript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? transcript.speakerTranscript!
            : transcript.text
        return """
        # \(titleOverride ?? title(for: session)) Transcript

        \(dateString(for: session))

        \(body.trimmingCharacters(in: .whitespacesAndNewlines))
        """
    }

    private static func fullMeeting(session: RecordingSession, transcript: Transcript, titleOverride: String?) -> String {
        let notes = transcript.summaryText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let manualNotes = session.manualNotes?.trimmingCharacters(in: .whitespacesAndNewlines)
        let speakers = transcript.speakerTranscript?.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        # \(titleOverride ?? title(for: session))

        \(dateString(for: session))

        ## Notes
        \(notes?.isEmpty == false ? notes! : "None available.")

        ## Written Notes
        \(manualNotes?.isEmpty == false ? manualNotes! : "None available.")

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

private extension RecordingSession {
    var isFromMac: Bool {
        syncOrigin == .fromMac
    }

    var isFromThisIPhone: Bool {
        !isFromMac
    }

    var sourceDisplayName: String {
        isFromMac ? "From Mac" : "This iPhone"
    }

    var sourceSystemImage: String {
        isFromMac ? "desktopcomputer" : "iphone"
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

struct SavedAudioPlayerView: View {
    let audioURL: URL

    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var currentTime: TimeInterval = 0
    @State private var duration: TimeInterval = 0
    @State private var samples: [CGFloat] = AudioWaveformSampler.placeholderSamples(count: waveformSampleCount)
    @State private var playbackError: String?

    private static let waveformSampleCount = 72
    private let timer = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: MuesliTheme.spacing12) {
            waveform
                .frame(height: 54)
                .padding(.horizontal, MuesliTheme.spacing12)
                .padding(.vertical, MuesliTheme.spacing12)
                .background(MuesliTheme.accent.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                .contentShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))

            HStack(spacing: MuesliTheme.spacing12) {
                Button(action: togglePlayback) {
                    Label(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill")
                        .font(MuesliTheme.headline())
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .foregroundStyle(.white)
                        .background(MuesliTheme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                        .contentShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                }
                .buttonStyle(.plain)

                Button(action: stopPlayback) {
                    Label("Stop", systemImage: "stop.fill")
                        .font(MuesliTheme.headline())
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .foregroundStyle(MuesliTheme.textPrimary)
                        .background(MuesliTheme.surfacePrimary)
                        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                        .contentShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                }
                .buttonStyle(.plain)
                .disabled(currentTime == 0 && !isPlaying)
                .opacity(currentTime == 0 && !isPlaying ? 0.55 : 1)
            }

            HStack {
                Text(formatTime(currentTime))
                Spacer()
                Text(formatTime(duration))
            }
            .font(MuesliTheme.captionMedium())
            .foregroundStyle(MuesliTheme.textTertiary)

            if let playbackError {
                Text(playbackError)
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.destructive)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: audioURL) {
            samples = await AudioWaveformSampler.samples(from: audioURL, count: Self.waveformSampleCount)
            preparePlayer()
        }
        .onAppear {
            if player == nil {
                preparePlayer()
            }
        }
        .onReceive(timer) { _ in
            guard let player else { return }
            currentTime = player.currentTime
            if !player.isPlaying, isPlaying {
                isPlaying = false
                if currentTime >= max(duration - 0.2, 0) {
                    resetPlayback()
                }
            }
        }
        .onDisappear {
            resetPlayback()
            player = nil
        }
    }

    private var waveform: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = 2
            let barWidth = max(1.2, (geometry.size.width - spacing * CGFloat(samples.count - 1)) / CGFloat(samples.count))
            let progress = duration > 0 ? min(max(currentTime / duration, 0), 1) : 0

            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(samples.enumerated()), id: \.offset) { index, sample in
                    let isPlayed = Double(index) / Double(max(samples.count - 1, 1)) <= progress
                    RoundedRectangle(cornerRadius: barWidth / 2, style: .continuous)
                        .fill(isPlayed ? MuesliTheme.accent : MuesliTheme.accent.opacity(0.32))
                        .frame(
                            width: barWidth,
                            height: max(4, geometry.size.height * sample)
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        seek(toProgress: value.location.x, width: geometry.size.width)
                    }
            )
            .accessibilityLabel("Audio waveform")
            .accessibilityValue("\(formatTime(currentTime)) of \(formatTime(duration))")
        }
    }

    private func preparePlayer() {
        do {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers])
            let player = try AVAudioPlayer(contentsOf: audioURL)
            player.prepareToPlay()
            self.player = player
            duration = player.duration
            currentTime = 0
            isPlaying = false
            playbackError = nil
        } catch {
            self.player = nil
            duration = 0
            currentTime = 0
            isPlaying = false
            playbackError = "Audio playback is unavailable for this recording."
        }
    }

    private func togglePlayback() {
        if player == nil {
            preparePlayer()
        }
        guard let player else { return }

        if player.isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if currentTime >= max(duration - 0.2, 0) {
                player.currentTime = 0
                currentTime = 0
            }
            player.play()
            isPlaying = true
        }
    }

    private func stopPlayback() {
        guard let player else { return }
        player.stop()
        player.currentTime = 0
        currentTime = 0
        isPlaying = false
    }

    private func resetPlayback() {
        player?.stop()
        player?.currentTime = 0
        currentTime = 0
        isPlaying = false
    }

    private func seek(to time: TimeInterval) {
        guard let player, duration > 0 else { return }
        let clamped = min(max(time, 0), duration)
        player.currentTime = clamped
        currentTime = clamped
    }

    private func seek(toProgress xPosition: CGFloat, width: CGFloat) {
        guard duration > 0 else { return }
        let progress = min(max(xPosition / max(width, 1), 0), 1)
        seek(to: TimeInterval(progress) * duration)
    }

    private func formatTime(_ time: TimeInterval) -> String {
        guard time.isFinite, time > 0 else { return "0:00" }
        let totalSeconds = Int(time.rounded())
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

struct SavedAudioWaveformView: View {
    let audioURL: URL
    @State private var samples: [CGFloat] = AudioWaveformSampler.placeholderSamples(count: waveformSampleCount)

    private static let waveformSampleCount = 72

    var body: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = 2
            let barWidth = max(1.2, (geometry.size.width - spacing * CGFloat(samples.count - 1)) / CGFloat(samples.count))
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
            samples = await AudioWaveformSampler.samples(from: audioURL, count: Self.waveformSampleCount)
        }
    }
}

enum AudioWaveformSampler {
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

    var compactTitle: String {
        switch self {
        case .recording:
            "Live"
        case .transcriptionQueued:
            "Saved"
        case .transcribing:
            "Processing"
        case .completed:
            "Complete"
        case .failed:
            "Failed"
        case .cancelled:
            "Cancelled"
        }
    }

    var headerTitle: String {
        switch self {
        case .recording:
            "Live"
        case .transcriptionQueued:
            "Saved"
        case .transcribing:
            "Processing"
        case .completed:
            "Completed"
        case .failed:
            "Needs review"
        case .cancelled:
            "Cancelled"
        }
    }

    var description: String {
        switch self {
        case .recording:
            "In progress."
        case .transcriptionQueued:
            "Audio is saved locally and ready for delayed transcription."
        case .transcribing:
            "Creating transcript and notes."
        case .completed:
            "Transcript saved."
        case .failed:
            "Transcription failed."
        case .cancelled:
            "Recording was cancelled."
        }
    }

    var systemImage: String {
        switch self {
        case .recording:
            "mic.fill"
        case .transcriptionQueued:
            "clock"
        case .transcribing:
            "waveform.badge.magnifyingglass"
        case .completed:
            "checkmark"
        case .failed:
            "exclamationmark.triangle"
        case .cancelled:
            "xmark"
        }
    }

    var tint: Color {
        switch self {
        case .recording:
            MuesliTheme.recording
        case .failed, .cancelled:
            MuesliTheme.destructive
        case .transcriptionQueued, .transcribing:
            MuesliTheme.transcribing
        case .completed:
            MuesliTheme.success
        }
    }
}

private extension RecordingSession {
    var hasRetainedAudio: Bool {
        kind == .meeting && keepsAudioRecording && audioFileName != nil
    }
}
