import AVFoundation
import Foundation

@MainActor
final class AudioRecorder {
    private var recorder: AVAudioRecorder?
    private var outputURL: URL?

    func requestPermission() async throws {
        let granted = await AVAudioApplication.requestRecordPermission()
        if !granted {
            throw RecordingError.microphonePermissionDenied
        }
    }

    func start() throws {
        if recorder?.isRecording == true {
            try stop()
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .spokenAudio, options: [.allowBluetooth])
        try session.setActive(true)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        outputURL = url
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = false
        guard recorder.prepareToRecord(), recorder.record() else {
            throw RecordingError.startFailed
        }
        self.recorder = recorder
    }

    @discardableResult
    func stop() throws -> URL {
        recorder?.stop()
        recorder = nil

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        guard let outputURL else {
            throw RecordingError.noRecording
        }

        self.outputURL = nil
        return outputURL
    }

    enum RecordingError: LocalizedError {
        case microphonePermissionDenied
        case noRecording
        case startFailed

        var errorDescription: String? {
            switch self {
            case .microphonePermissionDenied:
                "Microphone permission is required for dictation."
            case .noRecording:
                "No recording is available."
            case .startFailed:
                "Could not start microphone recording. Try again."
            }
        }
    }
}
