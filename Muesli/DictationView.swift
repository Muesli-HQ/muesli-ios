import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import CoreText
import UIKit
#endif

private enum DashboardCaptureMode: String, CaseIterable, Identifiable {
    case quickNote
    case notepad

    var id: Self { self }

    var title: String {
        switch self {
        case .quickNote: "Quick Note"
        case .notepad: "Notepad"
        }
    }
}

struct DictationView: View {
    @Bindable var coordinator: DictationCoordinator
    var isActive = true
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(MuesliPreferences.iCloudSyncEnabledKey) private var iCloudSyncEnabled = false
    @AppStorage(MuesliPreferences.recordingMicrophonePreferenceKey) private var microphonePreference = RecordingMicrophonePreference.automatic.rawValue
    @AppStorage(MuesliPreferences.keyboardSessionModeKey) private var keyboardSessionMode = false
    @AppStorage(MuesliPreferences.actionButtonOnboardingCompletedKey) private var actionButtonSetupCompleted = false
    @State private var sourceFilter: DictationSourceFilter = .all
    @State private var isSyncSetupPromptPresented = false
    @State private var shouldShowKeyboardSetupRow = false
    @State private var dashboardStats = DictationDashboardStats.empty
    @State private var navigationPath = NavigationPath()
    @State private var captureMode: DashboardCaptureMode = .quickNote
    @State private var isActionButtonOnboardingPresented = false

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
                    header
                    homeStatsRow
                    keyboardSessionHomeControl
                    if shouldShowActionButtonInvitation {
                        actionButtonInvitation
                    }
                    recorderPanel
                    voiceNoteHistorySection
                }
                .padding(.horizontal, MuesliTheme.spacing20)
                .padding(.top, MuesliTheme.spacing24)
                .padding(.bottom, 112)
            }
            .refreshable {
                triggerHomeSync()
            }
            .background(MuesliTheme.backgroundBase)
            .toolbar(.hidden, for: .navigationBar)
            .confirmationDialog(
                "Turn on private iCloud sync?",
                isPresented: $isSyncSetupPromptPresented,
                titleVisibility: .visible
            ) {
                Button("Open Sync Setup") {
                    coordinator.requestSyncSetup(source: "home_sync")
                }
                Button("Not Now", role: .cancel) {
                    coordinator.iCloudSyncStatusText = nil
                }
            } message: {
                Text("Muesli will sync voice note text, meeting transcripts, notes, and summaries with your Mac through your private iCloud account. Audio stays local.")
            }
            .onAppear {
                refreshVisibleStateIfNeeded()
                if Self.hasDebugSimulatorLaunchArgument("--muesli-ui-testing-action-button-onboarding") {
                    isActionButtonOnboardingPresented = true
                }
            }
            .onChange(of: isActive) { _, active in
                guard active else { return }
                refreshVisibleStateIfNeeded()
            }
            .onChange(of: coordinator.voiceNoteHistoryPresentation.revision) { _, _ in
                guard isActive else { return }
                updateDashboardStats()
            }
            .onChange(of: sourceFilter) { _, _ in
                guard isActive else { return }
                updateDashboardStats()
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active, isActive else { return }
                refreshVisibleStateIfNeeded()
            }
            .onChange(of: microphonePreference) { _, _ in
                guard isActive else { return }
                coordinator.refreshAudioInputRoute()
            }
            .onChange(of: keyboardSessionMode) { _, enabled in
                guard isActive else { return }
                coordinator.setKeyboardSessionModeEnabled(enabled)
            }
            .navigationDestination(for: UUID.self) { resultID in
                if let result = coordinator.voiceNoteHistoryPresentation.history.first(
                    where: { $0.id == resultID }
                ),
                   let session = coordinator.recordingSession(for: result),
                   let audioURL = coordinator.audioFileURL(for: result) {
                    DictationAudioDetailView(result: result, session: session, audioURL: audioURL) {
                        coordinator.copyToClipboard(result)
                    } onDeleteAudio: {
                        coordinator.deleteDictationAudio(for: result)
                    }
                } else {
                    DictationAudioMissingView()
                }
            }
        }
        .fullScreenCover(isPresented: $isActionButtonOnboardingPresented) {
            ActionButtonOnboardingView(coordinator: coordinator)
        }
    }

    private var shouldShowActionButtonInvitation: Bool {
        guard #available(iOS 18.0, *) else { return false }
        return UIDevice.current.userInterfaceIdiom == .phone
    }

    private var actionButtonInvitation: some View {
        Button {
            isActionButtonOnboardingPresented = true
            AppTelemetry.signal("action_button_invitation_opened")
        } label: {
            HStack(spacing: MuesliTheme.spacing12) {
                Image(systemName: "button.programmable")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(MuesliTheme.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Action Button").font(MuesliTheme.headline())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text(actionButtonSetupCompleted ? "Previously verified" : "Dictation or a meeting note")
                        .font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textSecondary)
                }
                Spacer(minLength: 8)
                Text(actionButtonSetupCompleted ? "Reconfigure" : "Set Up")
                    .font(MuesliTheme.headline()).foregroundStyle(MuesliTheme.accent)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(MuesliTheme.backgroundRaised, in: RoundedRectangle(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(MuesliTheme.surfaceBorder) }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("dictation.actionButtonInvitation")
    }

    @ViewBuilder
    private var homeStatsRow: some View {
        let stats = dashboardStats
        HStack(spacing: MuesliTheme.spacing8) {
            DictationHomeStatTile(
                value: stats.streak,
                label: "streak",
                systemImage: "flame.fill",
                tint: sourceFilter.statTint(default: Color(hex: 0xFF9F2D))
            )
            DictationHomeStatTile(
                value: stats.words,
                label: "words",
                systemImage: "waveform",
                tint: sourceFilter.statTint(default: MuesliTheme.accent)
            )
            DictationHomeStatTile(
                value: stats.wpm,
                label: "WPM",
                systemImage: "speedometer",
                tint: sourceFilter.statTint(default: MuesliTheme.success)
            )
            DictationHomeStatTile(
                value: stats.meetings,
                label: "meetings",
                systemImage: "person.2",
                tint: sourceFilter.statTint(default: MuesliTheme.accent)
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(sourceFilter.title) stats: \(stats.streak) day streak, \(stats.words) words, \(stats.wpm) words per minute, \(stats.meetings) meetings"
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
            HStack(spacing: MuesliTheme.spacing12) {
                Image("MuesliAppIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 42, height: 42)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .shadow(color: MuesliTheme.accent.opacity(0.24), radius: 8, x: 0, y: 3)
                    .accessibilityHidden(true)
                Text("muesli")
                    .font(MuesliTheme.title2())
                    .foregroundStyle(MuesliTheme.textPrimary)
            }

            Text("Local-first voice notes for iOS")
                .font(MuesliTheme.callout())
                .foregroundStyle(MuesliTheme.textSecondary)
        }
    }

    private func updateDashboardStats() {
        let history = statsHistory
        let sessions = statsSessions
        dashboardStats = DictationDashboardStats(
            words: formattedCompactCount(totalDictationWords(in: history)),
            wpm: formattedAverageWPM(history: history, sessions: sessions),
            meetings: formattedCompactCount(totalMeetingCount(in: sessions)),
            streak: "\(currentActivityStreak(history: history, sessions: sessions))"
        )
    }

    private var keyboardSessionHomeControl: some View {
        MuesliSurface(
            cornerRadius: MuesliTheme.cornerMedium,
            tint: keyboardSessionMode ? MuesliTheme.success : MuesliTheme.accent,
            isInteractive: true
        ) {
            HStack(spacing: MuesliTheme.spacing8) {
                ZStack {
                    Circle()
                        .fill(keyboardSessionMode ? MuesliTheme.success.opacity(0.16) : MuesliTheme.accentSubtle)
                    Image(systemName: keyboardSessionMode ? "mic.circle.fill" : "mic.circle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(keyboardSessionMode ? MuesliTheme.success : MuesliTheme.accent)
                }
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)

                Text("Persistent mic for improved experience")
                    .font(MuesliTheme.callout())
                    .foregroundStyle(MuesliTheme.textPrimary)
                    .lineLimit(1)
                    .allowsTightening(true)
                    .minimumScaleFactor(0.82)

                Spacer(minLength: MuesliTheme.spacing8)

                Toggle("Persistent mic for improved experience", isOn: $keyboardSessionMode)
                    .labelsHidden()
                    .tint(MuesliTheme.success)
                    .frame(minWidth: 52, minHeight: 44)
            }
            .padding(.horizontal, MuesliTheme.spacing12)
            .padding(.vertical, MuesliTheme.spacing4)
            .contentShape(Rectangle())
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Persistent mic for improved experience")
        .accessibilityValue(keyboardSessionMode ? "On" : "Off")
        .accessibilityHint("Keeps a Muesli microphone session ready for keyboard dictation.")
    }

    private func totalDictationWords(in history: [DictationResult]) -> Int {
        history.reduce(0) { total, result in
            total + result.text.split { $0.isWhitespace || $0.isNewline }.count
        }
    }

    private func totalMeetingCount(in sessions: [RecordingSession]) -> Int {
        sessions.filter { $0.kind == .meeting }.count
    }

    private func formattedAverageWPM(history: [DictationResult], sessions: [RecordingSession]) -> String {
        let sessionsByID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let completedDictationSessions = history.compactMap { result -> (words: Int, duration: TimeInterval)? in
            guard let sessionID = result.sessionID,
                  let session = sessionsByID[sessionID],
                  let duration = session.duration,
                  duration >= 10 else {
                return nil
            }

            let words = result.text.split { $0.isWhitespace || $0.isNewline }.count
            guard words > 0 else { return nil }
            return (words, duration)
        }

        let totalWords = completedDictationSessions.reduce(0) { $0 + $1.words }
        let totalSeconds = completedDictationSessions.reduce(0) { $0 + $1.duration }
        guard totalWords > 0, totalSeconds > 0 else { return "0" }

        let wpm = Double(totalWords) / max(totalSeconds / 60, 1 / 60)
        return "\(Int(wpm.rounded()))"
    }

    private func currentActivityStreak(history: [DictationResult], sessions: [RecordingSession]) -> Int {
        let calendar = Calendar.current
        let countedSessions = sessions.filter { $0.phase != .cancelled && $0.phase != .failed }
        let activeDays = Set(
            history.map { calendar.startOfDay(for: $0.createdAt) }
                + countedSessions.map { calendar.startOfDay(for: $0.createdAt) }
        )

        guard !activeDays.isEmpty else { return 0 }

        var streak = 0
        var day = calendar.startOfDay(for: .now)
        if !activeDays.contains(day),
           let yesterday = calendar.date(byAdding: .day, value: -1, to: day) {
            day = yesterday
        }

        while activeDays.contains(day) {
            streak += 1
            guard let previousDay = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previousDay
        }

        return streak
    }

    private func formattedCompactCount(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 10_000 {
            return String(format: "%.1fk", Double(value) / 1_000)
        }
        if value >= 1_000 {
            return "\(value.formatted())"
        }
        return "\(value)"
    }

    private var recorderPanel: some View {
        MuesliSurface(
            cornerRadius: MuesliTheme.cornerLarge,
            tint: statusColor,
            isInteractive: true
        ) {
            VStack(spacing: MuesliTheme.spacing12) {
                Picker("Capture mode", selection: $captureMode) {
                    ForEach(DashboardCaptureMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 240)
                .disabled(coordinator.isRecording || isTranscribing)

                Group {
                    if isWaveformActive {
                        VStack(spacing: MuesliTheme.spacing4) {
                            HStack {
                                Spacer(minLength: 0)

                                if coordinator.isRecording {
                                    VoiceNoteElapsedBadge(
                                        liveState: coordinator.voiceNoteLiveState,
                                        color: statusColor,
                                        isActive: isActive
                                    )
                                    .accessibilityIdentifier("dictation.elapsedBadge")
                                }
                            }
                            .frame(height: 22)
                            .padding(.horizontal, MuesliTheme.spacing8)

                            VoiceNoteWaveformLeaf(
                                liveState: coordinator.voiceNoteLiveState,
                                mode: recorderWaveformMode,
                                color: statusColor,
                                isActive: isActive,
                                barCount: 40,
                                usesPreviewSignal: isPreviewWaveformActive
                            )
                            .frame(maxWidth: .infinity)
                            .frame(height: 42)
                            .padding(.horizontal, MuesliTheme.spacing12)
                            .accessibilityIdentifier("dictation.waveformBars")

                            Text(recorderWaveformStatus)
                                .font(MuesliTheme.captionMedium())
                                .foregroundStyle(MuesliTheme.textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 104)
                        .muesliGlassSurface(
                            cornerRadius: MuesliTheme.cornerMedium,
                            tint: statusColor
                        )
                        .accessibilityIdentifier("dictation.waveform")
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    } else {
                        VStack(spacing: MuesliTheme.spacing8) {
                            HStack(spacing: MuesliTheme.spacing8) {
                                transcriptionModelMenu
                                Spacer(minLength: MuesliTheme.spacing8)
                                microphoneMenu
                            }

                            if let idleRecorderStatusMessage {
                                Text(idleRecorderStatusMessage)
                                    .font(MuesliTheme.caption())
                                    .foregroundStyle(statusColor)
                                    .multilineTextAlignment(.center)
                                    .transition(.opacity)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                        .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.20), value: isWaveformActive)

                if shouldReserveRealtimeTranscript {
                    VoiceNoteLiveTranscriptRegion(liveState: coordinator.voiceNoteLiveState)
                }

                Group {
                    if coordinator.isRecording {
                        HStack(spacing: MuesliTheme.spacing24) {
                            Button(role: .destructive) {
                                coordinator.cancelActiveRecording()
                            } label: {
                                VoiceNoteRecordingActionLabel(
                                    title: "Discard",
                                    systemImage: "xmark",
                                    color: MuesliTheme.destructive
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Discard Recording")
                            .accessibilityAddTraits(.isButton)
                            .accessibilityIdentifier("dictation.cancelButton")

                            Button {
                                toggleCapture()
                            } label: {
                                VoiceNoteRecordingActionLabel(
                                    title: "Stop Recording",
                                    systemImage: "stop.fill",
                                    color: MuesliTheme.recordingStop
                                )
                            }
                            .buttonStyle(.plain)
                            .sensoryFeedback(.impact, trigger: coordinator.isRecording)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Stop Recording")
                            .accessibilityAddTraits(.isButton)
                            .accessibilityIdentifier("dictation.primaryButton")
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        Button {
                            toggleCapture()
                        } label: {
                            VoiceNoteRecordButtonLabel(
                                title: dictationButtonTitle,
                                systemImage: dictationButtonIcon,
                                color: statusColor,
                                isStopState: false,
                                isDisabled: isDictationButtonDisabled
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isDictationButtonDisabled)
                        .sensoryFeedback(.impact, trigger: coordinator.isRecording)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(dictationButtonTitle)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityIdentifier("dictation.primaryButton")
                    }
                }
                .padding(.top, 0)

                if shouldShowKeyboardSetupRow && !shouldHideKeyboardSetupRowForMockPreview {
                    keyboardShortcutRow
                        .opacity(coordinator.isRecording ? 0 : 1)
                        .allowsHitTesting(!coordinator.isRecording)
                }
            }
            .padding(MuesliTheme.spacing16)
        }
        .accessibilityIdentifier("dictation.recorderPanel")
    }

    private func toggleCapture() {
        if coordinator.isRecording {
            coordinator.toggleRecording()
        } else if captureMode == .notepad {
            coordinator.startNotepadRecording()
        } else {
            coordinator.toggleRecording()
        }
    }

    private var transcriptionModelMenu: some View {
        Menu {
            Section("Ready models") {
                ForEach(LocalTranscriptionModel.allCases.filter(\.isDownloaded)) { model in
                    Button {
                        coordinator.selectTranscriptionModel(model)
                    } label: {
                        Label(
                            model.displayName,
                            systemImage: model == coordinator.selectedTranscriptionModel
                                ? "checkmark"
                                : "circle"
                        )
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(MuesliTheme.success)
                    .frame(width: 7, height: 7)
                Text(coordinator.selectedTranscriptionModel.shortName)
                    .font(MuesliTheme.captionMedium())
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(MuesliTheme.textPrimary)
            .padding(.horizontal, MuesliTheme.spacing8)
            .frame(height: 36)
            .background(MuesliTheme.accent.opacity(0.10), in: Capsule())
            .overlay(Capsule().strokeBorder(MuesliTheme.accent.opacity(0.28), lineWidth: 1))
            .contentShape(Capsule())
        }
        .menuOrder(.fixed)
        .accessibilityLabel("Transcription model")
        .accessibilityValue(coordinator.selectedTranscriptionModel.displayName)
    }

    private var microphoneMenu: some View {
        Menu {
            Section("Recording Microphone") {
                ForEach(microphonePreferenceOptions) { option in
                    Button {
                        microphonePreference = option.rawValue
                        coordinator.refreshAudioInputRoute()
                    } label: {
                        Label(
                            option.label,
                            systemImage: option.rawValue == microphonePreference ? "checkmark" : "mic"
                        )
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "mic")
                    .font(.system(size: 13, weight: .semibold))
                Text(coordinator.audioInputRouteText)
                    .font(MuesliTheme.captionMedium())
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .foregroundStyle(MuesliTheme.textSecondary)
            .padding(.horizontal, MuesliTheme.spacing8)
            .frame(height: 36)
            .background(MuesliTheme.surfacePrimary)
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .menuOrder(.fixed)
        .disabled(coordinator.isRecording)
        .accessibilityLabel("Recording microphone")
        .accessibilityValue(coordinator.audioInputRouteText)
    }

    private var microphonePreferenceOptions: [RecordingMicrophonePreference] {
        let options = AudioInputRouteManager.availablePreferenceOptions()
        let currentPreference = RecordingMicrophonePreference(rawValue: microphonePreference) ?? .automatic
        guard !options.contains(currentPreference) else { return options }
        return options + [currentPreference]
    }

    private var keyboardShortcutRow: some View {
        HStack(spacing: MuesliTheme.spacing12) {
            Image(systemName: "keyboard")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(MuesliTheme.accent)
                .frame(width: 32, height: 32)
                .background(MuesliTheme.accentSubtle)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text("Use from keyboard")
                    .font(MuesliTheme.captionMedium())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Text("Add Muesli Keyboard, enable Full Access, then tap mic in any text field.")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .lineLimit(2)
            }

            Spacer(minLength: MuesliTheme.spacing8)

            Button("Setup", action: openKeyboardSettings)
                .font(MuesliTheme.captionMedium())
                .buttonStyle(.plain)
                .foregroundStyle(MuesliTheme.accent)
        }
        .padding(MuesliTheme.spacing12)
        .muesliGlassSurface(cornerRadius: MuesliTheme.cornerMedium, tint: MuesliTheme.accent)
    }

    @ViewBuilder
    private var voiceNoteHistorySection: some View {
        let timeline = visibleVoiceNoteTimeline
        historyHeader(timeline: timeline)
        historyRows(timeline: timeline)
    }

    private func historyHeader(timeline: [VoiceNoteTimelineItem]) -> some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    Text("Recent Voice Notes")
                        .font(MuesliTheme.title3())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text("\(timeline.count) saved")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                }

                Spacer()

                CoordinatorICloudSyncStatusButton(
                    coordinator: coordinator,
                    isEnabled: iCloudSyncEnabled,
                    action: triggerHomeSync
                )

                if let status = coordinator.clipboardStatusText {
                    Label(status, systemImage: "checkmark")
                        .font(MuesliTheme.captionMedium())
                        .foregroundStyle(MuesliTheme.success)
                }
            }

            if sourceFilter != .all || !timeline.isEmpty {
                DictationSourceFilterPicker(selection: $sourceFilter)
            }
        }
    }

    @ViewBuilder
    private func historyRows(timeline: [VoiceNoteTimelineItem]) -> some View {
        Group {
            if timeline.isEmpty {
                emptyHistory
            } else {
                LazyVStack(spacing: MuesliTheme.spacing12) {
                    ForEach(timeline) { item in
                        switch item {
                        case .recoverable(let session):
                            RecoverableVoiceNoteRow(
                                session: session,
                                // A capture that is actually running still
                                // appears here; deleting it underneath the
                                // recorder would fail the work in flight.
                                canDelete: !coordinator.isCapturingVoiceNote(sessionID: session.id),
                                action: { coordinator.openLongVoiceNote(session) },
                                onDelete: { Task { await coordinator.deleteRecoverableVoiceNote(session) } }
                            )
                        case .completed(let result, let session):
                            let isNotepad = session?.startedAsNotepad == true
                            let hasPlayableAudio = !isNotepad
                                && session?.keepsAudioRecording == true
                                && (
                                    session.flatMap { coordinator.audioFileURL(for: $0) } != nil
                                    || shouldUseMockDictations
                                )
                            let canOpen = session?.isLongForm == true || hasPlayableAudio

                            DictationHistoryRow(
                                result: result,
                                session: session,
                                onOpen: canOpen ? {
                                    openCompletedVoiceNote(
                                        result: result,
                                        session: session,
                                        hasPlayableAudio: hasPlayableAudio
                                    )
                                } : nil,
                                onPlay: hasPlayableAudio ? {
                                    navigationPath.append(result.id)
                                } : nil,
                                onCopy: { coordinator.copyToClipboard(result) },
                                onDelete: { Task { await coordinator.deleteDictation(result) } }
                            )
                        }
                    }
                }
                .animation(
                    nil,
                    value: coordinator.voiceNoteHistoryPresentation.revision
                )
            }
        }
    }

    private var visibleVoiceNoteTimeline: [VoiceNoteTimelineItem] {
        #if DEBUG
        if shouldUseMockDictations {
            return VoiceNoteTimelineBuilder.build(from: .init(
                history: Self.mockDictationHistory,
                sessions: Self.mockRecordingSessions,
                sourceFilter: sourceFilter
            ))
        }
        #endif

        return coordinator.voiceNoteHistoryPresentation.timeline(for: sourceFilter)
    }

    private func openCompletedVoiceNote(
        result: DictationResult,
        session: RecordingSession?,
        hasPlayableAudio: Bool
    ) {
        if let session, session.isLongForm {
            coordinator.openLongVoiceNote(session)
        } else if hasPlayableAudio {
            navigationPath.append(result.id)
        }
    }

    private var statsHistory: [DictationResult] {
        displayHistory.filter { sourceFilter.includes($0.syncOrigin) }
    }

    private var statsSessions: [RecordingSession] {
        coordinator.voiceNoteHistoryPresentation.sessions.filter {
            sourceFilter.includes($0.syncOrigin)
        }
    }

    private var displayHistory: [DictationResult] {
        #if DEBUG
        if shouldUseMockDictations {
            return Self.mockDictationHistory
        }
        #endif

        return coordinator.voiceNoteHistoryPresentation.history
    }

    private var shouldUseMockDictations: Bool {
        Self.hasDebugSimulatorLaunchArgument("--muesli-mock-dictations")
    }

    private var isPreviewWaveformActive: Bool {
        Self.hasDebugSimulatorLaunchArgument("--muesli-preview-waveform")
    }

    private var shouldHideKeyboardSetupRowForMockPreview: Bool {
        shouldUseMockDictations || isPreviewWaveformActive
    }

    private var emptyHistory: some View {
        MuesliSurface {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                Image(systemName: "text.badge.plus")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(MuesliTheme.accent)

                Text(emptyHistoryTitle)
                    .font(MuesliTheme.headline())
                    .foregroundStyle(MuesliTheme.textPrimary)

                Text(emptyHistoryDetail)
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(MuesliTheme.spacing16)
        }
    }

    private var emptyHistoryTitle: String {
        displayHistory.isEmpty ? "No voice notes yet" : "No \(sourceFilter.title.lowercased()) voice notes"
    }

    private var emptyHistoryDetail: String {
        if displayHistory.isEmpty {
            return "Recorded voice notes from the app will appear here as a timeline."
        }
        return "Switch filters to see the complete voice note history."
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
        isListeningWaveformActive || isTranscribing
    }

    private var isListeningWaveformActive: Bool {
        isPreviewWaveformActive || coordinator.isRecording
    }

    private var isTranscribing: Bool {
        coordinator.statusText == "Transcribing"
    }

    private var recorderWaveformMode: MuesliFloatingWaveformMode {
        if isListeningWaveformActive {
            .level
        } else if isTranscribing {
            .waiting
        } else {
            .idle
        }
    }

    private var recorderWaveformStatus: String {
        if isListeningWaveformActive {
            "Listening"
        } else if isTranscribing {
            "Transcribing"
        } else {
            "Ready"
        }
    }

    private var idleRecorderStatusMessage: String? {
        let status = coordinator.statusText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !status.isEmpty,
              status != "Ready",
              !status.lowercased().hasSuffix(" ready")
        else { return nil }
        return status
    }

    private var shouldReserveRealtimeTranscript: Bool {
        isActive
            && coordinator.selectedTranscriptionModel.supportsRealtimeStreaming
            && isWaveformActive
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
            captureMode == .notepad ? "Start Notepad" : "Start Quick Note"
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

    private func triggerHomeSync() {
        if !iCloudSyncEnabled {
            coordinator.iCloudSyncStatusText = nil
            isSyncSetupPromptPresented = true
            return
        }
        coordinator.syncICloudTextIfEnabled(reason: "home_manual")
    }

    private func refreshVisibleStateIfNeeded() {
        guard isActive else { return }
        coordinator.refreshHistory()
        coordinator.refreshAudioInputRoute()
        refreshKeyboardSetupPromptVisibility()
        updateDashboardStats()
    }

    private func openKeyboardSettings() {
        #if canImport(UIKit)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            openURL(url)
        }
        #endif
    }

    private func refreshKeyboardSetupPromptVisibility() {
        let extensionStatus = try? SharedStore().keyboardExtensionStatus()
        let keyboardConfirmed = UserDefaults.standard.bool(forKey: OnboardingPreferenceKeys.keyboardEnabledConfirmed)
        let fullAccessConfirmed = UserDefaults.standard.bool(forKey: OnboardingPreferenceKeys.fullAccessConfirmed)
        shouldShowKeyboardSetupRow = extensionStatus?.hasOpenAccess != true && !(keyboardConfirmed && fullAccessConfirmed)
    }

    private static func hasDebugSimulatorLaunchArgument(_ argument: String) -> Bool {
        #if DEBUG && targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains(argument)
        #else
        false
        #endif
    }

    #if DEBUG
    private static let mockLongVoiceNoteSessionID = UUID(uuidString: "B5D51EAA-7A0A-42CE-B25A-E01F71000001")!
    private static let mockNotesSessionID = UUID(uuidString: "B5D51EAA-7A0A-42CE-B25A-E01F71000002")!

    private static let mockDictationHistory: [DictationResult] = {
        let calendar = Calendar.current
        let baseDate = calendar.date(from: DateComponents(year: 2026, month: 6, day: 30, hour: 13, minute: 30)) ?? .now
        let samples: [(String, String?, UUID?)] = [
            (
                "A longer voice note should stay easy to scan in the timeline even when the transcript contains several paragraphs. The preview needs a predictable height so one recording cannot take over the entire screen. Keep the first four lines visible, preserve the full transcript, and let the reader expand it only when they want the additional context.",
                "ios",
                mockLongVoiceNoteSessionID
            ),
            ("The capture screen should feel like a local first console, fast enough to open and start speaking without thinking about folders or setup.", "ios", mockNotesSessionID),
            ("Currently bleeding talent to the inference giants", "macOS", nil),
            ("We should test the magnified top note while scrolling because this is the exact state people will read after recording a quick thought.", "ios", nil),
            ("The Mac companion app can stay focused on longer workflows while the phone stays optimized for immediate capture.", "macOS", nil),
            ("Meeting notes need the same private sync language, but the voice note screen should remain lighter and faster.", "ios", nil),
            ("If a note is imported from the Mac, keep the provenance visible but do not let the chip overpower the transcript.", "macOS", nil),
            ("The tab bar should feel stable and tappable, with blue as the active state and green reserved for sync confidence.", "ios", nil),
            ("Keep the interface blue black white and green so the product feels consistent across phone and Mac.", "ios", nil),
            ("When the top card grows, the surrounding cards should stay quiet so the reading focus feels intentional rather than busy.", "macOS", nil)
        ]

        return samples.enumerated().map { index, sample in
            DictationResult(
                requestID: UUID(),
                sessionID: sample.2,
                text: sample.0,
                createdAt: calendar.date(byAdding: .minute, value: -index * 47, to: baseDate) ?? baseDate,
                engineIdentifier: sample.1 == "macOS" ? "icloud" : "parakeet",
                source: sample.1
            )
        }
    }()

    private static let mockRecordingSessions: [RecordingSession] = {
        let now = Date.now
        return [
            RecordingSession(
                id: mockLongVoiceNoteSessionID,
                kind: .quickDictation,
                createdAt: now,
                startedAt: now.addingTimeInterval(-185),
                endedAt: now,
                phase: .completed,
                audioFileName: "mock-long-voice-note.wav",
                keepsAudioRecording: true,
                source: "ios",
                isLongForm: true,
                longFormActivatedAt: now.addingTimeInterval(-125),
                longFormThresholdSeconds: 60,
                scratchpadText: "Follow up on the timeline design."
            ),
            RecordingSession(
                id: mockNotesSessionID,
                kind: .quickDictation,
                createdAt: now.addingTimeInterval(-47 * 60),
                startedAt: now.addingTimeInterval(-48 * 60),
                endedAt: now.addingTimeInterval(-47 * 60),
                phase: .completed,
                source: "ios",
                manualNotes: "Check the capture flow with the team."
            )
        ]
    }()
    #endif
}

private struct DictationDashboardStats {
    static let empty = DictationDashboardStats(words: "0", wpm: "0", meetings: "0", streak: "0")

    let words: String
    let wpm: String
    let meetings: String
    let streak: String
}

private struct DictationHomeStatTile: View {
    let value: String
    let label: String
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(spacing: MuesliTheme.spacing4) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(height: 17)

            VStack(spacing: 1) {
                Text(value)
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.76)
                    .lineLimit(1)
                    .foregroundStyle(MuesliTheme.textPrimary)

                Text(label)
                    .font(MuesliTheme.caption())
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .foregroundStyle(MuesliTheme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 68)
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: MuesliTheme.cornerLarge, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            MuesliTheme.backgroundRaised.opacity(0.80),
                            MuesliTheme.backgroundDeep.opacity(0.68)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .overlay(alignment: .top) {
            RoundedRectangle(cornerRadius: MuesliTheme.cornerLarge, style: .continuous)
                .strokeBorder(MuesliTheme.glassHighlight.opacity(0.72), lineWidth: 0.7)
                .blendMode(.screen)
        }
        .overlay {
            RoundedRectangle(cornerRadius: MuesliTheme.cornerLarge, style: .continuous)
                .strokeBorder(MuesliTheme.accent.opacity(0.34), lineWidth: 1)
        }
        .shadow(color: MuesliTheme.accent.opacity(0.07), radius: 9, x: 0, y: 5)
        .shadow(color: .black.opacity(0.12), radius: 6, x: 0, y: 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value) \(label)")
    }
}

private struct RecoverableVoiceNoteRow: View {
    let session: RecordingSession
    let canDelete: Bool
    let action: () -> Void
    let onDelete: () -> Void
    @State private var isConfirmingDelete = false

    private var deleteMessage: String {
        session.audioFileName == nil
            ? "The audio for this voice note is gone, so it cannot be transcribed. This removes it from local history."
            : "This removes the voice note, and its audio, from local history."
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: MuesliTheme.spacing12) {
                Image(systemName: session.audioFileName == nil ? "waveform.slash" : "waveform.badge.exclamationmark")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(session.audioFileName == nil ? MuesliTheme.destructive : MuesliTheme.accent)
                    .frame(width: 36, height: 36)
                    .background(MuesliTheme.accentSubtle)
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    Text(session.audioFileName == nil ? "Audio unavailable" : "Needs transcription")
                        .font(MuesliTheme.headline())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text(session.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                    if let scratchpad = session.scratchpadText?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !scratchpad.isEmpty {
                        Text(scratchpad)
                            .font(MuesliTheme.callout())
                            .foregroundStyle(MuesliTheme.textSecondary)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: MuesliTheme.spacing8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(MuesliTheme.textTertiary)
            }
            .padding(MuesliTheme.spacing16)
            .background(MuesliTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium, style: .continuous)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityHint(session.audioFileName == nil ? "Opens recovery details" : "Opens retry actions")
        .contextMenu {
            if canDelete {
                Button("Delete Voice Note", systemImage: "trash", role: .destructive) {
                    isConfirmingDelete = true
                }
            }
        }
        .accessibilityAction(named: "Delete voice note") {
            if canDelete { isConfirmingDelete = true }
        }
        .confirmationDialog(
            "Delete this voice note?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Voice Note", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteMessage)
        }
    }
}

private struct VoiceNoteRecordButtonLabel: View {
    let title: String
    let systemImage: String
    let color: Color
    let isStopState: Bool
    let isDisabled: Bool

    var body: some View {
        VStack(spacing: MuesliTheme.spacing8) {
            ZStack {
                Circle()
                    .fill(color.opacity(isStopState ? 0.18 : 0.16))
                    .frame(width: haloSize, height: haloSize)
                    .blur(radius: 0.5)

                Circle()
                    .fill(outerRingFill)
                    .frame(width: outerRingSize, height: outerRingSize)
                    .overlay(
                        Circle()
                            .strokeBorder(outerRingBorder, lineWidth: 1.2)
                    )
                    .shadow(color: outerShadow, radius: 14, x: 0, y: 9)
                    .shadow(color: color.opacity(isStopState ? 0.10 : 0.22), radius: 18, x: 0, y: 7)

                Circle()
                    .fill(
                        LinearGradient(
                            colors: circleGradient,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: innerCircleSize, height: innerCircleSize)
                    .overlay(alignment: .topLeading) {
                        Circle()
                            .strokeBorder(.white.opacity(isDisabled ? 0.08 : 0.42), lineWidth: 2)
                            .padding(4)
                            .blur(radius: 0.2)
                            .mask(
                                LinearGradient(
                                    colors: [.white, .clear],
                                    startPoint: .topLeading,
                                    endPoint: .center
                                )
                            )
                    }
                    .overlay {
                        Circle()
                            .strokeBorder(circleBorder, lineWidth: 1)
                    }
                    .shadow(color: .white.opacity(isDisabled ? 0 : 0.10), radius: 2, x: -1, y: -1)
                    .shadow(color: .black.opacity(0.20), radius: 7, x: 0, y: 5)

                Image(systemName: systemImage)
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(iconColor)
            }

            Text(title)
                .font(MuesliTheme.headline())
                .foregroundStyle(titleColor)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 92)
        .contentShape(Rectangle())
    }

    private var haloSize: CGFloat {
        78
    }

    private var outerRingSize: CGFloat {
        70
    }

    private var innerCircleSize: CGFloat {
        60
    }

    private var outerRingFill: Color {
        if isDisabled {
            return MuesliTheme.surfacePrimary.opacity(0.72)
        }
        if isStopState {
            return MuesliTheme.recordingStop.opacity(0.24)
        }
        return color.opacity(0.18)
    }

    private var outerRingBorder: Color {
        if isDisabled {
            return MuesliTheme.surfaceBorder
        }
        if isStopState {
            return MuesliTheme.recordingStop.opacity(0.58)
        }
        return color.opacity(0.54)
    }

    private var circleGradient: [Color] {
        if isDisabled {
            return [
                MuesliTheme.surfacePrimary.opacity(0.72),
                MuesliTheme.surfacePrimary.opacity(0.52)
            ]
        }
        if isStopState {
            return [
                MuesliTheme.recordingStop,
                MuesliTheme.recordingStop.opacity(0.86)
            ]
        }
        return [
            color.opacity(0.96),
            Color(hex: 0x1B56D8).opacity(0.95)
        ]
    }

    private var circleBorder: Color {
        if isDisabled {
            MuesliTheme.surfaceBorder
        } else if isStopState {
            MuesliTheme.recordingStop.opacity(0.52)
        } else {
            color.opacity(0.36)
        }
    }

    private var outerShadow: Color {
        if isDisabled {
            return .clear
        }
        if isStopState {
            return MuesliTheme.recordingStop.opacity(0.28)
        }
        return MuesliTheme.accent.opacity(0.18)
    }

    private var iconColor: Color {
        if isDisabled {
            MuesliTheme.textTertiary
        } else if isStopState {
            .white
        } else {
            .white
        }
    }

    private var titleColor: Color {
        if isDisabled {
            MuesliTheme.textTertiary
        } else if isStopState {
            MuesliTheme.textPrimary
        } else {
            MuesliTheme.textPrimary
        }
    }
}

private struct VoiceNoteRecordingActionLabel: View {
    let title: String
    let systemImage: String
    let color: Color

    var body: some View {
        VStack(spacing: MuesliTheme.spacing8) {
            Image(systemName: systemImage)
                .font(.system(size: 21, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(color, in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(.white.opacity(0.16), lineWidth: 1)
                }
                .shadow(color: color.opacity(0.28), radius: 12, x: 0, y: 7)

            Text(title)
                .font(MuesliTheme.captionMedium())
                .foregroundStyle(MuesliTheme.textPrimary)
                .lineLimit(1)
        }
        .frame(width: 128, height: 92)
        .contentShape(Rectangle())
    }
}

private struct CoordinatorICloudSyncStatusButton: View {
    @Bindable var coordinator: DictationCoordinator
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        ICloudSyncStatusButton(
            isEnabled: isEnabled,
            isSyncing: coordinator.isICloudSyncInProgress,
            hasError: coordinator.iCloudSyncStatusText?
                .localizedCaseInsensitiveContains("sync failed") == true,
            action: action
        )
    }
}

struct ICloudSyncStatusButton: View {
    let isEnabled: Bool
    let isSyncing: Bool
    let hasError: Bool
    let action: () -> Void

    private var tint: Color {
        if hasError {
            return MuesliTheme.transcribing
        }
        if isEnabled {
            return MuesliTheme.accent
        }
        return MuesliTheme.textTertiary
    }

    private var accessibilityLabel: String {
        if isSyncing {
            return "Syncing with iCloud"
        }
        if hasError {
            return "Retry iCloud sync"
        }
        if isEnabled {
            return "Sync with iCloud"
        }
        return "Turn on iCloud sync"
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Image(systemName: hasError ? "icloud.slash" : "icloud")
                    .font(.system(size: 22, weight: .semibold))
                RotatingSyncGlyph(isAnimating: isSyncing)
                    .font(.system(size: 10, weight: .bold))
                    .offset(y: 1)
                    .opacity(hasError ? 0 : 1)
            }
            .foregroundStyle(tint)
            .frame(width: 44, height: 44)
            .muesliGlassButton(cornerRadius: 22, tint: tint)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isSyncing)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Double tap to sync text with your Mac through private iCloud.")
    }
}

private struct RotatingSyncGlyph: View {
    let isAnimating: Bool
    @State private var animationStartedAt: Date?

    var body: some View {
        // Keep this rotation time-driven: a repeatForever animation transaction
        // can leak into sibling updates and replay the voice-note status transition.
        TimelineView(.animation(paused: !isAnimating)) { context in
            Image(systemName: "arrow.triangle.2.circlepath")
                .rotationEffect(.degrees(ICloudSyncGlyphRotation.degrees(
                    at: context.date,
                    startedAt: animationStartedAt,
                    isAnimating: isAnimating
                )))
                .animation(.easeOut(duration: 0.15), value: isAnimating)
        }
        .onAppear {
            animationStartedAt = isAnimating ? .now : nil
        }
        .onChange(of: isAnimating) { _, isAnimating in
            animationStartedAt = isAnimating ? .now : nil
        }
    }
}

enum ICloudSyncGlyphRotation {
    static let period: TimeInterval = 0.9

    static func degrees(at date: Date, startedAt: Date?, isAnimating: Bool) -> Double {
        guard isAnimating, let startedAt else { return 0 }
        let elapsed = max(date.timeIntervalSince(startedAt), 0)
        let phase = elapsed.truncatingRemainder(dividingBy: period) / period
        return phase * 360
    }
}

private extension SyncOrigin {
    var title: String {
        switch self {
        case .thisIPhone:
            "This iPhone"
        case .fromMac:
            "From Mac"
        }
    }

    var detail: String {
        switch self {
        case .thisIPhone:
            "Recorded locally"
        case .fromMac:
            "Synced via iCloud"
        }
    }

    var systemImage: String {
        switch self {
        case .thisIPhone:
            "iphone"
        case .fromMac:
            "macbook"
        }
    }

    var accentColor: Color {
        switch self {
        case .thisIPhone:
            MuesliTheme.accent
        case .fromMac:
            MuesliTheme.success
        }
    }
}

private struct DictationSourceFilterPicker: View {
    @Binding var selection: DictationSourceFilter

    var body: some View {
        HStack(spacing: MuesliTheme.spacing4) {
            ForEach(DictationSourceFilter.allCases) { filter in
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
                .accessibilityLabel("Show \(filter.title.lowercased()) voice notes")
            }
        }
        .padding(3)
        .muesliGlassSurface(cornerRadius: MuesliTheme.cornerMedium, tint: MuesliTheme.accent)
    }
}

private struct DictationHistoryRow: View {
    let result: DictationResult
    let session: RecordingSession?
    let onOpen: (() -> Void)?
    let onPlay: (() -> Void)?
    let onCopy: () -> Void
    let onDelete: () -> Void
    @State private var isConfirmingDelete = false

    var body: some View {
        Group {
            if let onOpen {
                rowSurface
                    .contentShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium, style: .continuous))
                    .onTapGesture(perform: onOpen)
                    .accessibilityElement(children: .contain)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction(named: "Open voice note", onOpen)
            } else {
                rowSurface
            }
        }
        .confirmationDialog(
            "Delete this voice note?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Voice Note", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the voice note from local history.")
        }
    }

    private var rowSurface: some View {
        MuesliSwipeActionRow(
            leadingAction: .init(
                title: "Delete",
                systemImage: "trash",
                tint: MuesliTheme.destructive,
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
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(origin.accentColor)
                        .frame(width: 3)
                        .padding(.vertical, MuesliTheme.spacing12)

                    rowContent
                        .padding(.vertical, MuesliTheme.spacing16)
                        .padding(.leading, MuesliTheme.spacing12)
                        .padding(.trailing, MuesliTheme.spacing16)
                }
            }
        }
    }

    private var rowContent: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            HStack(alignment: .top, spacing: MuesliTheme.spacing12) {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    Text(result.createdAt, formatter: Self.dateFormatter)
                        .font(MuesliTheme.captionMedium())
                        .foregroundStyle(MuesliTheme.textSecondary)
                    Text(origin.detail)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(origin.accentColor.opacity(0.9))
                        .lineLimit(1)
                }

                Spacer(minLength: MuesliTheme.spacing8)

                if let onPlay {
                    Button(action: onPlay) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(MuesliTheme.accent)
                            .frame(width: 24, height: 24)
                            .padding(10)
                            .contentShape(Circle())
                            .padding(-10)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Play saved audio")
                    .accessibilityIdentifier("voiceNote.playAudio")
                }

                if session?.hasUserAuthoredNotes == true,
                   session?.startedAsNotepad != true {
                    VoiceNoteAttributeIcon(
                        systemImage: "note.text",
                        accessibilityLabel: "Has manual notes",
                        identifier: "voiceNote.badge.notes",
                        tint: MuesliTheme.textSecondary
                    )
                }

                if session?.isLongForm == true {
                    VoiceNoteAttributeIcon(
                        systemImage: session?.startedAsNotepad == true ? "book.closed" : "clock",
                        accessibilityLabel: session?.startedAsNotepad == true ? "Notepad" : "Long voice note",
                        identifier: "voiceNote.badge.longForm",
                        tint: MuesliTheme.accent
                    )
                }

                DictationOriginChip(origin: origin)
            }

            ExpandableTranscriptPreview(text: result.text, resultID: result.id)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var origin: SyncOrigin {
        result.syncOrigin
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private struct VoiceNoteAttributeIcon: View {
    let systemImage: String
    let accessibilityLabel: String
    let identifier: String
    let tint: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 24, height: 24)
            .background(tint.opacity(0.10))
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(tint.opacity(0.18), lineWidth: 0.7))
            .accessibilityLabel(accessibilityLabel)
            .accessibilityIdentifier(identifier)
    }
}

private struct ExpandableTranscriptPreview: View {
    let text: String
    let resultID: UUID
    @Environment(\.sizeCategory) private var sizeCategory
    @State private var isExpanded = false
    @State private var availableWidth: CGFloat = 0
    @State private var isTruncated = false

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
            transcript(lineLimit: isExpanded ? nil : 4)
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear {
                                updateOverflow(for: proxy.size.width)
                            }
                            .onChange(of: proxy.size.width) { _, width in
                                updateOverflow(for: width)
                            }
                    }
                }
                .textSelection(.enabled)

            if isTruncated {
                Button(isExpanded ? "Show less" : "Read more") {
                    withAnimation(.snappy(duration: 0.22)) {
                        isExpanded.toggle()
                    }
                }
                .font(MuesliTheme.captionMedium())
                .foregroundStyle(MuesliTheme.accent)
                .buttonStyle(.plain)
                .accessibilityIdentifier("dictation.readMore.\(resultID.uuidString)")
            }
        }
        .onChange(of: text) { _, _ in
            updateOverflow(for: availableWidth)
        }
        .onChange(of: sizeCategory) { _, _ in
            updateOverflow(for: availableWidth)
        }
    }

    private func transcript(lineLimit: Int?) -> some View {
        Text(text)
            .font(MuesliTheme.transcript())
            .foregroundStyle(MuesliTheme.textPrimary)
            .lineSpacing(2)
            .lineLimit(lineLimit)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func updateOverflow(for width: CGFloat) {
        guard width > 0 else { return }
        if abs(availableWidth - width) > 0.5 {
            availableWidth = width
        }
        let overflow = TranscriptOverflowDetector.isTruncated(
            text,
            width: width,
            lineLimit: 4,
            sizeCategory: sizeCategory
        )
        if isTruncated != overflow {
            isTruncated = overflow
        }
    }
}

@MainActor
enum TranscriptOverflowDetector {
    private static let sampleCharacterLimit = 2_048

    static func isTruncated(
        _ text: String,
        width: CGFloat,
        lineLimit: Int,
        sizeCategory: ContentSizeCategory
    ) -> Bool {
        guard !text.isEmpty, width > 0, lineLimit > 0 else { return false }

        let traits = UITraitCollection(preferredContentSizeCategory: sizeCategory.uiKitCategory)
        let font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits)
        let sampleEnd = text.index(
            text.startIndex,
            offsetBy: sampleCharacterLimit,
            limitedBy: text.endIndex
        ) ?? text.endIndex
        let omittedRemainder = sampleEnd < text.endIndex
        let attributedText = NSAttributedString(
            string: String(text[..<sampleEnd]),
            attributes: [.font: font]
        )
        let typesetter = CTTypesetterCreateWithAttributedString(attributedText)
        var location = 0

        for _ in 0..<lineLimit {
            guard location < attributedText.length else { return false }
            let lineLength = CTTypesetterSuggestLineBreak(typesetter, location, width)
            guard lineLength > 0 else { return true }
            location += lineLength
        }

        return location < attributedText.length || omittedRemainder
    }
}

private extension ContentSizeCategory {
    var uiKitCategory: UIContentSizeCategory {
        switch self {
        case .extraSmall: .extraSmall
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .extraLarge: .extraLarge
        case .extraExtraLarge: .extraExtraLarge
        case .extraExtraExtraLarge: .extraExtraExtraLarge
        case .accessibilityMedium: .accessibilityMedium
        case .accessibilityLarge: .accessibilityLarge
        case .accessibilityExtraLarge: .accessibilityExtraLarge
        case .accessibilityExtraExtraLarge: .accessibilityExtraExtraLarge
        case .accessibilityExtraExtraExtraLarge: .accessibilityExtraExtraExtraLarge
        @unknown default: .large
        }
    }
}

private struct DictationAudioDetailView: View {
    let result: DictationResult
    let session: RecordingSession
    let audioURL: URL
    let onCopy: () -> Void
    let onDeleteAudio: () -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var filesExportStatus: String?
    @State private var isFilesExporterPresented = false
    @State private var isDeleteAudioConfirmationPresented = false
    @State private var audioDocument: AudioFileDocument?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing20) {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    Text(session.title ?? session.kind.title)
                        .font(MuesliTheme.title1())
                        .foregroundStyle(MuesliTheme.textPrimary)

                    Text(result.createdAt, formatter: Self.dateFormatter)
                        .font(MuesliTheme.callout())
                        .foregroundStyle(MuesliTheme.textSecondary)
                }

                MuesliSurface(cornerRadius: MuesliTheme.cornerLarge) {
                    VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Recording")
                                .font(MuesliTheme.title3())
                                .foregroundStyle(MuesliTheme.textPrimary)

                            Spacer()

                            if let duration = session.duration {
                                Text(formatTime(duration))
                                    .font(MuesliTheme.captionMedium())
                                    .monospacedDigit()
                                    .foregroundStyle(MuesliTheme.textTertiary)
                            }
                        }

                        SavedAudioPlayerView(audioURL: audioURL)

                        HStack(spacing: MuesliTheme.spacing12) {
                            ShareLink(item: audioURL) {
                                Label("Share", systemImage: "square.and.arrow.up")
                                    .font(MuesliTheme.captionMedium())
                            }
                            .foregroundStyle(MuesliTheme.accent)

                            Button(action: saveAudioToFiles) {
                                Label("Save to Files", systemImage: "folder")
                                    .font(MuesliTheme.captionMedium())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(MuesliTheme.accent)

                            Spacer()

                            Button(role: .destructive) {
                                isDeleteAudioConfirmationPresented = true
                            } label: {
                                Label("Delete Audio", systemImage: "trash")
                                    .font(MuesliTheme.captionMedium())
                            }
                            .buttonStyle(.plain)
                        }

                        VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                            if let fileName = session.audioFileName {
                                Label(fileName, systemImage: "iphone")
                                    .font(MuesliTheme.caption())
                                    .foregroundStyle(MuesliTheme.textTertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            if let filesExportStatus {
                                Text(filesExportStatus)
                                    .font(MuesliTheme.caption())
                                    .foregroundStyle(MuesliTheme.textTertiary)
                            }
                        }
                    }
                    .padding(MuesliTheme.spacing16)
                }

                MuesliSurface(cornerRadius: MuesliTheme.cornerLarge) {
                    VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                        HStack {
                            Text("Transcript")
                                .font(MuesliTheme.title3())
                                .foregroundStyle(MuesliTheme.textPrimary)
                            Spacer()
                            Button(action: onCopy) {
                                Label("Copy", systemImage: "doc.on.doc")
                                    .font(MuesliTheme.captionMedium())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(MuesliTheme.accent)
                        }

                        Text(result.text.isEmpty ? "No speech detected." : result.text)
                            .font(MuesliTheme.body())
                            .foregroundStyle(result.text.isEmpty ? MuesliTheme.textTertiary : MuesliTheme.textPrimary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(MuesliTheme.spacing16)
                }
            }
            .padding(.horizontal, MuesliTheme.spacing20)
            .padding(.top, MuesliTheme.spacing24)
            .padding(.bottom, MuesliTheme.spacing24)
        }
        .background(MuesliTheme.backgroundBase)
        .navigationTitle("Voice Note")
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            "Delete saved audio?",
            isPresented: $isDeleteAudioConfirmationPresented,
        ) {
            Button("Delete Audio Only", role: .destructive) {
                if onDeleteAudio() {
                    dismiss()
                } else {
                    filesExportStatus = "Audio delete failed"
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes only the local WAV recording. The transcript and voice note stay in history.")
        }
        .fileExporter(
            isPresented: $isFilesExporterPresented,
            document: audioDocument,
            contentType: AudioFileDocument.contentType,
            defaultFilename: audioURL.lastPathComponent
        ) { result in
            switch result {
            case .success:
                filesExportStatus = "Saved with Files"
            case .failure:
                filesExportStatus = "Files export failed"
            }
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        guard time.isFinite, time > 0 else { return "0:00" }
        let totalSeconds = Int(time.rounded())
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func saveAudioToFiles() {
        do {
            audioDocument = try AudioFileDocument(url: audioURL)
            isFilesExporterPresented = true
        } catch {
            filesExportStatus = "Files export failed"
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private struct DictationAudioMissingView: View {
    var body: some View {
        VStack(spacing: MuesliTheme.spacing12) {
            Image(systemName: "waveform.slash")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(MuesliTheme.textTertiary)
            Text("Recording unavailable")
                .font(MuesliTheme.title3())
                .foregroundStyle(MuesliTheme.textPrimary)
            Text("This voice note either was not saved with audio or its local audio file has been removed.")
                .font(MuesliTheme.body())
                .foregroundStyle(MuesliTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(MuesliTheme.spacing24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MuesliTheme.backgroundBase)
    }
}

private struct AudioFileDocument: FileDocument {
    static let contentType = UTType(filenameExtension: "wav") ?? .audio
    static var readableContentTypes: [UTType] { [contentType] }

    private var data: Data

    init(url: URL) throws {
        data = try Data(contentsOf: url)
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private struct DictationOriginChip: View {
    let origin: SyncOrigin

    var body: some View {
        Label {
            Text(origin.title)
                .lineLimit(1)
        } icon: {
            Image(systemName: origin.systemImage)
                .font(.system(size: 9, weight: .semibold))
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(origin.accentColor)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(origin.accentColor.opacity(0.13))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .strokeBorder(origin.accentColor.opacity(0.28), lineWidth: 1)
        )
        .accessibilityLabel(origin.title)
    }
}
