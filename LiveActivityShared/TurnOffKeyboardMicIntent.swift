import AppIntents
import Foundation

struct TurnOffKeyboardMicIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Turn mic off"
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static let openAppWhenRun = false
    static let isDiscoverable = false

    @Parameter(title: "Microphone Session") var sessionID: String

    init() {}
    init(sessionID: String) { self.sessionID = sessionID }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: sessionID),
              await KeyboardMicActionDispatcher.turnOff(sessionID: id) else {
            throw KeyboardMicActionError.unavailable
        }
        return .result()
    }
}

enum KeyboardMicActionError: LocalizedError {
    case unavailable
    var errorDescription: String? { "Open Muesli to turn the microphone off." }
}

@MainActor
enum KeyboardMicActionDispatcher {
    typealias Handler = @MainActor (UUID) async -> Bool
    private static var handler: Handler?
    static func register(_ handler: Handler?) { self.handler = handler }
    static func turnOff(sessionID: UUID) async -> Bool {
        guard let handler else { return false }
        return await handler(sessionID)
    }
}
