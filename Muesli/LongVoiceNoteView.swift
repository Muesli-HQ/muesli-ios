import SwiftUI

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
        VStack(spacing: MuesliTheme.spacing12) {
            VoiceNoteWaveformLeaf(
                liveState: coordinator.voiceNoteLiveState,
                mode: .level,
                color: MuesliTheme.accent,
                isActive: true,
                barCount: 44
            )
            .frame(height: 96)
        }
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
