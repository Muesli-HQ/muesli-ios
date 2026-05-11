import AVFoundation
import Foundation

@MainActor
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var outputFile: AVAudioFile?
    private var outputURL: URL?

    func requestPermission() async throws {
        let granted = await AVAudioApplication.requestRecordPermission()
        if !granted {
            throw RecordingError.microphonePermissionDenied
        }
    }

    func start() throws {
        if engine.isRunning {
            try stop()
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .spokenAudio, options: [.allowBluetoothHFP])
        try session.setActive(true)

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-\(UUID().uuidString)")
            .appendingPathExtension("caf")
        outputURL = url
        outputFile = try AVAudioFile(forWriting: url, settings: format.settings)

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { [weak self] buffer, _ in
            try? self?.outputFile?.write(from: buffer)
        }

        engine.prepare()
        try engine.start()
    }

    @discardableResult
    func stop() throws -> URL {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        outputFile = nil

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

        var errorDescription: String? {
            switch self {
            case .microphonePermissionDenied:
                "Microphone permission is required for dictation."
            case .noRecording:
                "No recording is available."
            }
        }
    }
}
