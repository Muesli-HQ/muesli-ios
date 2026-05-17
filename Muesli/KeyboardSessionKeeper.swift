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

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            throw AudioRecorder.RecordingError.audioSessionFailed(stage: "keyboard session", underlying: error)
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.inputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { _, _ in
            // Keep the microphone session alive for keyboard commands; audio is intentionally discarded.
        }
        engine.prepare()

        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
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
}
