import Foundation

struct MeetingLifecycleState: Equatable {
    enum Phase: Equatable {
        case idle
        case starting(UUID)
        case recording(UUID)
        case stopping(UUID)
        case transcribing(UUID)
        case cancelling(UUID)

        var telemetryName: String {
            switch self {
            case .idle: "idle"
            case .starting: "starting"
            case .recording: "recording"
            case .stopping: "stopping"
            case .transcribing: "transcribing"
            case .cancelling: "cancelling"
            }
        }
    }

    var phase: Phase = .idle

    var activeSessionID: UUID? {
        switch phase {
        case .idle:
            nil
        case .starting(let id), .recording(let id), .stopping(let id),
             .transcribing(let id), .cancelling(let id):
            id
        }
    }

    var isWorkActive: Bool { activeSessionID != nil }
    var isCancelling: Bool {
        if case .cancelling = phase { true } else { false }
    }
    var isRecording: Bool {
        if case .recording = phase { true } else { false }
    }
    var isTranscribing: Bool {
        if case .transcribing = phase { true } else { false }
    }
    var acceptsCaptureStopRequest: Bool {
        switch phase {
        case .starting, .recording:
            true
        case .idle, .stopping, .transcribing, .cancelling:
            false
        }
    }
    var requiresRecorder: Bool { isRecording }
    var allowsRecorder: Bool {
        switch phase {
        case .recording, .stopping:
            true
        case .idle, .starting, .transcribing, .cancelling:
            false
        }
    }

    func isStarting(sessionID: UUID) -> Bool {
        if case .starting(let id) = phase { id == sessionID } else { false }
    }

    func owns(sessionID: UUID) -> Bool {
        activeSessionID == sessionID
    }

    var isRecordingVisible: Bool {
        switch phase {
        case .starting, .recording, .stopping:
            true
        case .idle, .transcribing, .cancelling:
            false
        }
    }
}

enum MeetingLifecycleEvent: Equatable {
    case startRequested(UUID)
    case recordingStarted(UUID)
    case stopRequested(UUID)
    case transcriptionStarted(UUID)
    case cancelRequested(UUID)
    case finished(UUID)

    var telemetryName: String {
        switch self {
        case .startRequested: "start_requested"
        case .recordingStarted: "recording_started"
        case .stopRequested: "stop_requested"
        case .transcriptionStarted: "transcription_started"
        case .cancelRequested: "cancel_requested"
        case .finished: "finished"
        }
    }
}

struct MeetingLifecycleTransition: Equatable {
    let state: MeetingLifecycleState
    let accepted: Bool
}

enum MeetingLifecycleReducer {
    static func transition(
        _ state: MeetingLifecycleState,
        event: MeetingLifecycleEvent
    ) -> MeetingLifecycleTransition {
        let nextState: MeetingLifecycleState?

        switch (state.phase, event) {
        case (.idle, .startRequested(let id)):
            nextState = MeetingLifecycleState(phase: .starting(id))
        case (.starting(let activeID), .recordingStarted(let id)) where activeID == id:
            nextState = MeetingLifecycleState(phase: .recording(id))
        case (.recording(let activeID), .recordingStarted(let id)) where activeID == id:
            nextState = state
        case (.recording(let activeID), .stopRequested(let id)) where activeID == id:
            nextState = MeetingLifecycleState(phase: .stopping(id))
        case (.idle, .transcriptionStarted(let id)):
            nextState = MeetingLifecycleState(phase: .transcribing(id))
        case (.stopping(let activeID), .transcriptionStarted(let id)) where activeID == id:
            nextState = MeetingLifecycleState(phase: .transcribing(id))
        case (.starting(let activeID), .cancelRequested(let id)) where activeID == id,
             (.recording(let activeID), .cancelRequested(let id)) where activeID == id,
             (.stopping(let activeID), .cancelRequested(let id)) where activeID == id,
             (.transcribing(let activeID), .cancelRequested(let id)) where activeID == id:
            nextState = MeetingLifecycleState(phase: .cancelling(id))
        case (.idle, .cancelRequested(let id)):
            nextState = MeetingLifecycleState(phase: .cancelling(id))
        case (_, .finished(let id)) where state.activeSessionID == id:
            nextState = MeetingLifecycleState()
        default:
            nextState = nil
        }

        guard let nextState else {
            return MeetingLifecycleTransition(state: state, accepted: false)
        }
        return MeetingLifecycleTransition(state: nextState, accepted: true)
    }

    static func reduce(
        _ state: MeetingLifecycleState,
        event: MeetingLifecycleEvent
    ) -> MeetingLifecycleState {
        transition(state, event: event).state
    }
}

struct MeetingLifecycleRunner {
    let sessionID: UUID
    var startupTask: Task<Void, Never>?
    var finalizationTask: Task<Void, Never>?

    mutating func cancelAll() {
        startupTask?.cancel()
        finalizationTask?.cancel()
        startupTask = nil
        finalizationTask = nil
    }
}

enum RecordingSessionInventory {
    static func preservingActiveSession(
        _ activeSession: RecordingSession?,
        in persistedSessions: [RecordingSession]
    ) -> [RecordingSession] {
        guard let activeSession,
              !persistedSessions.contains(where: { $0.id == activeSession.id })
        else { return persistedSessions }

        return [activeSession] + persistedSessions
    }
}

struct MeetingRuntimeSnapshot: Equatable {
    let lifecycle: MeetingLifecycleState
    let activeSessionID: UUID?
    let persistedSessionIDs: Set<UUID>
    let recorderIsPresent: Bool
}

enum MeetingRuntimeIssue: Equatable {
    case orphanedRecorder
    case orphanedActiveSession(UUID)
    case activeSessionNeedsRestore(UUID)
    case missingSession(UUID)
    case conflictingActiveSession(expected: UUID, actual: UUID)
    case missingRecorder(UUID)
    case recorderPresentOutsideCapture(UUID)

    var telemetryName: String {
        switch self {
        case .orphanedRecorder: "orphaned_recorder"
        case .orphanedActiveSession: "orphaned_active_session"
        case .activeSessionNeedsRestore: "active_session_needs_restore"
        case .missingSession: "missing_session"
        case .conflictingActiveSession: "conflicting_active_session"
        case .missingRecorder: "missing_recorder"
        case .recorderPresentOutsideCapture: "recorder_outside_capture"
        }
    }
}

enum MeetingRuntimeInvariant {
    static func issues(in snapshot: MeetingRuntimeSnapshot) -> [MeetingRuntimeIssue] {
        guard let expectedID = snapshot.lifecycle.activeSessionID else {
            var issues: [MeetingRuntimeIssue] = []
            if let activeSessionID = snapshot.activeSessionID {
                issues.append(.orphanedActiveSession(activeSessionID))
            }
            if snapshot.recorderIsPresent {
                issues.append(.orphanedRecorder)
            }
            return issues
        }

        var issues: [MeetingRuntimeIssue] = []
        if let activeID = snapshot.activeSessionID, activeID != expectedID {
            issues.append(.conflictingActiveSession(expected: expectedID, actual: activeID))
        }
        if snapshot.activeSessionID == nil {
            if snapshot.persistedSessionIDs.contains(expectedID) {
                issues.append(.activeSessionNeedsRestore(expectedID))
            } else {
                issues.append(.missingSession(expectedID))
            }
        } else if snapshot.activeSessionID != expectedID,
                  !snapshot.persistedSessionIDs.contains(expectedID) {
            issues.append(.missingSession(expectedID))
        }
        if snapshot.lifecycle.requiresRecorder, !snapshot.recorderIsPresent {
            issues.append(.missingRecorder(expectedID))
        }
        if !snapshot.lifecycle.allowsRecorder, snapshot.recorderIsPresent {
            issues.append(.recorderPresentOutsideCapture(expectedID))
        }
        return issues
    }
}
