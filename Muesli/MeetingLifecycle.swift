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
    let id: UUID
    let sessionID: UUID
    var startupTask: Task<Void, Never>?
    var finalizationTask: Task<Void, Never>?

    init(id: UUID = UUID(), sessionID: UUID) {
        self.id = id
        self.sessionID = sessionID
    }

    mutating func cancelAll() {
        startupTask?.cancel()
        finalizationTask?.cancel()
        startupTask = nil
        finalizationTask = nil
    }
}

enum MeetingPresentationState: Equatable {
    case idle
    case capturing(UUID)
    case processing(UUID)
    case recovery(UUID)

    var sessionID: UUID? {
        switch self {
        case .idle: nil
        case .capturing(let id), .processing(let id), .recovery(let id): id
        }
    }

    var isBusy: Bool { sessionID != nil }
    var isCapturing: Bool {
        if case .capturing = self { true } else { false }
    }
    var isProcessing: Bool {
        if case .processing = self { true } else { false }
    }
    var needsRecovery: Bool {
        if case .recovery = self { true } else { false }
    }
}

struct MeetingPresentationSnapshot: Equatable {
    let runtime: MeetingLifecycleState
    let persistedSessionID: UUID?
    let persistedPhase: RecordingSessionPhase?
    let recorderIsPresent: Bool
}

enum MeetingPresentationPolicy {
    static func state(for snapshot: MeetingPresentationSnapshot) -> MeetingPresentationState {
        guard let sessionID = snapshot.runtime.activeSessionID else {
            guard snapshot.persistedPhase == .recording,
                  let persistedSessionID = snapshot.persistedSessionID
            else { return .idle }
            return .recovery(persistedSessionID)
        }

        guard let persistedPhase = snapshot.persistedPhase else { return .idle }
        switch persistedPhase {
        case .completed, .failed, .cancelled:
            return .idle
        case .transcriptionQueued:
            return .recovery(sessionID)
        case .transcribing:
            return snapshot.runtime.isTranscribing ? .processing(sessionID) : .recovery(sessionID)
        case .recording:
            switch snapshot.runtime.phase {
            case .starting:
                return .capturing(sessionID)
            case .recording where snapshot.recorderIsPresent:
                return .capturing(sessionID)
            case .stopping:
                return .processing(sessionID)
            case .idle, .recording, .transcribing, .cancelling:
                return .recovery(sessionID)
            }
        }
    }
}

enum MeetingAudioInterruptionCause: String, Equatable {
    case sceneBackgrounded = "scene_backgrounded"
    case routeDisconnected = "route_disconnected"
    case microphoneMuted = "microphone_muted"
    case deviceUnauthenticated = "device_unauthenticated"
    case system = "system"
}

enum MeetingAudioInterruptionDisposition: Equatable {
    case keepCaptureAlive
    case finalizeForRecovery
}

enum MeetingAudioInterruptionPolicy {
    static func disposition(
        for cause: MeetingAudioInterruptionCause
    ) -> MeetingAudioInterruptionDisposition {
        .keepCaptureAlive
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
    var persistedSessionPhases: [UUID: RecordingSessionPhase] = [:]
}

enum MeetingRuntimeIssue: Equatable {
    case orphanedRecorder
    case orphanedActiveSession(UUID)
    case activeSessionNeedsRestore(UUID)
    case missingSession(UUID)
    case conflictingActiveSession(expected: UUID, actual: UUID)
    case missingRecorder(UUID)
    case recorderPresentOutsideCapture(UUID)
    case persistedPhaseConflictsWithRuntime(
        sessionID: UUID,
        runtime: MeetingLifecycleState.Phase,
        persisted: RecordingSessionPhase
    )

    var telemetryName: String {
        switch self {
        case .orphanedRecorder: "orphaned_recorder"
        case .orphanedActiveSession: "orphaned_active_session"
        case .activeSessionNeedsRestore: "active_session_needs_restore"
        case .missingSession: "missing_session"
        case .conflictingActiveSession: "conflicting_active_session"
        case .missingRecorder: "missing_recorder"
        case .recorderPresentOutsideCapture: "recorder_outside_capture"
        case .persistedPhaseConflictsWithRuntime: "persisted_phase_conflicts_with_runtime"
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
        if let persistedPhase = snapshot.persistedSessionPhases[expectedID],
           !persistedPhase.isCompatible(with: snapshot.lifecycle.phase) {
            issues.append(.persistedPhaseConflictsWithRuntime(
                sessionID: expectedID,
                runtime: snapshot.lifecycle.phase,
                persisted: persistedPhase
            ))
        }
        return issues
    }
}


extension RecordingSessionPhase {
    func isCompatible(with runtime: MeetingLifecycleState.Phase) -> Bool {
        switch runtime {
        case .idle:
            true
        case .starting, .recording:
            self == .recording
        case .stopping:
            self == .recording || self == .transcriptionQueued
        case .transcribing:
            self == .transcribing
        case .cancelling:
            self != .completed && self != .failed
        }
    }
}
