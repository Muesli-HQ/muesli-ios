import SwiftUI

enum NotepadDocumentComposer {
    static func appending(segment: String, to document: String) -> String {
        let segment = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !segment.isEmpty else { return document }

        let trimmedDocument = document.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDocument.isEmpty else { return segment }
        guard !trimmedDocument.hasSuffix(segment) else { return document }
        if segment.hasPrefix(trimmedDocument) {
            return segment
        }

        let separator = document.last?.isWhitespace == true ? "" : " "
        return document + separator + segment
    }

    static func title(for document: String, fallbackDate: Date) -> String {
        let firstLine = document
            .split(whereSeparator: \Character.isNewline)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !firstLine.isEmpty {
            let limit = 28
            return firstLine.count > limit
                ? String(firstLine.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
                : firstLine
        }
        return fallbackDate.formatted(.dateTime.day().month(.abbreviated))
    }
}

struct NotepadView: View {
    @Bindable var coordinator: DictationCoordinator
    let sessionID: UUID

    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var isEditorFocused: Bool
    @State private var documentText = ""
    @State private var documentSaveTask: Task<Void, Never>?
    @State private var canonicalSessionID: UUID?
    @State private var pendingReplacementSessionID: UUID?
    @State private var processedSessionIDs = Set<UUID>()
    @State private var isStartingBurst = false
    @State private var isDiscarding = false
    @State private var isDiscardConfirmationPresented = false
    @State private var isDeleteAudioConfirmationPresented = false

    private var session: RecordingSession? {
        coordinator.presentedLongVoiceNoteSession?.id == sessionID
            ? coordinator.presentedLongVoiceNoteSession
            : coordinator.recordingSessions.first(where: { $0.id == sessionID })
    }

    private var isActivelyRecording: Bool {
        coordinator.isRecording && coordinator.activeLongVoiceNoteSession?.id == sessionID
    }

    private var isTranscribing: Bool {
        guard let phase = session?.phase else { return false }
        return phase == .transcriptionQueued || phase == .transcribing
    }

    private var documentTitle: String {
        NotepadDocumentComposer.title(
            for: documentText,
            fallbackDate: session?.createdAt ?? .now
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                topBar
                Divider().overlay(MuesliTheme.surfaceBorder)
                editor
            }
            .background(MuesliTheme.backgroundBase.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                voiceControl
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .interactiveDismissDisabled(isActivelyRecording || isTranscribing)
        .onAppear(perform: configureInitialDocument)
        .onChange(of: documentText) { _, text in
            scheduleDocumentSave(text)
        }
        .onChange(of: sessionID) { _, _ in
            isStartingBurst = false
            coordinator.updateVoiceNoteScratchpad(sessionID: sessionID, text: documentText)
        }
        .onChange(of: session?.phase) { _, phase in
            if phase == .completed {
                handleCompletedSegment()
            }
        }
        .onChange(of: coordinator.isRecording) { _, recording in
            if recording { isStartingBurst = false }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            flushDocument()
        }
        .onDisappear(perform: flushDocument)
        .confirmationDialog(
            "Discard this Notepad?",
            isPresented: $isDiscardConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Discard Notepad", role: .destructive) {
                isDiscarding = true
                documentSaveTask?.cancel()
                documentSaveTask = nil
                var sessionIDs = Set([sessionID])
                if let canonicalSessionID {
                    sessionIDs.insert(canonicalSessionID)
                }
                if let pendingReplacementSessionID {
                    sessionIDs.insert(pendingReplacementSessionID)
                }
                Task {
                    await coordinator.discardNotepad(sessionIDs: sessionIDs)
                }
            }
            Button("Keep Writing", role: .cancel) {}
        } message: {
            Text("The current recording and any text in this Notepad will be deleted.")
        }
        .confirmationDialog(
            "Delete saved audio?",
            isPresented: $isDeleteAudioConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Delete Audio", role: .destructive) {
                coordinator.deleteVoiceNoteAudio(sessionID: sessionID)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your Notepad text will remain, but this audio cannot be recovered.")
        }
    }

    private var topBar: some View {
        ZStack {
            HStack {
                Button(action: closeNotepad) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(MuesliTheme.textPrimary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close Notepad")

                Spacer()

                trailingMenu
            }

            Button {
                isEditorFocused = true
            } label: {
                HStack(spacing: MuesliTheme.spacing8) {
                    Text(documentTitle)
                        .font(MuesliTheme.headline())
                        .foregroundStyle(MuesliTheme.textPrimary)
                        .lineLimit(1)
                    Image(systemName: "pencil")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(MuesliTheme.textSecondary)
                }
                .padding(.horizontal, MuesliTheme.spacing8)
                .frame(maxWidth: 230, minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit Notepad")
        }
        .padding(.horizontal, MuesliTheme.spacing12)
        .padding(.vertical, MuesliTheme.spacing8)
        .background(MuesliTheme.backgroundBase)
    }

    @ViewBuilder
    private var trailingMenu: some View {
        if !documentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || session?.audioFileName != nil
            || session?.phase == .failed
            || isActivelyRecording {
            Menu {
                if session?.phase == .failed,
                   session?.canRetryVoiceNoteTranscription == true {
                    Button("Retry Dictation", systemImage: "arrow.clockwise") {
                        coordinator.retryVoiceNoteTranscription(sessionID: sessionID)
                    }
                }

                if session?.audioFileName != nil {
                    Button("Keep Saved Audio", systemImage: "pin") {
                        coordinator.keepVoiceNoteAudio(sessionID: sessionID)
                    }
                    Button("Delete Saved Audio", systemImage: "trash", role: .destructive) {
                        isDeleteAudioConfirmationPresented = true
                    }
                }

                if isActivelyRecording {
                    Button("Discard Notepad", systemImage: "trash", role: .destructive) {
                        isDiscardConfirmationPresented = true
                    }
                }
            } label: {
                Image(systemName: "book.closed")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(MuesliTheme.textPrimary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Notepad options")
        } else {
            Color.clear.frame(width: 44, height: 44)
        }
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $documentText)
                .focused($isEditorFocused)
                .font(.system(size: 20, weight: .regular, design: .default))
                .foregroundStyle(MuesliTheme.textPrimary)
                .lineSpacing(5)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, MuesliTheme.spacing16)
                .padding(.top, MuesliTheme.spacing20)
                .padding(.bottom, 92)
                .accessibilityLabel("Notepad text")
                .accessibilityIdentifier("notepad.editor")

            if documentText.isEmpty {
                Text("Tap the mic to start taking a note with Muesli")
                    .font(.system(size: 20, weight: .regular, design: .default))
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .padding(.horizontal, MuesliTheme.spacing20)
                    .padding(.top, 28)
                    .allowsHitTesting(false)
            }

            if session?.phase == .failed {
                failureBanner
                    .padding(.horizontal, MuesliTheme.spacing20)
                    .padding(.top, MuesliTheme.spacing8)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { isEditorFocused = true }
    }

    private var failureBanner: some View {
        HStack(spacing: MuesliTheme.spacing12) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(MuesliTheme.destructive)
            VStack(alignment: .leading, spacing: 2) {
                Text("Dictation wasn’t added")
                    .font(MuesliTheme.captionMedium())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Text(session?.errorMessage ?? "Your existing text is safe.")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: MuesliTheme.spacing8)
            if session?.canRetryVoiceNoteTranscription == true {
                Button("Retry") {
                    coordinator.retryVoiceNoteTranscription(sessionID: sessionID)
                }
                .font(MuesliTheme.captionMedium())
            }
        }
        .padding(MuesliTheme.spacing12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall, style: .continuous)
                .strokeBorder(MuesliTheme.destructive.opacity(0.28), lineWidth: 1)
        }
    }

    private var voiceControl: some View {
        Group {
            if isActivelyRecording {
                HStack {
                    Spacer()
                    activeVoicePill
                    Spacer()
                }
            } else {
                HStack {
                    Spacer()

                    if isTranscribing || isStartingBurst {
                        processingPill
                    } else {
                        microphoneButton
                    }

                    Spacer()
                }
            }
        }
        .padding(.horizontal, MuesliTheme.spacing20)
        .padding(.vertical, MuesliTheme.spacing12)
    }

    private var microphoneButton: some View {
        Button(action: beginDictationBurst) {
            Image(systemName: "mic.fill")
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 68, height: 68)
                .background(MuesliTheme.accent, in: Circle())
                .overlay {
                    Circle().strokeBorder(.white.opacity(0.2), lineWidth: 1)
                }
                .shadow(color: MuesliTheme.accent.opacity(0.32), radius: 18, x: 0, y: 8)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Start dictation")
        .accessibilityHint("Adds the next spoken passage to this Notepad")
        .accessibilityIdentifier("notepad.microphoneButton")
    }

    private var activeVoicePill: some View {
        HStack(spacing: MuesliTheme.spacing12) {
            Button(role: .destructive, action: discardDictationBurst) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(MuesliTheme.destructive, in: Circle())
                    .overlay {
                        Circle()
                            .strokeBorder(.white.opacity(0.16), lineWidth: 1)
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Discard current dictation")
            .accessibilityHint("Removes only the passage currently being recorded")
            .accessibilityIdentifier("notepad.discardBurstButton")

            VoiceNoteWaveformLeaf(
                liveState: coordinator.voiceNoteLiveState,
                mode: .level,
                color: .white,
                isActive: true,
                barCount: 28
            )
            .frame(width: 116, height: 30)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Live audio waveform")
            .accessibilityIdentifier("notepad.waveform")

            Button(action: stopDictationBurst) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(MuesliTheme.accent)
                    .frame(width: 42, height: 42)
                    .background(.white, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop dictation")
            .accessibilityHint("Transcribes this passage and keeps the Notepad open")
            .accessibilityIdentifier("notepad.stopButton")
        }
        .padding(.horizontal, MuesliTheme.spacing8)
        .padding(.vertical, MuesliTheme.spacing8)
        .background(MuesliTheme.accent, in: Capsule())
        .shadow(color: MuesliTheme.accent.opacity(0.3), radius: 18, x: 0, y: 8)
    }

    private var processingPill: some View {
        HStack(spacing: 10) {
            ProgressView()
                .tint(.white)
            Text(isStartingBurst ? "Starting…" : "Adding text…")
                .font(MuesliTheme.captionMedium())
                .foregroundStyle(.white)
        }
        .padding(.horizontal, MuesliTheme.spacing16)
        .frame(height: 52)
        .background(MuesliTheme.accent, in: Capsule())
        .shadow(color: MuesliTheme.accent.opacity(0.24), radius: 14, x: 0, y: 7)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isStartingBurst ? "Starting dictation" : "Adding dictated text")
    }

    private func configureInitialDocument() {
        canonicalSessionID = sessionID
        let saved = session?.scratchpadText ?? ""
        if session?.phase == .completed, let transcript = currentTranscript {
            documentText = NotepadDocumentComposer.appending(segment: transcript, to: saved)
            processedSessionIDs.insert(sessionID)
            coordinator.saveNotepadDocument(sessionID: sessionID, text: documentText)
        } else {
            documentText = saved
        }

    }

    private var currentTranscript: String? {
        guard let session else { return nil }
        return coordinator.transcript(for: session)?.text
            ?? coordinator.dictationHistory.first(where: { $0.sessionID == sessionID })?.text
    }

    private func beginDictationBurst() {
        isEditorFocused = false
        flushDocument()
        pendingReplacementSessionID = canonicalSessionID
        isStartingBurst = true
        coordinator.startNotepadRecording(seedText: documentText)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if !coordinator.isRecording && !isTranscribing {
                isStartingBurst = false
            }
        }
    }

    private func stopDictationBurst() {
        flushDocument()
        coordinator.toggleRecording()
    }

    private func discardDictationBurst() {
        flushDocument()
        let discardedSessionID = sessionID
        let restoreSessionID = canonicalSessionID
        pendingReplacementSessionID = nil
        isStartingBurst = false
        coordinator.discardCurrentNotepadBurst(
            sessionID: discardedSessionID,
            restoring: restoreSessionID,
            documentText: documentText
        )
    }

    private func handleCompletedSegment() {
        guard !processedSessionIDs.contains(sessionID),
              let transcript = currentTranscript
        else { return }

        processedSessionIDs.insert(sessionID)
        documentText = NotepadDocumentComposer.appending(segment: transcript, to: documentText)
        coordinator.commitNotepadDocument(
            sessionID: sessionID,
            text: documentText,
            replacing: pendingReplacementSessionID
        )
        canonicalSessionID = sessionID
        pendingReplacementSessionID = nil
        isStartingBurst = false
    }

    private func closeNotepad() {
        if isActivelyRecording {
            isDiscardConfirmationPresented = true
            return
        }
        guard !isTranscribing else { return }
        flushDocument()
        coordinator.finishNotepad(sessionID: sessionID, text: documentText)
    }

    private func scheduleDocumentSave(_ text: String) {
        documentSaveTask?.cancel()
        documentSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, !isDiscarding else { return }
            coordinator.saveNotepadDocument(sessionID: sessionID, text: text)
        }
    }

    private func flushDocument() {
        documentSaveTask?.cancel()
        documentSaveTask = nil
        guard !isDiscarding else { return }
        coordinator.saveNotepadDocument(sessionID: sessionID, text: documentText)
    }
}

struct LongVoiceNoteView: View {
    @Bindable var coordinator: DictationCoordinator
    let sessionID: UUID

    @Environment(\.scenePhase) private var scenePhase
    @State private var scratchpadText = ""
    @State private var scratchpadSaveTask: Task<Void, Never>?
    @State private var isDiscardConfirmationPresented = false
    @State private var isDeleteAudioConfirmationPresented = false

    private var session: RecordingSession? {
        coordinator.presentedLongVoiceNoteSession?.id == sessionID
            ? coordinator.presentedLongVoiceNoteSession
            : coordinator.recordingSessions.first(where: { $0.id == sessionID })
    }

    private var isActivelyRecording: Bool {
        coordinator.isRecording && coordinator.activeLongVoiceNoteSession?.id == sessionID
    }

    var body: some View {
        NavigationStack {
            ZStack {
                MuesliTheme.backgroundBase.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
                        recordingHeader
                        if isActivelyRecording {
                            activeWaveform
                            scratchpadEditor
                        } else {
                            if session?.phase == .failed {
                                failureRecoveryPanel
                            }
                            completedTranscript
                            scratchpadEditor
                            recoveryAudio
                        }
                    }
                    .padding(.horizontal, MuesliTheme.spacing20)
                    .padding(.top, MuesliTheme.spacing12)
                    .padding(.bottom, isActivelyRecording ? 112 : 40)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .safeAreaInset(edge: .bottom) {
                if isActivelyRecording {
                    stopBar
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .interactiveDismissDisabled(isActivelyRecording)
        .onAppear {
            scratchpadText = session?.scratchpadText ?? ""
        }
        .onChange(of: scratchpadText) { _, text in
            scheduleScratchpadSave(text)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            flushScratchpad()
        }
        .onDisappear {
            flushScratchpad()
        }
        .confirmationDialog(
            "Discard this voice note?",
            isPresented: $isDiscardConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Discard Voice Note", role: .destructive) {
                flushScratchpad()
                coordinator.cancelActiveRecording()
                coordinator.dismissLongVoiceNote()
            }
            Button("Keep Recording", role: .cancel) {}
        } message: {
            Text("The recording, saved checkpoints, and scratchpad will be deleted.")
        }
        .confirmationDialog(
            "Delete saved audio?",
            isPresented: $isDeleteAudioConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Delete Audio", role: .destructive) {
                coordinator.deleteVoiceNoteAudio(sessionID: sessionID)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The transcript and scratchpad will remain, but this audio cannot be recovered.")
        }
    }

    private var recordingHeader: some View {
        HStack(alignment: .top, spacing: MuesliTheme.spacing12) {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                Text("Long Voice Note")
                    .font(MuesliTheme.title2())
                    .foregroundStyle(MuesliTheme.textPrimary)

                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                    Text(statusCopy)
                        .font(MuesliTheme.captionMedium())
                        .foregroundStyle(statusColor)
                }

                if isActivelyRecording {
                    LongVoiceNoteElapsedText(liveState: coordinator.voiceNoteLiveState)
                } else {
                    Text(VoiceNoteDurationFormatter.padded(
                        max(Int((session?.duration ?? 0).rounded(.down)), 0)
                    ))
                    .font(.system(.title3, design: .monospaced, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .padding(.top, MuesliTheme.spacing4)
                }
            }

            Spacer()

            MuesliGlassGroup(spacing: MuesliTheme.spacing8) {
                if isActivelyRecording {
                    Button(role: .destructive) {
                        isDiscardConfirmationPresented = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(MuesliTheme.destructive)
                            .frame(width: 44, height: 44)
                            .muesliGlassButton(cornerRadius: 22, tint: MuesliTheme.destructive)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Discard voice note")
                } else {
                    Button("Done") {
                        flushScratchpad()
                        coordinator.dismissLongVoiceNote()
                    }
                    .font(MuesliTheme.headline())
                    .foregroundStyle(MuesliTheme.accent)
                    .frame(minWidth: 64, minHeight: 44)
                    .muesliGlassButton(cornerRadius: 22, tint: MuesliTheme.accent)
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var activeWaveform: some View {
        VoiceNoteWaveformLeaf(
            liveState: coordinator.voiceNoteLiveState,
            mode: .level,
            color: MuesliTheme.accent,
            isActive: true,
            barCount: 44
        )
        .frame(height: 96)
        .padding(MuesliTheme.spacing16)
        .background(MuesliTheme.surfacePrimary)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium, style: .continuous)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Live audio waveform")
    }

    private var scratchpadEditor: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            Label("Scratchpad", systemImage: "square.and.pencil")
                .font(MuesliTheme.headline())
                .foregroundStyle(MuesliTheme.textPrimary)

            TextEditor(text: $scratchpadText)
                .font(MuesliTheme.body())
                .foregroundStyle(MuesliTheme.textPrimary)
                .scrollContentBackground(.hidden)
                .frame(minHeight: isActivelyRecording ? 210 : 130)
                .padding(MuesliTheme.spacing12)
                .background(MuesliTheme.backgroundBase.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if scratchpadText.isEmpty {
                        Text("Add notes while speaking...")
                            .font(MuesliTheme.body())
                            .foregroundStyle(MuesliTheme.textTertiary)
                            .padding(.horizontal, MuesliTheme.spacing16)
                            .padding(.vertical, MuesliTheme.spacing20)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("Voice note scratchpad")
                .accessibilityIdentifier("longVoiceNote.scratchpad")
        }
        .padding(MuesliTheme.spacing16)
        .background(MuesliTheme.surfacePrimary)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium, style: .continuous)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        }
    }

    @ViewBuilder
    private var failureRecoveryPanel: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            Text(session?.canRetryVoiceNoteTranscription == true ? "Transcription failed" : "Recovery unavailable")
                .font(MuesliTheme.headline())
                .foregroundStyle(MuesliTheme.textPrimary)

            if let error = session?.errorMessage {
                Text(error)
                    .font(MuesliTheme.callout())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if session?.canRetryVoiceNoteTranscription != true,
               session?.audioFileName != nil {
                Text("A durable audio checkpoint is not available, so this transcription cannot be retried safely.")
                    .font(MuesliTheme.callout())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            recoveryActions
        }
        .padding(MuesliTheme.spacing16)
        .background(MuesliTheme.surfacePrimary)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium, style: .continuous)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        }
    }

    @ViewBuilder
    private var completedTranscript: some View {
        if session?.phase == .completed,
           let text = coordinator.transcript(for: session ?? fallbackSession)?.text
                ?? coordinator.dictationHistory.first(where: { $0.sessionID == sessionID })?.text,
           !text.isEmpty {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                Label("Transcript", systemImage: "text.alignleft")
                    .font(MuesliTheme.headline())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Text(text)
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(MuesliTheme.spacing16)
            .background(MuesliTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium, style: .continuous)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
            }
        }
    }

    @ViewBuilder
    private var recoveryAudio: some View {
        if let session, let audioURL = coordinator.audioFileURL(for: session) {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                Text("Saved Audio")
                    .font(MuesliTheme.headline())
                    .foregroundStyle(MuesliTheme.textPrimary)
                SavedAudioPlayerView(audioURL: audioURL)
            }
            .padding(MuesliTheme.spacing16)
            .background(MuesliTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium, style: .continuous)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
            }
        }
    }

    private var recoveryActions: some View {
        MuesliGlassGroup(spacing: MuesliTheme.spacing8) {
            VStack(spacing: MuesliTheme.spacing8) {
                if session?.canRetryVoiceNoteTranscription == true {
                    Button {
                        coordinator.retryVoiceNoteTranscription(sessionID: sessionID)
                    } label: {
                        Label("Retry Transcript", systemImage: "arrow.clockwise")
                            .font(MuesliTheme.headline())
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(MuesliTheme.accent)
                            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }

                if session?.audioFileName != nil {
                    HStack(spacing: MuesliTheme.spacing8) {
                        Button {
                            coordinator.keepVoiceNoteAudio(sessionID: sessionID)
                        } label: {
                            Label("Keep Audio", systemImage: "pin")
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .muesliGlassButton(cornerRadius: MuesliTheme.cornerSmall, tint: MuesliTheme.accent)
                        }
                        .buttonStyle(.plain)

                        Button(role: .destructive) {
                            isDeleteAudioConfirmationPresented = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                                .foregroundStyle(MuesliTheme.destructive)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .muesliGlassButton(cornerRadius: MuesliTheme.cornerSmall, tint: MuesliTheme.destructive)
                        }
                        .buttonStyle(.plain)
                    }
                    .font(MuesliTheme.captionMedium())
                } else if session?.canRetryVoiceNoteTranscription != true {
                    Label("Audio unavailable", systemImage: "waveform.slash")
                        .font(MuesliTheme.callout())
                        .foregroundStyle(MuesliTheme.destructive)
                }
            }
        }
    }

    private var stopBar: some View {
        Button {
            flushScratchpad()
            coordinator.toggleRecording()
        } label: {
            Label("Stop Recording", systemImage: "stop.fill")
                .font(MuesliTheme.headline())
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 54)
                .background(MuesliTheme.accent)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, MuesliTheme.spacing20)
        .padding(.vertical, MuesliTheme.spacing12)
        .background(.ultraThinMaterial)
        .accessibilityIdentifier("longVoiceNote.stopButton")
    }

    private var statusCopy: String {
        if let durabilityError = coordinator.longVoiceNoteDurabilityError, isActivelyRecording {
            return durabilityError
        }
        guard let session else { return "Loading voice note" }
        if isActivelyRecording {
            return coordinator.longVoiceNoteAudioIsSecured ? "Audio saved locally" : "Securing audio"
        }
        switch session.phase {
        case .recording: return "Recovered recording"
        case .transcriptionQueued: return "Waiting to transcribe"
        case .transcribing: return "Transcribing"
        case .completed: return "Transcript ready"
        case .failed:
            switch session.voiceNoteDurabilityEvidence {
            case .durableCheckpoint: return "Audio saved locally"
            case .audioReferenceOnly: return "Audio needs recovery"
            case .unavailable: return "Audio unavailable"
            }
        case .cancelled: return "Cancelled"
        }
    }

    private var statusColor: Color {
        if coordinator.longVoiceNoteDurabilityError != nil || session?.phase == .failed {
            return MuesliTheme.destructive
        }
        if session?.phase == .completed || coordinator.longVoiceNoteAudioIsSecured {
            return MuesliTheme.success
        }
        return MuesliTheme.accent
    }

    private var fallbackSession: RecordingSession {
        RecordingSession(id: sessionID, kind: .quickDictation, phase: .failed)
    }

    private func scheduleScratchpadSave(_ text: String) {
        scratchpadSaveTask?.cancel()
        scratchpadSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            coordinator.updateVoiceNoteScratchpad(sessionID: sessionID, text: text)
        }
    }

    private func flushScratchpad() {
        scratchpadSaveTask?.cancel()
        scratchpadSaveTask = nil
        coordinator.updateVoiceNoteScratchpad(sessionID: sessionID, text: scratchpadText)
    }
}
