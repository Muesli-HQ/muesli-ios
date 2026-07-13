import AppIntents
import Foundation

struct StopMeetingRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Meeting Recording"
    static let description = IntentDescription("Stops the active Muesli meeting recording and begins local processing.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static let isDiscoverable = false

    @Parameter(title: "Meeting Session")
    var sessionID: String

    init() {}

    init(sessionID: String) {
        self.sessionID = sessionID
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let sessionID = UUID(uuidString: sessionID) else {
            throw StopMeetingRecordingIntentError.invalidSession
        }

        switch MeetingLiveActivityActionDispatcher.stopMeetingRecording(sessionID: sessionID) {
        case .accepted, .alreadyHandled:
            return .result()
        case .failed, .unavailable:
            throw StopMeetingRecordingIntentError.unavailable
        }
    }
}

private enum StopMeetingRecordingIntentError: LocalizedError {
    case invalidSession
    case unavailable

    var errorDescription: String? {
        switch self {
        case .invalidSession:
            "This meeting recording is no longer available."
        case .unavailable:
            "Muesli could not stop this meeting recording. Open the app and try again."
        }
    }
}

enum MeetingLiveActivityStopResult: Equatable {
    case accepted
    case alreadyHandled
    case failed
    case unavailable
}

@MainActor
enum MeetingLiveActivityActionDispatcher {
    typealias StopHandler = @MainActor (UUID) -> MeetingLiveActivityStopResult

    private static var stopHandler: StopHandler?

    static func register(stopHandler: StopHandler?) {
        self.stopHandler = stopHandler
    }

    static func stopMeetingRecording(sessionID: UUID) -> MeetingLiveActivityStopResult {
        guard let stopHandler else { return .unavailable }
        return stopHandler(sessionID)
    }
}
