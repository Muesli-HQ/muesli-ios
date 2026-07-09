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
}

enum VoiceNoteLifecycleReducer {
    static func reduce(_ state: VoiceNoteLifecycleState, event: VoiceNoteLifecycleEvent) -> VoiceNoteLifecycleState {
        switch event {
        case .recordingStarted(let id):
            guard state.activeSessionID == nil || state.activeSessionID == id else { return state }
            return VoiceNoteLifecycleState(phase: .recordingShort(id))
        case .longFormActivated(let id):
            guard state.activeSessionID == id else { return state }
            return VoiceNoteLifecycleState(phase: .recordingLongProtected(id))
        case .stopRequested(let id):
            guard state.activeSessionID == id else { return state }
            return VoiceNoteLifecycleState(phase: .stopping(id))
        case .audioFinalized(let id):
            guard state.activeSessionID == id else { return state }
            return VoiceNoteLifecycleState(phase: .audioSaved(id))
        case .transcriptionQueued(let id):
            guard state.activeSessionID == nil || state.activeSessionID == id else { return state }
            return VoiceNoteLifecycleState(phase: .transcriptionQueued(id))
        case .transcriptionStarted(let id):
            guard state.activeSessionID == nil || state.activeSessionID == id else { return state }
            return VoiceNoteLifecycleState(phase: .transcribing(id))
        case .transcriptionFailed(let id):
            guard state.activeSessionID == id else { return state }
            return VoiceNoteLifecycleState(phase: .failedRetryable(id))
        case .retryRequested(let id):
            guard state.activeSessionID == nil || state.activeSessionID == id else { return state }
            return VoiceNoteLifecycleState(phase: .transcriptionQueued(id))
        case .cancelRequested(let id):
            guard state.activeSessionID == nil || state.activeSessionID == id else { return state }
            return VoiceNoteLifecycleState(phase: .cancelling(id))
        case .finished(let id):
            guard state.activeSessionID == id else { return state }
            return VoiceNoteLifecycleState()
        }
    }
}

struct VoiceNoteLifecycleRunner {
    let sessionID: UUID
    var checkpointTask: Task<Void, Never>?
    var thresholdTask: Task<Void, Never>?
    var transcriptionTask: Task<Void, Never>?

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
