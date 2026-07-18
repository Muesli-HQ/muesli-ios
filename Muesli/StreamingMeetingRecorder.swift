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
    private final class SendableAudioBuffer: @unchecked Sendable {
        let value: AVAudioPCMBuffer

        init(_ value: AVAudioPCMBuffer) {
            self.value = value
        }
    }

    struct StopResult: Sendable {
        let finalChunk: MeetingAudioChunk?
        let retainedAudioURL: URL?
        let writerFailure: CheckpointingAudioWriterFailure?
    }

    var onAudioSamples: (([Float]) -> Void)?
    var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onRecordingFailure: (@Sendable (
        _ failure: CheckpointingAudioWriterFailure,
        _ captureID: UUID
    ) -> Void)?

    private struct FileState {
        var latestPowerDB: Float = -160
        var lastInputBufferAt: Date?
        var inputHealthEpoch: UInt64 = 0
        var inputHealthInvalidated = false
    }

    private var engine = AVAudioEngine()
    private let lock = NSLock()
    private let graphMutationLock = NSRecursiveLock()
    private var state = FileState()
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var audioWriter: CheckpointingAudioWriter?
    private var isRunning = false
    private var tapInstalled = false
    private var tapGeneration: UInt64 = 0
    private var captureGeneration: UInt64 = 0
    private var activeCaptureID: UUID?
    private var chunksDirectory: URL?

    private static let sampleRate: Double = 16_000
    private static let bufferSize: AVAudioFrameCount = 4_096

    func start(
        chunksDirectory: URL,
        retainedAudioURL: URL?,
        routeStage: String = "streaming recorder"
    ) throws {
        graphMutationLock.lock()
        defer { graphMutationLock.unlock() }

        lock.lock()
        let alreadyRunning = isRunning
        lock.unlock()
        guard !alreadyRunning else { return }
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
            let engine = currentEngine()
            let inputNode = engine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)
            let converter = !Self.formatsMatch(inputFormat, targetFormat)
                ? AVAudioConverter(from: inputFormat, to: targetFormat)
                : nil

            let captureID = UUID()
            let writer = try CheckpointingAudioWriter(
                continuousAudioURL: retainedAudioURL,
                checkpointDirectory: chunksDirectory,
                format: targetFormat
            )
            writer.onFailure = { [weak self, weak writer, captureID] failure in
                guard let writer else { return }
                self?.handleWriterFailure(
                    failure,
                    writer: writer,
                    captureID: captureID
                )
            }
            lock.lock()
            captureGeneration &+= 1
            activeCaptureID = captureID
            self.targetFormat = targetFormat
            self.converter = converter
            audioWriter = writer
            state.lastInputBufferAt = nil
            lock.unlock()

            installInputTap(on: engine, targetFormat: targetFormat)
            setTapInstalled(true)
            engine.prepare()
            try engine.start()
            setRunning(true)
        } catch {
            cleanupAfterFailedStart()
            if error is AudioRecorder.RecordingError {
                throw error
            }
            throw AudioRecorder.RecordingError.startFailed(stage: routeStage)
        }
    }

    func rotateChunk() -> MeetingAudioChunk? {
        lock.lock()
        let running = isRunning
        let writer = audioWriter
        lock.unlock()
        guard running else { return nil }
        return writer?.rotateCheckpoint()
    }

    var isCapturingAudio: Bool {
        lock.lock()
        let running = isRunning
        let inputHealthInvalidated = state.inputHealthInvalidated
        let engine = self.engine
        lock.unlock()
        return running && !inputHealthInvalidated && engine.isRunning
    }

    func isActiveCapture(_ captureID: UUID) -> Bool {
        lock.lock()
        let isActive = activeCaptureID == captureID && isRunning && audioWriter != nil
        lock.unlock()
        return isActive
    }

    private func handleWriterFailure(
        _ failure: CheckpointingAudioWriterFailure,
        writer: CheckpointingAudioWriter,
        captureID: UUID
    ) {
        lock.lock()
        guard activeCaptureID == captureID,
              audioWriter === writer,
              isRunning
        else {
            lock.unlock()
            return
        }
        invalidateInputHealthLocked()
        let callback = onRecordingFailure
        lock.unlock()
        callback?(failure, captureID)
    }

    /// `AVAudioEngine.isRunning` can remain true even when the input tap has stopped
    /// receiving buffers after a route or media-services change.
    func isReceivingAudio(
        now: Date = .now,
        maximumAge: TimeInterval = 1.5
    ) -> Bool {
        lock.lock()
        let running = isRunning
        let lastInputBufferAt = state.lastInputBufferAt
        let inputHealthInvalidated = state.inputHealthInvalidated
        let engine = self.engine
        lock.unlock()

        return RecentAudioInputHealth.isReceiving(
            hasActiveCapture: running && !inputHealthInvalidated,
            graphIsRunning: engine.isRunning,
            lastInputBufferAt: lastInputBufferAt,
            now: now,
            maximumAge: maximumAge
        )
    }

    @discardableResult
    func resumeIfNeeded(
        routeStage: String = "meeting interruption recovery",
        rebuildGraph: Bool = false,
        recreateEngine: Bool = false
    ) throws -> Bool {
        graphMutationLock.lock()
        defer { graphMutationLock.unlock() }

        lock.lock()
        let running = isRunning
        let targetFormat = self.targetFormat
        let hasTap = tapInstalled
        let inputHealthInvalidated = state.inputHealthInvalidated
        var engine = self.engine
        lock.unlock()
        let shouldRebuildGraph = rebuildGraph || inputHealthInvalidated
        guard running else { return false }
        guard !engine.isRunning || shouldRebuildGraph || recreateEngine else { return true }
        guard let targetFormat else { return false }
        _ = try AudioInputRouteManager.configureForRecording(stage: routeStage)
        lock.lock()
        state.lastInputBufferAt = nil
        lock.unlock()

        if recreateEngine {
            abandonGraphAfterMediaServicesReset(engine)
            engine = replaceEngine()
            setConverter(nil)
            configureAndInstallInputTap(on: engine, targetFormat: targetFormat)
        } else if shouldRebuildGraph {
            tearDownGraph(engine)
            configureAndInstallInputTap(on: engine, targetFormat: targetFormat)
        } else {
            guard hasTap else { return false }
        }
        do {
            engine.prepare()
            try engine.start()
            return engine.isRunning
        } catch {
            tearDownGraph(engine)
            throw error
        }
    }

    /// Media-services reset invalidates the engine instance itself. Replace it while
    /// preserving the live checkpoint writer and its accumulated audio.
    @discardableResult
    func recoverAfterMediaServicesReset(
        routeStage: String = "meeting media services reset recovery"
    ) throws -> Bool {
        try resumeIfNeeded(
            routeStage: routeStage,
            rebuildGraph: true,
            recreateEngine: true
        )
    }

    func stop() -> StopResult {
        graphMutationLock.lock()
        defer { graphMutationLock.unlock() }

        lock.lock()
        let running = isRunning
        let engine = self.engine
        lock.unlock()
        guard running else {
            return StopResult(
                finalChunk: nil,
                retainedAudioURL: nil,
                writerFailure: nil
            )
        }
        setRunning(false)
        tearDownGraph(engine)

        lock.lock()
        let writer = audioWriter
        captureGeneration &+= 1
        activeCaptureID = nil
        audioWriter = nil
        converter = nil
        targetFormat = nil
        state.lastInputBufferAt = nil
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
        graphMutationLock.lock()
        defer { graphMutationLock.unlock() }

        lock.lock()
        let hasTap = tapInstalled
        let engine = self.engine
        lock.unlock()
        if hasTap {
            tearDownGraph(engine)
        } else {
            engine.stop()
            invalidateInputHealth()
        }
        setRunning(false)

        lock.lock()
        let writer = audioWriter
        captureGeneration &+= 1
        activeCaptureID = nil
        audioWriter = nil
        converter = nil
        targetFormat = nil
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

    /// Fences the active tap and clears all prior liveness evidence. Call this at
    /// interruption/configuration-event delivery time so pre-event callbacks cannot
    /// make the post-event graph appear healthy.
    func invalidateInputHealth() {
        lock.lock()
        invalidateInputHealthLocked()
        lock.unlock()
    }

    /// Clears liveness evidence while keeping the current tap eligible. Audio already
    /// in flight may still reach the writer, but its old epoch cannot satisfy a health
    /// probe issued after this reset.
    func resetInputHealthEvidence() {
        lock.lock()
        state.inputHealthEpoch &+= 1
        state.lastInputBufferAt = nil
        state.latestPowerDB = -160
        lock.unlock()
    }

    private func handle(
        buffer: AVAudioPCMBuffer,
        targetFormat: AVAudioFormat,
        tapGeneration: UInt64
    ) {
        lock.lock()
        guard tapGeneration == self.tapGeneration,
              !state.inputHealthInvalidated,
              isRunning,
              let writer = audioWriter
        else {
            lock.unlock()
            return
        }
        let converter = self.converter
        let inputHealthEpoch = state.inputHealthEpoch
        let captureGeneration = self.captureGeneration
        lock.unlock()

        guard let monoBuffer = convert(
            buffer: buffer,
            targetFormat: targetFormat,
            converter: converter
        ) else {
            invalidateInputHealth(ifCurrentTapGeneration: tapGeneration)
            return
        }

        guard let floatData = monoBuffer.floatChannelData?[0] else {
            invalidateInputHealth(ifCurrentTapGeneration: tapGeneration)
            return
        }
        let frameCount = Int(monoBuffer.frameLength)
        guard frameCount > 0 else { return }

        let samples = Array(UnsafeBufferPointer(start: floatData, count: frameCount))
        var sumSquares: Float = 0
        for sample in samples {
            sumSquares += sample * sample
        }
        let rms = sqrt(sumSquares / Float(frameCount))
        let powerDB = rms > 0.000_001 ? max(-160, min(0, 20 * log10(rms))) : -160
        let receivedAt = Date()

        guard let callbackBuffer = Self.copyBuffer(monoBuffer) else {
            invalidateInputHealth(ifCurrentTapGeneration: tapGeneration)
            return
        }
        let sendableBuffer = SendableAudioBuffer(callbackBuffer)

        // A tap callback only proves that AVAudioEngine produced bytes. Capture
        // health must mean those bytes reached at least one durable sink. The
        // writer acknowledges on its serial queue after a successful write; the
        // generation/identity checks reject delayed acknowledgements from a torn
        // down graph, an invalidated health epoch, or an earlier recording.
        writer.append(monoBuffer) { [weak self, writer, sendableBuffer, samples] in
            self?.acceptDurablyWrittenInput(
                writer: writer,
                buffer: sendableBuffer.value,
                samples: samples,
                powerDB: powerDB,
                receivedAt: receivedAt,
                tapGeneration: tapGeneration,
                inputHealthEpoch: inputHealthEpoch,
                captureGeneration: captureGeneration
            )
        }
    }

    private func acceptDurablyWrittenInput(
        writer: CheckpointingAudioWriter,
        buffer: AVAudioPCMBuffer,
        samples: [Float],
        powerDB: Float,
        receivedAt: Date,
        tapGeneration: UInt64,
        inputHealthEpoch: UInt64,
        captureGeneration: UInt64
    ) {
        lock.lock()
        let accepted = tapGeneration == self.tapGeneration
            && inputHealthEpoch == state.inputHealthEpoch
            && captureGeneration == self.captureGeneration
            && !state.inputHealthInvalidated
            && isRunning
            && audioWriter === writer
        if accepted {
            state.latestPowerDB = powerDB
            state.lastInputBufferAt = receivedAt
        }
        let onAudioBuffer = accepted ? self.onAudioBuffer : nil
        let onAudioSamples = accepted ? self.onAudioSamples : nil
        lock.unlock()

        guard accepted else { return }
        onAudioBuffer?(buffer)
        onAudioSamples?(samples)
    }

    private func convert(
        buffer: AVAudioPCMBuffer,
        targetFormat: AVAudioFormat,
        converter: AVAudioConverter?
    ) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0 else { return nil }
        guard let converter else {
            guard Self.formatsMatch(buffer.format, targetFormat) else { return nil }
            return Self.copyBuffer(buffer)
        }
        guard Self.formatsMatch(buffer.format, converter.inputFormat),
              Self.formatsMatch(targetFormat, converter.outputFormat)
        else { return nil }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let frameCapacity = max(
            1,
            AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        )
        guard let converted = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: frameCapacity
        ) else { return nil }
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
        guard error == nil,
              converted.frameLength > 0,
              Self.formatsMatch(converted.format, targetFormat)
        else { return nil }
        return converted
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
        graphMutationLock.lock()
        defer { graphMutationLock.unlock() }

        lock.lock()
        let hasTap = tapInstalled
        let engine = self.engine
        lock.unlock()
        if hasTap {
            tearDownGraph(engine)
        } else {
            engine.stop()
            invalidateInputHealth()
        }
        lock.lock()
        let writer = audioWriter
        captureGeneration &+= 1
        activeCaptureID = nil
        audioWriter = nil
        converter = nil
        targetFormat = nil
        state = FileState()
        isRunning = false
        lock.unlock()
        writer?.cancel()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func setRunning(_ running: Bool) {
        lock.lock()
        isRunning = running
        lock.unlock()
    }

    private func setTapInstalled(_ installed: Bool) {
        lock.lock()
        tapInstalled = installed
        lock.unlock()
    }

    private func setConverter(_ newConverter: AVAudioConverter?) {
        lock.lock()
        converter = newConverter
        lock.unlock()
    }

    private func currentEngine() -> AVAudioEngine {
        lock.lock()
        let engine = self.engine
        lock.unlock()
        return engine
    }

    private func replaceEngine() -> AVAudioEngine {
        let replacement = AVAudioEngine()
        lock.lock()
        engine = replacement
        tapInstalled = false
        lock.unlock()
        return replacement
    }

    private func activateTapGeneration() -> UInt64 {
        lock.lock()
        tapGeneration &+= 1
        state.inputHealthEpoch &+= 1
        state.inputHealthInvalidated = false
        state.lastInputBufferAt = nil
        let generation = tapGeneration
        lock.unlock()
        return generation
    }

    private func invalidateInputHealthLocked() {
        tapGeneration &+= 1
        state.inputHealthEpoch &+= 1
        state.inputHealthInvalidated = true
        state.lastInputBufferAt = nil
        state.latestPowerDB = -160
    }

    private func invalidateInputHealth(ifCurrentTapGeneration generation: UInt64) {
        lock.lock()
        if generation == tapGeneration {
            invalidateInputHealthLocked()
        }
        lock.unlock()
    }

    private func installInputTap(on engine: AVAudioEngine, targetFormat: AVAudioFormat) {
        let generation = activateTapGeneration()
        engine.inputNode.installTap(
            onBus: 0,
            bufferSize: Self.bufferSize,
            format: nil
        ) { [weak self] buffer, _ in
            self?.handle(
                buffer: buffer,
                targetFormat: targetFormat,
                tapGeneration: generation
            )
        }
    }

    private func configureAndInstallInputTap(
        on engine: AVAudioEngine,
        targetFormat: AVAudioFormat
    ) {
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        let converter = !Self.formatsMatch(inputFormat, targetFormat)
            ? AVAudioConverter(from: inputFormat, to: targetFormat)
            : nil
        setConverter(converter)
        installInputTap(on: engine, targetFormat: targetFormat)
        setTapInstalled(true)
    }

    private func tearDownGraph(_ engine: AVAudioEngine) {
        lock.lock()
        let hasTap = tapInstalled
        lock.unlock()
        if hasTap {
            engine.inputNode.removeTap(onBus: 0)
            setTapInstalled(false)
        }
        engine.stop()
        invalidateInputHealth()
    }

    private func abandonGraphAfterMediaServicesReset(_ engine: AVAudioEngine) {
        // The reset invalidates the old audio objects. Avoid touching its input node;
        // stopping and generation-fencing it is sufficient before releasing it.
        engine.stop()
        setTapInstalled(false)
        invalidateInputHealth()
    }

    private static func formatsMatch(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.sampleRate == rhs.sampleRate
            && lhs.channelCount == rhs.channelCount
            && lhs.commonFormat == rhs.commonFormat
            && lhs.isInterleaved == rhs.isInterleaved
    }

}
