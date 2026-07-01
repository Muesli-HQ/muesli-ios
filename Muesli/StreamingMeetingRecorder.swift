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
    var onAudioSamples: (([Float]) -> Void)?
    var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?

    private struct FileState {
        var chunkFile: AVAudioFile?
        var chunkURL: URL?
        var chunkIndex = 0
        var chunkStartFrame: AVAudioFramePosition = 0
        var chunkFrames: AVAudioFramePosition = 0
        var retainedFile: AVAudioFile?
        var retainedURL: URL?
        var totalFrames: AVAudioFramePosition = 0
        var latestPowerDB: Float = -160
    }

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var state = FileState()
    private var converter: AVAudioConverter?
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

            let firstChunkURL = chunkURL(directory: chunksDirectory, index: 0)
            let firstChunkFile = try AVAudioFile(forWriting: firstChunkURL, settings: targetFormat.settings)
            let retainedFile = try retainedAudioURL.map { url in
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                return try AVAudioFile(forWriting: url, settings: targetFormat.settings)
            }

            lock.lock()
            state = FileState(
                chunkFile: firstChunkFile,
                chunkURL: firstChunkURL,
                retainedFile: retainedFile,
                retainedURL: retainedAudioURL
            )
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
        guard isRunning, let chunksDirectory else { return nil }

        lock.lock()
        guard let completedURL = state.chunkURL, state.chunkFrames > 0 else {
            lock.unlock()
            return nil
        }

        state.chunkFile = nil
        let completedIndex = state.chunkIndex
        let completedStartFrame = state.chunkStartFrame
        let completedFrames = state.chunkFrames
        let nextIndex = completedIndex + 1
        let nextURL = chunkURL(directory: chunksDirectory, index: nextIndex)

        do {
            guard let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Self.sampleRate,
                channels: 1,
                interleaved: false
            ) else {
                lock.unlock()
                return nil
            }
            let nextFile = try AVAudioFile(forWriting: nextURL, settings: format.settings)
            state.chunkFile = nextFile
            state.chunkURL = nextURL
            state.chunkIndex = nextIndex
            state.chunkStartFrame = state.totalFrames
            state.chunkFrames = 0
        } catch {
            lock.unlock()
            return nil
        }
        lock.unlock()

        return MeetingAudioChunk(
            index: completedIndex,
            url: completedURL,
            startTime: Double(completedStartFrame) / Self.sampleRate,
            duration: Double(completedFrames) / Self.sampleRate
        )
    }

    func stop() -> (finalChunk: MeetingAudioChunk?, retainedAudioURL: URL?) {
        guard isRunning else { return (nil, nil) }
        isRunning = false
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()

        lock.lock()
        let finalURL = state.chunkURL
        let finalIndex = state.chunkIndex
        let finalStartFrame = state.chunkStartFrame
        let finalFrames = state.chunkFrames
        let retainedURL = state.retainedURL
        state.chunkFile = nil
        state.retainedFile = nil
        state.chunkURL = nil
        state.retainedURL = nil
        lock.unlock()

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        let finalChunk: MeetingAudioChunk?
        if let finalURL, finalFrames > 0 {
            finalChunk = MeetingAudioChunk(
                index: finalIndex,
                url: finalURL,
                startTime: Double(finalStartFrame) / Self.sampleRate,
                duration: Double(finalFrames) / Self.sampleRate
            )
        } else {
            finalChunk = nil
        }
        return (finalChunk, retainedURL)
    }

    func cancel() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        isRunning = false

        lock.lock()
        let chunkURL = state.chunkURL
        let retainedURL = state.retainedURL
        state = FileState()
        lock.unlock()

        if let chunkURL {
            try? FileManager.default.removeItem(at: chunkURL)
        }
        if let retainedURL {
            try? FileManager.default.removeItem(at: retainedURL)
        }
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
        do {
            try state.chunkFile?.write(from: monoBuffer)
            try state.retainedFile?.write(from: monoBuffer)
            state.chunkFrames += AVAudioFramePosition(frameCount)
            state.totalFrames += AVAudioFramePosition(frameCount)
            state.latestPowerDB = powerDB
        } catch {
            // Keep recording best-effort; UI will surface failure on stop if no chunks exist.
        }
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
        state = FileState()
        lock.unlock()
        isRunning = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func chunkURL(directory: URL, index: Int) -> URL {
        directory
            .appendingPathComponent("chunk-\(String(format: "%04d", index))")
            .appendingPathExtension("wav")
    }
}
