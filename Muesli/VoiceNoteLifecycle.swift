import Foundation

struct VoiceNoteLifecycleState: Equatable {
    enum Phase: Equatable {
        case idle
        case recordingShort(UUID)
        case recordingLongProtected(UUID)
        case stopping(UUID)
        case audioSaved(UUID)
        case transcriptionQueued(UUID)
        case transcribing(UUID)
        case failedRetryable(UUID)
        case cancelling(UUID)

        var telemetryName: String {
            switch self {
            case .idle: "idle"
            case .recordingShort: "recording_short"
            case .recordingLongProtected: "recording_long_protected"
            case .stopping: "stopping"
            case .audioSaved: "audio_saved"
            case .transcriptionQueued: "transcription_queued"
            case .transcribing: "transcribing"
            case .failedRetryable: "failed_retryable"
            case .cancelling: "cancelling"
            }
        }
    }

    var phase: Phase = .idle

    var activeSessionID: UUID? {
        switch phase {
        case .idle:
            nil
        case .recordingShort(let id), .recordingLongProtected(let id), .stopping(let id),
             .audioSaved(let id), .transcriptionQueued(let id), .transcribing(let id),
             .failedRetryable(let id), .cancelling(let id):
            id
        }
    }

    var isRecording: Bool {
        switch phase {
        case .recordingShort, .recordingLongProtected, .stopping:
            true
        case .idle, .audioSaved, .transcriptionQueued, .transcribing, .failedRetryable, .cancelling:
            false
        }
    }

    var isLongFormVisible: Bool {
        switch phase {
        case .recordingLongProtected, .stopping, .audioSaved, .transcriptionQueued,
             .transcribing, .failedRetryable:
            true
        case .idle, .recordingShort, .cancelling:
            false
        }
    }

    var isWorkActive: Bool {
        switch phase {
        case .recordingShort, .recordingLongProtected, .stopping, .audioSaved,
             .transcriptionQueued, .transcribing, .cancelling:
            true
        case .idle, .failedRetryable:
            false
        }
    }
}

enum VoiceNoteLifecycleEvent {
    case recordingStarted(UUID)
    case longFormActivated(UUID)
    case stopRequested(UUID)
    case audioFinalized(UUID)
    case transcriptionQueued(UUID)
    case transcriptionStarted(UUID)
    case transcriptionFailed(UUID)
    case retryRequested(UUID)
    case cancelRequested(UUID)
    case finished(UUID)

    var telemetryName: String {
        switch self {
        case .recordingStarted: "recording_started"
        case .longFormActivated: "long_form_activated"
        case .stopRequested: "stop_requested"
        case .audioFinalized: "audio_finalized"
        case .transcriptionQueued: "transcription_queued"
        case .transcriptionStarted: "transcription_started"
        case .transcriptionFailed: "transcription_failed"
        case .retryRequested: "retry_requested"
        case .cancelRequested: "cancel_requested"
        case .finished: "finished"
        }
    }
}

struct VoiceNoteLifecycleTransition: Equatable {
    let state: VoiceNoteLifecycleState
    let accepted: Bool
}

enum VoiceNoteLifecycleReducer {
    static func transition(
        _ state: VoiceNoteLifecycleState,
        event: VoiceNoteLifecycleEvent
    ) -> VoiceNoteLifecycleTransition {
        let nextState: VoiceNoteLifecycleState?
        switch (state.phase, event) {
        case (.idle, .recordingStarted(let id)):
            nextState = VoiceNoteLifecycleState(phase: .recordingShort(id))
        case (.failedRetryable, .recordingStarted(let id)):
            nextState = VoiceNoteLifecycleState(phase: .recordingShort(id))
        case (.recordingShort(let activeID), .recordingStarted(let id)) where activeID == id:
            nextState = state
        case (.recordingShort(let activeID), .longFormActivated(let id)) where activeID == id:
            nextState = VoiceNoteLifecycleState(phase: .recordingLongProtected(id))
        case (.recordingShort(let activeID), .stopRequested(let id)) where activeID == id:
            nextState = VoiceNoteLifecycleState(phase: .stopping(id))
        case (.recordingLongProtected(let activeID), .stopRequested(let id)) where activeID == id:
            nextState = VoiceNoteLifecycleState(phase: .stopping(id))
        case (.stopping(let activeID), .audioFinalized(let id)) where activeID == id:
            nextState = VoiceNoteLifecycleState(phase: .audioSaved(id))
        case (.audioSaved(let activeID), .transcriptionQueued(let id)) where activeID == id:
            nextState = VoiceNoteLifecycleState(phase: .transcriptionQueued(id))
        case (.stopping(let activeID), .transcriptionStarted(let id)) where activeID == id:
            nextState = VoiceNoteLifecycleState(phase: .transcribing(id))
        case (.audioSaved(let activeID), .transcriptionStarted(let id)) where activeID == id:
            nextState = VoiceNoteLifecycleState(phase: .transcribing(id))
        case (.transcriptionQueued(let activeID), .transcriptionStarted(let id)) where activeID == id:
            nextState = VoiceNoteLifecycleState(phase: .transcribing(id))
        case (.stopping(let activeID), .transcriptionFailed(let id)) where activeID == id:
            nextState = VoiceNoteLifecycleState(phase: .failedRetryable(id))
        case (.audioSaved(let activeID), .transcriptionFailed(let id)) where activeID == id:
            nextState = VoiceNoteLifecycleState(phase: .failedRetryable(id))
        case (.transcriptionQueued(let activeID), .transcriptionFailed(let id)) where activeID == id:
            nextState = VoiceNoteLifecycleState(phase: .failedRetryable(id))
        case (.transcribing(let activeID), .transcriptionFailed(let id)) where activeID == id:
            nextState = VoiceNoteLifecycleState(phase: .failedRetryable(id))
        case (.idle, .retryRequested(let id)):
            nextState = VoiceNoteLifecycleState(phase: .transcriptionQueued(id))
        case (.failedRetryable(let activeID), .retryRequested(let id)) where activeID == id:
            nextState = VoiceNoteLifecycleState(phase: .transcriptionQueued(id))
        case (.recordingShort(let activeID), .cancelRequested(let id)) where activeID == id:
            nextState = VoiceNoteLifecycleState(phase: .cancelling(id))
        case (.recordingLongProtected(let activeID), .cancelRequested(let id)) where activeID == id:
            nextState = VoiceNoteLifecycleState(phase: .cancelling(id))
        case (.stopping(let activeID), .cancelRequested(let id)) where activeID == id:
            nextState = VoiceNoteLifecycleState(phase: .cancelling(id))
        case (_, .finished(let id)) where state.activeSessionID == id:
            nextState = VoiceNoteLifecycleState()
        default:
            nextState = nil
        }

        guard let nextState else {
            return VoiceNoteLifecycleTransition(state: state, accepted: false)
        }
        return VoiceNoteLifecycleTransition(state: nextState, accepted: true)
    }

    static func reduce(
        _ state: VoiceNoteLifecycleState,
        event: VoiceNoteLifecycleEvent
    ) -> VoiceNoteLifecycleState {
        transition(state, event: event).state
    }
}

struct VoiceNoteRequestOwnership: Equatable {
    let requestID: UUID?
    let isWorkActive: Bool

    func accepts(requestID incomingRequestID: UUID) -> Bool {
        guard isWorkActive else { return true }
        guard let requestID else { return false }
        return requestID == incomingRequestID
    }
}

struct VoiceNoteLifecycleRunner {
    let id: UUID
    let sessionID: UUID
    let requestID: UUID
    var checkpointTask: Task<Void, Never>?
    var thresholdTask: Task<Void, Never>?
    var transcriptionTask: Task<Void, Never>?

    init(id: UUID = UUID(), sessionID: UUID, requestID: UUID) {
        self.id = id
        self.sessionID = sessionID
        self.requestID = requestID
    }

    mutating func cancelAll() {
        checkpointTask?.cancel()
        thresholdTask?.cancel()
        transcriptionTask?.cancel()
        checkpointTask = nil
        thresholdTask = nil
        transcriptionTask = nil
    }
}

enum VoiceNoteAudioRetentionPolicy {
    static func shouldDeleteAudioAfterFailure(_ session: RecordingSession) -> Bool {
        !session.protectedAudioUntilTranscriptCompletes && !session.keepsAudioRecording
    }

    static func shouldDeleteAudioAfterSuccess(_ session: RecordingSession) -> Bool {
        !session.keepsAudioRecording
    }
}

enum VoiceNoteFailureLifecycleDisposition: Equatable {
    case retryable
    case finished

    static func resolve(for session: RecordingSession) -> VoiceNoteFailureLifecycleDisposition {
        session.isLongForm ? .retryable : .finished
    }
}

enum VoiceNoteRecordingTerminationCause: Equatable {
    case interrupted
    case checkpointFailure

    var failureReason: VoiceNoteTranscriptionFailureReason {
        switch self {
        case .interrupted: .interrupted
        case .checkpointFailure: .checkpointFailure
        }
    }
}

enum VoiceNoteFailureSessionPolicy {
    static func prepare(
        _ session: RecordingSession,
        reason: VoiceNoteTranscriptionFailureReason,
        message: String,
        hasRecoverableAudio: Bool
    ) -> RecordingSession {
        var failedSession = session
        failedSession.phase = .failed
        failedSession.errorMessage = message
        failedSession.lastTranscriptionFailureReason = reason
        failedSession.protectedAudioUntilTranscriptCompletes = session.isLongForm
            && hasRecoverableAudio
        return failedSession
    }
}

enum VoiceNoteCheckpointRetentionPolicy {
    static func shouldDeleteCheckpoints(for session: RecordingSession?) -> Bool {
        guard let session else { return true }
        guard session.kind != .meeting else { return false }
        if session.phase == .completed || session.phase == .cancelled {
            return true
        }
        if session.protectedAudioUntilTranscriptCompletes,
           session.audioFileName != nil {
            return false
        }
        if !session.isLongForm {
            return ![.recording, .transcriptionQueued, .transcribing].contains(session.phase)
        }
        return session.audioFileName == nil
            && !session.protectedAudioUntilTranscriptCompletes
    }
}
