import AVFoundation
import Foundation

enum CheckpointingAudioWriterFailure: Error, Sendable, Equatable {
    case continuousWrite
    case checkpointWrite
    case checkpointRotation
}

struct CheckpointingAudioWriterResult: Sendable {
    let finalCheckpoint: MeetingAudioChunk?
    let continuousAudioURL: URL?
    let failure: CheckpointingAudioWriterFailure?
    let totalFrames: AVAudioFramePosition
}

final class CheckpointingAudioWriter: @unchecked Sendable {
    var onFailure: (@Sendable (CheckpointingAudioWriterFailure) -> Void)?

    private struct State {
        var continuousFile: AVAudioFile?
        var continuousURL: URL?
        var checkpointFile: AVAudioFile?
        var checkpointURL: URL?
        var checkpointIndex = 0
        var checkpointStartFrame: AVAudioFramePosition = 0
        var checkpointFrames: AVAudioFramePosition = 0
        var totalFrames: AVAudioFramePosition = 0
        var failure: CheckpointingAudioWriterFailure?
        var isClosed = false
    }

    private let queue = DispatchQueue(label: "com.muesli.checkpointingAudioWriter")
    private let checkpointDirectory: URL
    private let format: AVAudioFormat
    private var state: State

    init(
        continuousAudioURL: URL?,
        checkpointDirectory: URL,
        format: AVAudioFormat
    ) throws {
        self.checkpointDirectory = checkpointDirectory
        self.format = format
        if let continuousAudioURL {
            try FileManager.default.createDirectory(
                at: continuousAudioURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        try FileManager.default.createDirectory(at: checkpointDirectory, withIntermediateDirectories: true)
        let checkpointURL = Self.checkpointURL(directory: checkpointDirectory, index: 0)
        state = State(
            continuousFile: try continuousAudioURL.map {
                try AVAudioFile(forWriting: $0, settings: format.settings)
            },
            continuousURL: continuousAudioURL,
            checkpointFile: try AVAudioFile(forWriting: checkpointURL, settings: format.settings),
            checkpointURL: checkpointURL
        )
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let copy = Self.copyBuffer(buffer), copy.frameLength > 0 else { return }
        queue.async { [weak self] in
            self?.write(copy)
        }
    }

    func rotateCheckpoint() -> MeetingAudioChunk? {
        queue.sync {
            guard !state.isClosed,
                  let completedURL = state.checkpointURL,
                  state.checkpointFrames > 0
            else { return nil }

            state.checkpointFile = nil
            let completed = MeetingAudioChunk(
                index: state.checkpointIndex,
                url: completedURL,
                startTime: Double(state.checkpointStartFrame) / format.sampleRate,
                duration: Double(state.checkpointFrames) / format.sampleRate
            )

            let nextIndex = state.checkpointIndex + 1
            let nextURL = Self.checkpointURL(directory: checkpointDirectory, index: nextIndex)
            do {
                state.checkpointFile = try AVAudioFile(forWriting: nextURL, settings: format.settings)
                state.checkpointURL = nextURL
                state.checkpointIndex = nextIndex
                state.checkpointStartFrame = state.totalFrames
                state.checkpointFrames = 0
            } catch {
                report(.checkpointRotation)
            }
            return completed
        }
    }

    func finish() -> CheckpointingAudioWriterResult {
        queue.sync {
            guard !state.isClosed else {
                return CheckpointingAudioWriterResult(
                    finalCheckpoint: nil,
                    continuousAudioURL: state.continuousURL,
                    failure: state.failure,
                    totalFrames: state.totalFrames
                )
            }
            state.isClosed = true
            let finalCheckpoint: MeetingAudioChunk?
            if let checkpointURL = state.checkpointURL, state.checkpointFrames > 0 {
                finalCheckpoint = MeetingAudioChunk(
                    index: state.checkpointIndex,
                    url: checkpointURL,
                    startTime: Double(state.checkpointStartFrame) / format.sampleRate,
                    duration: Double(state.checkpointFrames) / format.sampleRate
                )
            } else {
                finalCheckpoint = nil
            }
            state.checkpointFile = nil
            state.continuousFile = nil
            return CheckpointingAudioWriterResult(
                finalCheckpoint: finalCheckpoint,
                continuousAudioURL: state.continuousURL,
                failure: state.failure,
                totalFrames: state.totalFrames
            )
        }
    }

    func cancel() {
        let urls = queue.sync { () -> [URL] in
            state.isClosed = true
            state.checkpointFile = nil
            state.continuousFile = nil
            return [state.checkpointURL, state.continuousURL].compactMap { $0 }
        }
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func write(_ buffer: AVAudioPCMBuffer) {
        guard !state.isClosed else { return }
        let frameCount = AVAudioFramePosition(buffer.frameLength)
        guard frameCount > 0 else { return }
        var wroteFrames = false

        if let continuousFile = state.continuousFile {
            do {
                try continuousFile.write(from: buffer)
                wroteFrames = true
            } catch {
                state.continuousFile = nil
                report(.continuousWrite)
            }
        }

        if let checkpointFile = state.checkpointFile {
            do {
                try checkpointFile.write(from: buffer)
                state.checkpointFrames += frameCount
                wroteFrames = true
            } catch {
                state.checkpointFile = nil
                report(.checkpointWrite)
            }
        }
        if wroteFrames {
            state.totalFrames += frameCount
        }
    }

    private func report(_ failure: CheckpointingAudioWriterFailure) {
        if state.failure == nil {
            state.failure = failure
        }
        onFailure?(failure)
    }

    private static func checkpointURL(directory: URL, index: Int) -> URL {
        directory
            .appendingPathComponent("chunk-\(String(format: "%04d", index))")
            .appendingPathExtension("wav")
    }

    private static func copyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: buffer.format,
            frameCapacity: buffer.frameLength
        ) else { return nil }
        copy.frameLength = buffer.frameLength

        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        if let source = buffer.floatChannelData, let destination = copy.floatChannelData {
            for channel in 0..<channelCount {
                destination[channel].update(from: source[channel], count: frameCount)
            }
        } else if let source = buffer.int16ChannelData, let destination = copy.int16ChannelData {
            for channel in 0..<channelCount {
                destination[channel].update(from: source[channel], count: frameCount)
            }
        } else {
            return nil
        }
        return copy
    }
}
