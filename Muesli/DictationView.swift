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
    @State private var sourceFilter: DictationSourceFilter = .all
    @State private var isSyncSetupPromptPresented = false
    @State private var shouldShowKeyboardSetupRow = false

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
            .refreshable {
                triggerHomeSync()
            }
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
                refreshKeyboardSetupPromptVisibility()
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                refreshKeyboardSetupPromptVisibility()
            }
            .navigationDestination(for: UUID.self) { resultID in
                if let result = coordinator.dictationHistory.first(where: { $0.id == resultID }),
                   let session = coordinator.recordingSession(for: result),
                   let audioURL = coordinator.audioFileURL(for: result) {
                    DictationAudioDetailView(result: result, session: session, audioURL: audioURL) {
                        coordinator.copyToClipboard(result)
                    }
                } else {
                    DictationAudioMissingView()
                }
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

            Text("Local-first voice notes for iOS")
                .font(MuesliTheme.callout())
                .foregroundStyle(MuesliTheme.textSecondary)
        }
    }

    private var recorderPanel: some View {
        MuesliSurface(cornerRadius: MuesliTheme.cornerLarge) {
            VStack(spacing: MuesliTheme.spacing20) {
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
                    VoiceNoteRecordButtonLabel(
                        title: dictationButtonTitle,
                        systemImage: dictationButtonIcon,
                        color: statusColor,
                        isDisabled: isDictationButtonDisabled
                    )
                }
                .buttonStyle(.plain)
                .disabled(isDictationButtonDisabled)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(dictationButtonTitle)
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("dictation.primaryButton")

                if shouldShowKeyboardSetupRow {
                    keyboardShortcutRow
                }
            }
            .padding()
        }
        .accessibilityIdentifier("dictation.recorderPanel")
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
        .background(MuesliTheme.surfacePrimary.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
    }

    @ViewBuilder
    private var historySection: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    Text("Recent Voice Notes")
                        .font(MuesliTheme.title3())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text("\(coordinator.dictationHistory.count) saved")
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

            if !coordinator.dictationHistory.isEmpty {
                DictationSourceFilterPicker(selection: $sourceFilter)
            }

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
        coordinator.dictationHistory.filter { sourceFilter.includes($0.syncOrigin) }
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
        coordinator.dictationHistory.isEmpty ? "No voice notes yet" : "No \(sourceFilter.title.lowercased()) voice notes"
    }

    private var emptyHistoryDetail: String {
        if coordinator.dictationHistory.isEmpty {
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
}

private struct VoiceNoteRecordButtonLabel: View {
    let title: String
    let systemImage: String
    let color: Color
    let isDisabled: Bool

    var body: some View {
        VStack(spacing: MuesliTheme.spacing8) {
            ZStack {
                Circle()
                    .fill(isDisabled ? MuesliTheme.surfacePrimary : color)
                    .frame(width: 86, height: 86)
                    .overlay(
                        Circle()
                            .strokeBorder((isDisabled ? MuesliTheme.surfaceBorder : color.opacity(0.36)), lineWidth: 1)
                    )

                Image(systemName: systemImage)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(isDisabled ? MuesliTheme.textTertiary : .white)
            }

            Text(title)
                .font(MuesliTheme.headline())
                .foregroundStyle(isDisabled ? MuesliTheme.textTertiary : MuesliTheme.textPrimary)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
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
            .frame(width: 38, height: 38)
            .background(tint.opacity(isEnabled || hasError ? 0.14 : 0.08))
            .clipShape(Circle())
            .overlay(
                Circle()
                    .strokeBorder(tint.opacity(isEnabled || hasError ? 0.28 : 0.14), lineWidth: 1)
            )
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
            Color(hex: 0x2DD4BF)
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
                        .background(selection == filter ? MuesliTheme.surfaceSelected : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show \(filter.title.lowercased()) voice notes")
            }
        }
        .padding(3)
        .background(MuesliTheme.surfacePrimary.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
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
                .font(MuesliTheme.body())
                .foregroundStyle(MuesliTheme.textPrimary)
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

    @State private var filesExportStatus: String?
    @State private var isFilesExporterPresented = false
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
