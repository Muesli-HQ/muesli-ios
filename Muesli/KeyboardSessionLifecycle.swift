import Foundation

struct KeyboardSessionState: Equatable {
    enum Phase: Equatable {
        case off
        case arming
        case ready
        case handoff(UUID)
        case recording(UUID)
        case transcribing(UUID)
        case retrying(String)
        case failed(String)
    }

    var phase: Phase = .off
    var sessionAvailable = false
    var micSession = KeyboardMicSession()

    var isArmed: Bool {
        switch phase {
        case .ready, .handoff, .recording, .transcribing, .arming:
            sessionAvailable
        case .off, .retrying, .failed:
            false
        }
    }

    var isKeyboardHandoffActive: Bool {
        switch phase {
        case .handoff, .recording, .transcribing:
            true
        case .off, .arming, .ready, .retrying, .failed:
            false
        }
    }

    var isWorkflowActive: Bool {
        switch phase {
        case .handoff, .recording, .transcribing, .arming:
            true
        case .off, .ready, .retrying, .failed:
            false
        }
    }

    var statusText: String {
        switch phase {
        case .off:
            "Off"
        case .arming:
            "Starting"
        case .ready:
            "Ready"
        case .handoff:
            "Starting"
        case .recording:
            "Recording"
        case .transcribing:
            "Transcribing"
        case .retrying(let message):
            message
        case .failed(let message):
            message
        }
    }
}

enum KeyboardSessionEvent {
    case micRequested
    case micStopped
    case standbyStopped(preserveHandoff: Bool)
    case startRequested
    case startSucceeded
    case startFailed(message: String, recoverable: Bool)
    case retryScheduled(message: String)
    case resumeRequested
    case handoffStarted(UUID)
    case recordingStarted(UUID)
    case transcribing(UUID)
    case requestFinished
    case stop(KeyboardSessionStopReason)
}

enum KeyboardSessionStopReason: Equatable {
    case off
    case turnedOff
    case stopped

    var message: String {
        switch self {
        case .off:
            "Off"
        case .turnedOff:
            "Turned off"
        case .stopped:
            "Stopped"
        }
    }
}

enum KeyboardSessionReducer {
    static func reduce(_ state: KeyboardSessionState, event: KeyboardSessionEvent) -> KeyboardSessionState {
        var next = state
        switch event {
        case .micRequested:
            _ = next.micSession.begin()
        case .micStopped:
            next.micSession.stop()
            next.sessionAvailable = false
        case .standbyStopped(let preserveHandoff):
            next.sessionAvailable = false
            if !preserveHandoff { next.phase = .off }
        case .startRequested:
            next.phase = .arming
            next.sessionAvailable = false
        case .startSucceeded:
            next.phase = .ready
            next.sessionAvailable = true
        case .startFailed(let message, let recoverable):
            next.phase = recoverable ? .retrying(message) : .failed(message)
            next.sessionAvailable = false
        case .retryScheduled(let message):
            next.phase = .retrying(message)
            next.sessionAvailable = false
        case .resumeRequested:
            guard state.isArmed else { return state }
            next.phase = .arming
        case .handoffStarted(let requestID):
            next.phase = .handoff(requestID)
        case .recordingStarted(let requestID):
            next.phase = .recording(requestID)
        case .transcribing(let requestID):
            next.phase = .transcribing(requestID)
        case .requestFinished:
            next.phase = state.sessionAvailable ? .ready : .off
        case .stop:
            next.phase = .off
            next.sessionAvailable = false
        }
        return next
    }
}

