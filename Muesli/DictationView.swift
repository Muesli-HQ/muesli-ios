import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

struct DictationView: View {
    @Bindable var coordinator: DictationCoordinator
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(MuesliPreferences.iCloudSyncEnabledKey) private var iCloudSyncEnabled = false
    @AppStorage(MuesliPreferences.recordingMicrophonePreferenceKey) private var microphonePreference = RecordingMicrophonePreference.automatic.rawValue
    @State private var sourceFilter: DictationSourceFilter = .all
    @State private var isSyncSetupPromptPresented = false
    @State private var shouldShowKeyboardSetupRow = false
    @State private var previewInputLevel = 0.0
    @State private var dashboardStats = DictationDashboardStats.empty

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
                    header
                    homeStatsRow
                    recorderPanel
                    historyHeader
                    historyRows
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
                coordinator.refreshHistory()
                coordinator.refreshAudioInputRoute()
                refreshKeyboardSetupPromptVisibility()
                updateDashboardStats()
            }
            .onChange(of: coordinator.dictationHistory.count) { _, _ in
                updateDashboardStats()
            }
            .onChange(of: coordinator.recordingSessions.count) { _, _ in
                updateDashboardStats()
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                coordinator.refreshAudioInputRoute()
                refreshKeyboardSetupPromptVisibility()
                updateDashboardStats()
            }
            .onChange(of: microphonePreference) { _, _ in
                coordinator.refreshAudioInputRoute()
            }
            .navigationDestination(for: UUID.self) { resultID in
                if let result = coordinator.dictationHistory.first(where: { $0.id == resultID }),
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
    }

    @ViewBuilder
    private var homeStatsRow: some View {
        let stats = dashboardStats
        HStack(spacing: MuesliTheme.spacing8) {
            DictationHomeStatTile(
                value: stats.streak,
                label: "streak",
                systemImage: "flame.fill",
                tint: Color(hex: 0xFF9F2D)
            )
            DictationHomeStatTile(
                value: stats.words,
                label: "words",
                systemImage: "waveform",
                tint: MuesliTheme.accent
            )
            DictationHomeStatTile(
                value: stats.wpm,
                label: "WPM",
                systemImage: "speedometer",
                tint: MuesliTheme.success
            )
            DictationHomeStatTile(
                value: stats.meetings,
                label: "meetings",
                systemImage: "person.2",
                tint: MuesliTheme.accent
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Stats: \(stats.streak) day streak, \(stats.words) words, \(stats.wpm) words per minute, \(stats.meetings) meetings"
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
        #if DEBUG
        if shouldUseMockDictations {
            dashboardStats = DictationDashboardStats(words: "61.0k", wpm: "152", meetings: "135", streak: "3")
            return
        }
        #endif

        let history = displayHistory
        let sessions = coordinator.recordingSessions
        dashboardStats = DictationDashboardStats(
            words: formattedCompactCount(totalDictationWords(in: history)),
            wpm: formattedAverageWPM(history: history, sessions: sessions),
            meetings: formattedCompactCount(totalMeetingCount(in: sessions)),
            streak: "\(currentActivityStreak(history: history, sessions: sessions))"
        )
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
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                        Text("Voice Note")
                            .font(MuesliTheme.title3())
                            .foregroundStyle(MuesliTheme.textPrimary)
                        Text(coordinator.statusText)
                            .font(MuesliTheme.callout())
                            .foregroundStyle(statusColor)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: MuesliTheme.spacing8) {
                        if coordinator.isRecording {
                            Text(formatElapsedTime(coordinator.recordingElapsedTime))
                                .font(MuesliTheme.captionMedium())
                                .monospacedDigit()
                                .foregroundStyle(statusColor)
                                .padding(.horizontal, MuesliTheme.spacing8)
                                .padding(.vertical, MuesliTheme.spacing4)
                                .background(statusColor.opacity(0.13))
                                .clipShape(Capsule())
                                .accessibilityLabel("Recording elapsed time")
                                .accessibilityValue(formatElapsedTime(coordinator.recordingElapsedTime))
                        }

                        microphoneMenu
                            .disabled(coordinator.isRecording)
                    }
                }

                if isWaveformActive {
                    VStack(spacing: MuesliTheme.spacing8) {
                        MuesliInlineWaveformView(
                            mode: isListeningWaveformActive ? .level : .waiting,
                            color: statusColor,
                            level: waveformLevel,
                            barCount: 24
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .padding(.horizontal, MuesliTheme.spacing16)

                        Text(isListeningWaveformActive ? "Listening" : "Transcribing")
                            .font(MuesliTheme.captionMedium())
                            .foregroundStyle(MuesliTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, MuesliTheme.spacing16)
                    .muesliGlassSurface(cornerRadius: MuesliTheme.cornerMedium, tint: statusColor)
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
                    .muesliGlassSurface(cornerRadius: MuesliTheme.cornerMedium, tint: MuesliTheme.accent)
                }

                VStack(spacing: MuesliTheme.spacing8) {
                    Button {
                        coordinator.toggleRecording()
                    } label: {
                        VoiceNoteRecordButtonLabel(
                            title: dictationButtonTitle,
                            systemImage: dictationButtonIcon,
                            color: statusColor,
                            isStopState: coordinator.isRecording,
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

                    if coordinator.isRecording {
                        Button(role: .destructive) {
                            coordinator.cancelActiveRecording()
                        } label: {
                            Label("Cancel Recording", systemImage: "xmark")
                                .font(MuesliTheme.captionMedium())
                                .foregroundStyle(MuesliTheme.destructive)
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: 44)
                                .background(MuesliTheme.destructiveSubtle)
                                .clipShape(Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("dictation.cancelButton")
                    }
                }
                .padding(.top, isWaveformActive || shouldShowRealtimeTranscript ? 0 : MuesliTheme.spacing4)

                if shouldShowKeyboardSetupRow && !shouldHideKeyboardSetupRowForMockPreview {
                    keyboardShortcutRow
                }
            }
            .padding(MuesliTheme.spacing16)
        }
        .accessibilityIdentifier("dictation.recorderPanel")
        .task {
            await runPreviewWaveformIfNeeded()
        }
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
                Text(coordinator.audioInputRouteText)
                    .lineLimit(1)
            }
            .font(MuesliTheme.captionMedium())
            .foregroundStyle(MuesliTheme.textSecondary)
            .padding(.horizontal, MuesliTheme.spacing8)
            .frame(minHeight: 32)
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
    private var historyHeader: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    Text("Recent Voice Notes")
                        .font(MuesliTheme.title3())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text("\(displayHistory.count) saved")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                }

                Spacer()

                ICloudSyncStatusButton(
                    isEnabled: iCloudSyncEnabled,
                    isSyncing: coordinator.isICloudSyncInProgress,
                    hasError: syncStatusIsError,
                    action: triggerHomeSync
                )

                if let status = coordinator.clipboardStatusText {
                    Label(status, systemImage: "checkmark")
                        .font(MuesliTheme.captionMedium())
                        .foregroundStyle(MuesliTheme.success)
                }
            }

            if !displayHistory.isEmpty {
                DictationSourceFilterPicker(selection: $sourceFilter)
            }
        }
    }

    @ViewBuilder
    private var historyRows: some View {
        Group {
            if filteredHistory.isEmpty {
                emptyHistory
            } else {
                LazyVStack(spacing: MuesliTheme.spacing12) {
                    ForEach(filteredHistory) { result in
                        let session = coordinator.recordingSession(for: result)
                        let hasRetainedAudio = session?.keepsAudioRecording == true && coordinator.audioFileURL(for: result) != nil
                        if hasRetainedAudio {
                            NavigationLink(value: result.id) {
                                DictationHistoryRow(
                                    result: result,
                                    hasRetainedAudio: true,
                                    onCopy: { coordinator.copyToClipboard(result) },
                                    onDelete: { coordinator.deleteDictation(result) }
                                )
                            }
                            .buttonStyle(.plain)
                        } else {
                            DictationHistoryRow(
                                result: result,
                                hasRetainedAudio: false,
                                onCopy: { coordinator.copyToClipboard(result) },
                                onDelete: { coordinator.deleteDictation(result) }
                            )
                        }
                    }
                }
            }
        }
    }

    private var filteredHistory: [DictationResult] {
        displayHistory.filter { sourceFilter.includes($0.syncOrigin) }
    }

    private var displayHistory: [DictationResult] {
        #if DEBUG
        if shouldUseMockDictations {
            return Self.mockDictationHistory
        }
        #endif

        return coordinator.dictationHistory
    }

    private var shouldUseMockDictations: Bool {
        Self.hasDebugSimulatorLaunchArgument("--muesli-mock-dictations")
    }

    private var isPreviewWaveformActive: Bool {
        Self.hasDebugSimulatorLaunchArgument("--muesli-preview-waveform")
    }

    private var waveformLevel: Double? {
        if isPreviewWaveformActive {
            return previewInputLevel
        }
        return coordinator.isRecording ? coordinator.inputLevel : nil
    }

    private var shouldHideKeyboardSetupRowForMockPreview: Bool {
        shouldUseMockDictations
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

    private var shouldShowRealtimeTranscript: Bool {
        coordinator.selectedTranscriptionModel.supportsRealtimeStreaming
            && isWaveformActive
            && !coordinator.liveDictationTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isDictationButtonDisabled: Bool {
        isTranscribing
    }

    private var syncStatusIsError: Bool {
        coordinator.iCloudSyncStatusText?.localizedCaseInsensitiveContains("sync failed") == true
    }

    private var dictationButtonTitle: String {
        if coordinator.isRecording {
            "Stop Recording"
        } else if isTranscribing {
            "Transcribing"
        } else {
            "Start Voice Note"
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

    private func formatElapsedTime(_ time: TimeInterval) -> String {
        guard time.isFinite, time > 0 else { return "0:00" }
        let totalSeconds = Int(time.rounded(.down))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func runPreviewWaveformIfNeeded() async {
        guard isPreviewWaveformActive else { return }

        var tick = 0.0
        while !Task.isCancelled {
            let phrase = (sin(tick * 0.82) + 1) * 0.28
            let syllable = (sin(tick * 2.7) + 1) * 0.18
            let transient = (sin(tick * 7.1) + 1) * 0.08
            if sin(tick * 0.31) > 0.72 {
                previewInputLevel = 0.02
            } else {
                previewInputLevel = min(0.95, max(0.02, 0.08 + phrase + syllable + transient))
            }
            tick += 0.18
            try? await Task.sleep(for: .milliseconds(55))
        }
    }

    private static func hasDebugSimulatorLaunchArgument(_ argument: String) -> Bool {
        #if DEBUG && targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains(argument)
        #else
        false
        #endif
    }

    #if DEBUG
    private static let mockDictationHistory: [DictationResult] = {
        let calendar = Calendar.current
        let baseDate = calendar.date(from: DateComponents(year: 2026, month: 6, day: 30, hour: 13, minute: 30)) ?? .now
        let samples: [(String, String?)] = [
            ("Is this the best animation and UI that we could come up with", "ios"),
            ("The capture screen should feel like a local first console, fast enough to open and start speaking without thinking about folders or setup.", "ios"),
            ("Currently bleeding talent to the inference giants", "macOS"),
            ("We should test the magnified top note while scrolling because this is the exact state people will read after recording a quick thought.", "ios"),
            ("The Mac companion app can stay focused on longer workflows while the phone stays optimized for immediate capture.", "macOS"),
            ("Meeting notes need the same private sync language, but the voice note screen should remain lighter and faster.", "ios"),
            ("If a note is imported from the Mac, keep the provenance visible but do not let the chip overpower the transcript.", "macOS"),
            ("The tab bar should feel stable and tappable, with blue as the active state and green reserved for sync confidence.", "ios"),
            ("Keep the interface blue black white and green so the product feels consistent across phone and Mac.", "ios"),
            ("When the top card grows, the surrounding cards should stay quiet so the reading focus feels intentional rather than busy.", "macOS")
        ]

        return samples.enumerated().map { index, sample in
            DictationResult(
                requestID: UUID(),
                text: sample.0,
                createdAt: calendar.date(byAdding: .minute, value: -index * 47, to: baseDate) ?? baseDate,
                engineIdentifier: sample.1 == "macOS" ? "icloud" : "parakeet",
                source: sample.1
            )
        }
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
        VStack(spacing: MuesliTheme.spacing8) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(height: 20)

            VStack(spacing: 1) {
                Text(value)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
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
        .frame(height: 76)
        .padding(.horizontal, MuesliTheme.spacing8)
        .background {
            RoundedRectangle(cornerRadius: MuesliTheme.cornerLarge, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            MuesliTheme.backgroundRaised.opacity(0.88),
                            MuesliTheme.backgroundDeep.opacity(0.76)
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
        .shadow(color: MuesliTheme.accent.opacity(0.10), radius: 12, x: 0, y: 7)
        .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value) \(label)")
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
                    .frame(width: 96, height: 96)
                    .blur(radius: 0.5)

                Circle()
                    .fill(outerRingFill)
                    .frame(width: 88, height: 88)
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
                    .frame(width: 74, height: 74)
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
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(iconColor)
            }

            Text(title)
                .font(MuesliTheme.headline())
                .foregroundStyle(titleColor)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 112)
        .contentShape(Rectangle())
    }

    private var outerRingFill: Color {
        if isDisabled {
            return MuesliTheme.surfacePrimary.opacity(0.72)
        }
        if isStopState {
            return MuesliTheme.destructive.opacity(0.20)
        }
        return color.opacity(0.18)
    }

    private var outerRingBorder: Color {
        if isDisabled {
            return MuesliTheme.surfaceBorder
        }
        if isStopState {
            return MuesliTheme.destructive.opacity(0.42)
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
                MuesliTheme.destructive.opacity(0.88),
                MuesliTheme.destructive.opacity(0.52)
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
            MuesliTheme.destructive.opacity(0.38)
        } else {
            color.opacity(0.36)
        }
    }

    private var outerShadow: Color {
        if isDisabled {
            return .clear
        }
        if isStopState {
            return MuesliTheme.destructive.opacity(0.16)
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
            MuesliTheme.destructive
        } else {
            MuesliTheme.textPrimary
        }
    }
}

private struct ICloudSyncStatusButton: View {
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
    @State private var rotationDegrees = 0.0

    var body: some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .rotationEffect(.degrees(rotationDegrees))
            .onAppear {
                updateRotation(animated: false)
            }
            .onChange(of: isAnimating) { _, _ in
                updateRotation(animated: true)
            }
    }

    private func updateRotation(animated: Bool) {
        guard isAnimating else {
            if animated {
                withAnimation(.easeOut(duration: 0.15)) {
                    rotationDegrees = 0
                }
            } else {
                rotationDegrees = 0
            }
            return
        }

        rotationDegrees = 0
        withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
            rotationDegrees = 360
        }
    }
}

private enum DictationSourceFilter: String, CaseIterable, Identifiable {
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

    func includes(_ origin: DictationSyncOrigin) -> Bool {
        switch self {
        case .all:
            true
        case .thisIPhone:
            origin == .thisIPhone
        case .fromMac:
            origin == .fromMac
        }
    }
}

private enum DictationSyncOrigin: Equatable {
    case thisIPhone
    case fromMac

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

private extension DictationResult {
    var syncOrigin: DictationSyncOrigin {
        let normalizedSource = source?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let normalizedSource, normalizedSource == "ios" {
            return .thisIPhone
        }

        if let normalizedSource, !normalizedSource.isEmpty {
            return .fromMac
        }

        // Older synced rows were stored before source was persisted and used
        // the fallback engine label. Treat those as Mac-origin cloud imports.
        if normalizedSource == nil && engineIdentifier.lowercased() == "icloud" {
            return .fromMac
        }

        return .thisIPhone
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
    let hasRetainedAudio: Bool
    let onCopy: () -> Void
    let onDelete: () -> Void
    @State private var isConfirmingDelete = false

    var body: some View {
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

                if hasRetainedAudio {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(MuesliTheme.accent)
                        .accessibilityHidden(true)
                }

                DictationOriginChip(origin: origin)
            }

            Text(result.text)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(MuesliTheme.textPrimary)
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var origin: DictationSyncOrigin {
        result.syncOrigin
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
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
    let origin: DictationSyncOrigin

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
