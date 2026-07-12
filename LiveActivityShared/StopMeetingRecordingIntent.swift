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
            return .result()
        }
        _ = MeetingLiveActivityActionDispatcher.stopMeetingRecording(sessionID: sessionID)
        return .result()
    }
}

@MainActor
enum MeetingLiveActivityActionDispatcher {
    typealias StopHandler = @MainActor (UUID) -> Bool

    private static var stopHandler: StopHandler?

    static func register(stopHandler: StopHandler?) {
        self.stopHandler = stopHandler
    }

    @discardableResult
    static func stopMeetingRecording(sessionID: UUID) -> Bool {
        stopHandler?(sessionID) ?? false
    }
}
