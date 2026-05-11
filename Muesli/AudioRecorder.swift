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
        do {
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [])
        } catch {
            throw RecordingError.audioSessionFailed(stage: "category", underlying: error)
        }

        do {
            try session.setActive(true)
        } catch {
            throw RecordingError.audioSessionFailed(stage: "activation", underlying: error)
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        outputURL = url
        let recorder: AVAudioRecorder
        do {
            recorder = try AVAudioRecorder(url: url, settings: settings)
        } catch {
            throw RecordingError.recorderSetupFailed(stage: "create", underlying: error)
        }
        recorder.isMeteringEnabled = false
        guard recorder.prepareToRecord() else {
            throw RecordingError.startFailed(stage: "prepare")
        }
        guard recorder.record() else {
            throw RecordingError.startFailed(stage: "record")
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
        case audioSessionFailed(stage: String, underlying: Error)
        case recorderSetupFailed(stage: String, underlying: Error)
        case startFailed(stage: String)

        var errorDescription: String? {
            switch self {
            case .microphonePermissionDenied:
                "Microphone permission is required for dictation."
            case .noRecording:
                "No recording is available."
            case .audioSessionFailed(let stage, let underlying):
                "Audio session \(stage) failed: \(underlying.localizedDescription)"
            case .recorderSetupFailed(let stage, let underlying):
                "Audio recorder \(stage) failed: \(underlying.localizedDescription)"
            case .startFailed(let stage):
                "Audio recorder \(stage) failed. Try again."
            }
        }
    }
}
