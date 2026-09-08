import AppIntents
import Foundation
import UserNotifications

@available(iOS 18.0, *)
struct ToggleMuesliDictationIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Muesli Dictation"
    static let description = IntentDescription(
        "Starts or stops dictation. Inserts text through the active Muesli keyboard, or offers Open to copy when the transcript is ready."
    )
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let capture = try await performActionButtonCapture(.dictation)
        guard case .stopped(let sessionID) = capture else { return ActionButtonShortcutOutput.intentResult(nil) }
        let store = SharedStore()
        let text = try await ActionButtonShortcutOutput.waitForTranscript {
            guard let session = try store.recordingSession(id: sessionID) else { return nil }
            if session.phase == .failed || session.phase == .cancelled {
                throw ActionButtonCaptureError.unavailable(session.errorMessage ?? "The recording could not be transcribed.")
            }
            guard let requestID = session.requestID else { return nil }
            return try store.result(for: requestID)?.text
        }
        return ActionButtonShortcutOutput.intentResult(text)
    }
}

/// The bundled workflow calls this only after Apple's Copy to Clipboard action.
@available(iOS 18.0, *)
struct ConfirmMuesliClipboardIntent: AppIntent {
    static let title: LocalizedStringResource = "Confirm copied dictation"
    static let description = IntentDescription("Shows the copied transcript after the Copy to Clipboard action completes.")
    static let openAppWhenRun = false

    @Parameter(title: "Transcript") var transcript: String?

    func perform() async throws -> some IntentResult {
        guard let transcript, let text = ActionButtonClipboardConfirmation.nonemptyTranscript(transcript) else { return .result() }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            return .result()
        }
        let content = UNMutableNotificationContent()
        content.title = "Copied to clipboard"
        content.body = text
        try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        return .result()
    }
}

enum ActionButtonClipboardConfirmation {
    static func nonemptyTranscript(_ text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

@available(iOS 18.0, *)
struct ToggleMuesliMeetingIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Muesli Meeting Note"
    static let description = IntentDescription(
        "Starts or stops a meeting recording and saves it in Muesli Meetings for transcription."
    )
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = try await performActionButtonCapture(.meeting)
        return .result()
    }
}

@MainActor
private func performActionButtonCapture(_ mode: ActionButtonCaptureMode) async throws -> ActionButtonDictationResult {
    let result = await ActionButtonCaptureDispatcher.toggle(mode)
    let store = SetupVerificationStore()
    switch result {
    case .started(let sessionID):
        store.recordActionButtonEvent(.started, mode: mode, sessionID: sessionID)
    case .stopped(let sessionID):
        store.recordActionButtonEvent(.stopped, mode: mode, sessionID: sessionID)
    case .busy(let message), .failed(let message):
        throw ActionButtonCaptureError.unavailable(message)
    case .unavailable:
        throw ActionButtonCaptureError.unavailable("Open Muesli once to finish preparing, then try again.")
    }
    return result
}

@available(iOS 18.0, *)
struct MuesliAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleMuesliDictationIntent(),
            phrases: ["Start dictation with \(.applicationName)", "Toggle dictation with \(.applicationName)"],
            shortTitle: "Muesli Dictation",
            systemImageName: "waveform.badge.mic"
        )
        AppShortcut(
            intent: ToggleMuesliMeetingIntent(),
            phrases: ["Record a meeting with \(.applicationName)", "Toggle meeting recording with \(.applicationName)"],
            shortTitle: "Muesli Meeting Note",
            systemImageName: "person.2.wave.2"
        )
    }
}

enum ActionButtonCaptureError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self {
        case .unavailable(let message): message
        }
    }
}

enum ActionButtonDictationResult: Sendable, Equatable {
    case started(sessionID: UUID)
    case stopped(sessionID: UUID)
    case busy(String)
    case failed(String)
    case unavailable
}

@MainActor
enum ActionButtonCaptureDispatcher {
    typealias ToggleHandler = @MainActor @Sendable (ActionButtonCaptureMode) async -> ActionButtonDictationResult
    private static var toggleHandler: ToggleHandler?

    static func register(toggleHandler: ToggleHandler?) {
        self.toggleHandler = toggleHandler
    }

    static func toggle(_ mode: ActionButtonCaptureMode) async -> ActionButtonDictationResult {
        guard let toggleHandler else { return .unavailable }
        return await toggleHandler(mode)
    }
}

struct ActionButtonTestOutput: Equatable {
    var title: String
    var detail: String
    var text = ""
    var isComplete = false
    var isFailure = false
}

/// Keep the stop invocation alive until its own result exists, so the next
/// Shortcuts action receives text instead of racing asynchronous transcription.
@MainActor
enum ActionButtonShortcutOutput {
    // An empty String is still an output item in Shortcuts. Starting capture must
    // return no item, so "has any value" skips clipboard and confirmation actions.
    static func intentResult(_ text: String?) -> IntentResultContainer<String, Never, Never, Never> {
        var result: IntentResultContainer<String, Never, Never, Never> = .result(value: "")
        result.value = text.flatMap(ActionButtonClipboardConfirmation.nonemptyTranscript)
        return result
    }

    static func waitForTranscript(
        timeout: Duration = .seconds(60),
        pollInterval: Duration = .milliseconds(100),
        read: @MainActor () throws -> String?
    ) async throws -> String {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            try Task.checkCancellation()
            if let text = try read() {
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ActionButtonCaptureError.unavailable("No speech was recognized. Nothing was copied. Try recording again.")
                }
                return text
            }
            guard clock.now < deadline else {
                throw ActionButtonCaptureError.unavailable("Transcription is still finishing. Your recording is saved in Muesli.")
            }
            try await Task.sleep(for: pollInterval)
        }
    }
}

/// Establish audio while the intent's startup permission is held. Creating the
/// Live Activity can retire that startup assertion, so it follows capture.
/// Never leave audio running if the required activity cannot be published.
@MainActor
enum ActionButtonCaptureStartup {
    static func run(
        startAudio: () async throws -> Void,
        publishActivity: () async throws -> Void,
        cancelAudio: () -> Void
    ) async throws {
        do {
            try Task.checkCancellation()
            try await startAudio()
            KeyboardDiagnosticsLog.record("recording.audioEstablished")
            try Task.checkCancellation()
            try await publishActivity()
            try Task.checkCancellation()
        } catch {
            cancelAudio()
            throw error
        }
    }
}
