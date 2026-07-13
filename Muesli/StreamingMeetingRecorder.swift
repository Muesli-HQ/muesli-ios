import AVFoundation
import Foundation
import os

struct MeetingAudioChunk: Sendable, Equatable {
    let index: Int
    let url: URL
    let startTime: TimeInterval
    let duration: TimeInterval
}

final class StreamingMeetingRecorder: @unchecked Sendable {
    struct StopResult: Sendable {
        let finalChunk: MeetingAudioChunk?
        let retainedAudioURL: URL?
        let writerFailure: CheckpointingAudioWriterFailure?
    }

    var onAudioSamples: (([Float]) -> Void)?
    var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onRecordingFailure: (@Sendable (CheckpointingAudioWriterFailure) -> Void)?

    private struct FileState {
        var latestPowerDB: Float = -160
    }

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var state = FileState()
    private var converter: AVAudioConverter?
    private var audioWriter: CheckpointingAudioWriter?
    private var isRunning = false
    private var tapInstalled = false
    private var chunksDirectory: URL?

    private static let sampleRate: Double = 16_000
    private static let bufferSize: AVAudioFrameCount = 4_096

    func start(
        chunksDirectory: URL,
        retainedAudioURL: URL?,
        routeStage: String = "streaming recorder"
    ) throws {
        guard !isRunning else { return }
        self.chunksDirectory = chunksDirectory
        try FileManager.default.createDirectory(at: chunksDirectory, withIntermediateDirectories: true)

        _ = try AudioInputRouteManager.configureForRecording(stage: routeStage)

        do {
            guard let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Self.sampleRate,
                channels: 1,
                interleaved: false
            ) else {
                throw AudioRecorder.RecordingError.startFailed(stage: "streaming format")
            }

            let inputNode = engine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)
            converter = inputFormat.sampleRate != targetFormat.sampleRate || inputFormat.channelCount != targetFormat.channelCount
                ? AVAudioConverter(from: inputFormat, to: targetFormat)
                : nil

            let writer = try CheckpointingAudioWriter(
                continuousAudioURL: retainedAudioURL,
                checkpointDirectory: chunksDirectory,
                format: targetFormat
            )
            writer.onFailure = { [weak self] failure in
                self?.onRecordingFailure?(failure)
            }
            lock.lock()
            audioWriter = writer
            lock.unlock()

            inputNode.installTap(onBus: 0, bufferSize: Self.bufferSize, format: nil) { [weak self] buffer, _ in
                self?.handle(buffer: buffer, targetFormat: targetFormat)
            }
            tapInstalled = true
            engine.prepare()
            try engine.start()
            isRunning = true
        } catch {
            cleanupAfterFailedStart()
            if error is AudioRecorder.RecordingError {
                throw error
            }
            throw AudioRecorder.RecordingError.startFailed(stage: routeStage)
        }
    }

    func rotateChunk() -> MeetingAudioChunk? {
        guard isRunning else { return nil }
        lock.lock()
        let writer = audioWriter
        lock.unlock()
        return writer?.rotateCheckpoint()
    }

    var isCapturingAudio: Bool {
        isRunning && engine.isRunning
    }

    @discardableResult
    func resumeIfNeeded(routeStage: String = "meeting interruption recovery") throws -> Bool {
        guard isRunning else { return false }
        guard !engine.isRunning else { return true }
        _ = try AudioInputRouteManager.configureForRecording(stage: routeStage)
        engine.prepare()
        try engine.start()
        return engine.isRunning
    }

    func stop() -> StopResult {
        guard isRunning else {
            return StopResult(
                finalChunk: nil,
                retainedAudioURL: nil,
                writerFailure: nil
            )
        }
        isRunning = false
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()

        lock.lock()
        let writer = audioWriter
        audioWriter = nil
        lock.unlock()
        let result = writer?.finish()

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        return StopResult(
            finalChunk: result?.finalCheckpoint,
            retainedAudioURL: result?.continuousAudioURL,
            writerFailure: result?.failure
        )
    }

    func cancel() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        isRunning = false

        lock.lock()
        let writer = audioWriter
        audioWriter = nil
        state = FileState()
        lock.unlock()
        writer?.cancel()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func currentPower() -> Float {
        lock.lock()
        let value = state.latestPowerDB
        lock.unlock()
        return value
    }

    private func handle(buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) {
        let monoBuffer: AVAudioPCMBuffer
        if let converter {
            let ratio = targetFormat.sampleRate / buffer.format.sampleRate
            let frameCapacity = max(1, AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1)
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else { return }
            let didProvideInput = OSAllocatedUnfairLock(initialState: false)
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, outStatus in
                let shouldProvideInput = didProvideInput.withLock { hasProvidedInput in
                    guard !hasProvidedInput else { return false }
                    hasProvidedInput = true
                    return true
                }
                guard shouldProvideInput else {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                outStatus.pointee = .haveData
                return buffer
            }
            guard error == nil else { return }
            monoBuffer = converted
        } else {
            monoBuffer = buffer
        }

        guard let floatData = monoBuffer.floatChannelData?[0] else { return }
        let frameCount = Int(monoBuffer.frameLength)
        guard frameCount > 0 else { return }

        let samples = Array(UnsafeBufferPointer(start: floatData, count: frameCount))
        var sumSquares: Float = 0
        for sample in samples {
            sumSquares += sample * sample
        }
        let rms = sqrt(sumSquares / Float(frameCount))
        let powerDB = rms > 0.000_001 ? max(-160, min(0, 20 * log10(rms))) : -160

        lock.lock()
        audioWriter?.append(monoBuffer)
        state.latestPowerDB = powerDB
        lock.unlock()

        if let audioBuffer = Self.copyBuffer(monoBuffer) {
            onAudioBuffer?(audioBuffer)
        }
        onAudioSamples?(samples)
    }

    private static func copyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: buffer.format,
            frameCapacity: buffer.frameLength
        ) else {
            return nil
        }

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
        }
        return copy
    }

    private func cleanupAfterFailedStart() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        lock.lock()
        let writer = audioWriter
        audioWriter = nil
        state = FileState()
        lock.unlock()
        writer?.cancel()
        isRunning = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

}
