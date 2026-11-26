import AVFoundation
import Foundation
import Speech

/// The keyboard extension cannot show permission prompts. Speech Recognition
/// gives the keyboard live words and its Apple Speech fallback, so the app asks
/// once, when nothing is recording.
@MainActor
enum InKeyboardDictationPermissionPrompt {
    /// Lets a keyboard handoff that opened the app start recording first.
    private static let settleDelay: Duration = .seconds(2)
    private static var isPrompting = false

    static func requestIfNeeded(isRecording: @escaping @MainActor () -> Bool) {
        guard !isPrompting, shouldPrompt(isRecording: isRecording()) else { return }
        isPrompting = true
        Task { @MainActor in
            defer { isPrompting = false }
            try? await Task.sleep(for: settleDelay)
            guard shouldPrompt(isRecording: isRecording()) else { return }
            let status = await requestAuthorization()
            AppTelemetry.signal("keyboard_inline_speech_permission", parameters: [
                "granted": status == .authorized ? "true" : "false"
            ])
        }
    }

    static func shouldPrompt(
        isRecording: Bool,
        microphone: AVAudioApplication.recordPermission = AVAudioApplication.shared.recordPermission,
        speech: SFSpeechRecognizerAuthorizationStatus = SFSpeechRecognizer.authorizationStatus()
    ) -> Bool {
        !isRecording && microphone == .granted && speech == .notDetermined
    }

    /// Nonisolated so Speech's background-queue callback is not inferred as
    /// main-actor isolated.
    nonisolated private static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }
}
