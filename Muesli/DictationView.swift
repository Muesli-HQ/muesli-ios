import SwiftUI

struct DictationView: View {
    @Bindable var coordinator: DictationCoordinator
    @AppStorage(MuesliPreferences.iCloudSyncEnabledKey) private var iCloudSyncEnabled = false
    @State private var sourceFilter: DictationSourceFilter = .all

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

                Spacer(minLength: MuesliTheme.spacing12)

                ICloudSyncHeaderButton(
                    isEnabled: iCloudSyncEnabled,
                    isSyncing: coordinator.isICloudSyncInProgress,
                    hasError: syncStatusIsError,
                    action: handleHeaderSyncTap
                )
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

            if !coordinator.dictationHistory.isEmpty {
                DictationSourceFilterPicker(selection: $sourceFilter)
            }

            if filteredHistory.isEmpty {
                emptyHistory
            } else {
                LazyVStack(spacing: MuesliTheme.spacing12) {
                    ForEach(filteredHistory) { result in
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
        coordinator.dictationHistory.isEmpty ? "No dictations yet" : "No \(sourceFilter.title.lowercased()) dictations"
    }

    private var emptyHistoryDetail: String {
        if coordinator.dictationHistory.isEmpty {
            return "Recorded dictations from the app will appear here as a timeline."
        }
        return "Switch filters to see the complete dictation history."
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

    private func handleHeaderSyncTap() {
        if !iCloudSyncEnabled {
            iCloudSyncEnabled = true
        }
        coordinator.syncICloudTextIfEnabled(reason: "home_manual")
    }
}

private struct ICloudSyncHeaderButton: View {
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
                    .font(.system(size: 23, weight: .semibold))
                RotatingSyncGlyph(isAnimating: isSyncing)
                    .font(.system(size: 11, weight: .bold))
                    .offset(y: 1)
                    .opacity(hasError ? 0 : 1)
            }
            .foregroundStyle(tint)
            .frame(width: 44, height: 44)
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
                .accessibilityLabel("Show \(filter.title.lowercased()) dictations")
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
