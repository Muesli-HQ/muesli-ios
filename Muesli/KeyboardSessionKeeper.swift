import AVFoundation
import Foundation

@MainActor
final class KeyboardSessionKeeper {
    private var engine: AVAudioEngine?

    var isRunning: Bool {
        engine?.isRunning == true
    }

    func start() async throws {
        if isRunning { return }

        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else {
            throw AudioRecorder.RecordingError.microphonePermissionDenied
        }

        _ = try AudioInputRouteManager.configureForRecording(
            stage: "keyboard session",
            preference: .builtIn
        )

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.inputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format, block: Self.discardAudioTap)
        engine.prepare()

        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            throw AudioRecorder.RecordingError.startFailed(stage: "keyboard session")
        }

        self.engine = engine
    }

    func stop(deactivateSession: Bool = true) {
        guard let engine else {
            if deactivateSession {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
            return
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil

        if deactivateSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    nonisolated static func discardAudioTap(_: AVAudioPCMBuffer, when _: AVAudioTime) {}
}
