import AVFoundation
import Foundation
import os

enum RecentAudioInputHealth {
    static func isReceiving(
        hasActiveCapture: Bool,
        graphIsRunning: Bool,
        lastInputBufferAt: Date?,
        now: Date,
        maximumAge: TimeInterval
    ) -> Bool {
        guard hasActiveCapture,
              graphIsRunning,
              maximumAge >= 0,
              let lastInputBufferAt
        else { return false }

        let age = now.timeIntervalSince(lastInputBufferAt)
        return age >= 0 && age <= maximumAge
    }
}

final class KeyboardSessionKeeper: @unchecked Sendable {
    struct SegmentResult: Sendable {
        let audioURL: URL
        let finalCheckpoint: MeetingAudioChunk?
        let writerFailure: CheckpointingAudioWriterFailure?
    }

    private final class ConverterInputState: @unchecked Sendable {
        var didProvideInput = false
    }

    private struct FileState {
        var activeFile: AVAudioFile?
        var checkpointWriter: CheckpointingAudioWriter?
        var activeURL: URL?
        var activeSegmentID: UUID?
        var latestPowerDB: Float = -160
        var segmentFrames: AVAudioFramePosition = 0
        var lastInputBufferAt: Date?
        var lastStandbyInputBufferAt: Date?
        var lastInputActivityNotifiedAt = Date.distantPast
        var inputHealthEpoch: UInt64 = 0
        var inputHealthInvalidated = false
        var isFinishingSegment = false
    }

    private struct PendingFileWrite: @unchecked Sendable {
        let segmentID: UUID
        let tapGeneration: UInt64
        let inputHealthEpoch: UInt64
        let file: AVAudioFile
        let buffer: AVAudioPCMBuffer
        let frameCount: Int
        let powerDB: Float
        let receivedAt: Date
    }

    private var engine = AVAudioEngine()
    private let lock = NSLock()
    private let graphMutationLock = NSRecursiveLock()
    private let fileWriteQueue = DispatchQueue(label: "com.muesli.keyboardSessionKeeper.fileWrite")
    private var state = FileState()
    private var converter: AVAudioConverter?
    private var isEngineRunning = false
    private var isStarting = false
    private var tapInstalled = false
    private var tapGeneration: UInt64 = 0
    private var inputActivityHandler: (@Sendable (
        _ powerDB: Float,
        _ isCapturing: Bool,
        _ segmentID: UUID?
    ) -> Void)?
    var onRecordingFailure: (@Sendable (
        _ failure: CheckpointingAudioWriterFailure,
        _ segmentID: UUID
    ) -> Void)?

    private static let sampleRate: Double = 16_000
    private static let bufferSize: AVAudioFrameCount = 2_048
    private static let standbyInputMaximumAge: TimeInterval = 1.5
    private static let inputActivityNotificationInterval: TimeInterval = 0.16

    static func discardAudioTap(_ buffer: AVAudioPCMBuffer, when _: AVAudioTime) {
        _ = buffer.frameLength
    }

    var isRunning: Bool {
        lock.lock()
        let shouldBeRunning = isEngineRunning
        let engine = self.engine
        lock.unlock()
        return shouldBeRunning && engine.isRunning
    }

    var canAcceptStartCommand: Bool {
        lock.lock()
        let shouldBeRunning = isEngineRunning
        let hasTap = tapInstalled
        let inputHealthInvalidated = state.inputHealthInvalidated
        let hasActiveSegment = state.activeFile != nil || state.checkpointWriter != nil
        let lastStandbyInputBufferAt = state.lastStandbyInputBufferAt
        let engine = self.engine
        lock.unlock()

        return RecentAudioInputHealth.isReceiving(
            hasActiveCapture: shouldBeRunning
                && hasTap
                && !inputHealthInvalidated
                && !hasActiveSegment,
            graphIsRunning: engine.isRunning,
            lastInputBufferAt: lastStandbyInputBufferAt,
            now: .now,
            maximumAge: Self.standbyInputMaximumAge
        )
    }

    var isRecordingSegment: Bool {
        lock.lock()
        let recording = state.activeFile != nil || state.checkpointWriter != nil
        lock.unlock()
        return recording
    }

    var isCapturingAudio: Bool {
        lock.lock()
        let engine = self.engine
        let inputHealthInvalidated = state.inputHealthInvalidated
        lock.unlock()
        return isRecordingSegment && !inputHealthInvalidated && engine.isRunning
    }

    /// `AVAudioEngine.isRunning` only describes the render graph. A graph can remain
    /// running after a route/configuration change while its input tap receives no
    /// buffers. Use this signal when deciding whether capture actually recovered.
    func isReceivingAudio(
        now: Date = .now,
        maximumAge: TimeInterval = 1.5
    ) -> Bool {
        lock.lock()
        let lastInputBufferAt = state.lastInputBufferAt
        let hasActiveSegment = state.activeFile != nil || state.checkpointWriter != nil
        let inputHealthInvalidated = state.inputHealthInvalidated
        let engine = self.engine
        lock.unlock()

        return RecentAudioInputHealth.isReceiving(
            hasActiveCapture: hasActiveSegment && !inputHealthInvalidated,
            graphIsRunning: engine.isRunning,
            lastInputBufferAt: lastInputBufferAt,
            now: now,
            maximumAge: maximumAge
        )
    }

    func start() async throws {
        guard beginStartingIfNeeded() else {
            return
        }

        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else {
            setEngineStarting(false)
            throw AudioRecorder.RecordingError.microphonePermissionDenied
        }

        do {
            try withGraphMutationLock {
                // Standby captures real keyboard dictation segments, so it must honor the selected route.
                _ = try AudioInputRouteManager.configureForRecording(stage: "keyboard session")
                prepareForStart()

                let targetFormat = try Self.makeTargetFormat()
                let engine = currentEngine()
                let inputNode = engine.inputNode
                let inputFormat = inputNode.outputFormat(forBus: 0)
                setConverter(
                    Self.requiresConversion(from: inputFormat, to: targetFormat)
                        ? AVAudioConverter(from: inputFormat, to: targetFormat)
                        : nil
                )

                installInputTap(on: engine, targetFormat: targetFormat)
                setTapInstalled(true)
                engine.prepare()
                try engine.start()

                setEngineRunning(true)
            }
        } catch {
            cleanupAfterFailedStart()
            if error is AudioRecorder.RecordingError {
                throw error
            }
            throw AudioRecorder.RecordingError.startFailed(stage: "keyboard session")
        }
    }

    func setInputActivityHandler(
        _ handler: (@Sendable (
            _ powerDB: Float,
            _ isCapturing: Bool,
            _ segmentID: UUID?
        ) -> Void)?
    ) {
        lock.lock()
        inputActivityHandler = handler
        lock.unlock()
    }

    func isActiveSegment(_ segmentID: UUID) -> Bool {
        lock.lock()
        let isActive = state.activeSegmentID == segmentID && !state.isFinishingSegment
        lock.unlock()
        return isActive
    }

    func beginSegment(outputURL: URL, checkpointDirectory: URL? = nil) throws {
        graphMutationLock.lock()
        defer { graphMutationLock.unlock() }

        guard canAcceptStartCommand else {
            throw AudioRecorder.RecordingError.startFailed(
                stage: "keyboard session standby input not ready"
            )
        }

        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let format = try Self.makeTargetFormat()
        let file: AVAudioFile?
        if checkpointDirectory == nil {
            file = try AVAudioFile(forWriting: outputURL, settings: format.settings)
            try SharedFileProtection.protectAudio(at: outputURL)
        } else {
            file = nil
        }
        let segmentID = UUID()
        let writer = try checkpointDirectory.map {
            try CheckpointingAudioWriter(
                continuousAudioURL: outputURL,
                checkpointDirectory: $0,
                format: format
            )
        }
        writer?.onFailure = { [weak self, weak writer, segmentID] failure in
            guard let writer else { return }
            self?.handleWriterFailure(
                failure,
                writer: writer,
                segmentID: segmentID
            )
        }

        lock.lock()
        state.activeFile = file
        state.checkpointWriter = writer
        state.activeURL = outputURL
        state.activeSegmentID = segmentID
        state.segmentFrames = 0
        state.lastInputBufferAt = nil
        state.lastStandbyInputBufferAt = nil
        state.isFinishingSegment = false
        lock.unlock()
    }

    private func handleWriterFailure(
        _ failure: CheckpointingAudioWriterFailure,
        writer: CheckpointingAudioWriter,
        segmentID: UUID
    ) {
        lock.lock()
        guard state.activeSegmentID == segmentID,
              state.checkpointWriter === writer,
              !state.isFinishingSegment
        else {
            lock.unlock()
            return
        }
        invalidateInputHealthLocked()
        let callback = onRecordingFailure
        lock.unlock()
        callback?(failure, segmentID)
    }

    @discardableResult
    func finishSegment() throws -> SegmentResult {
        graphMutationLock.lock()
        defer { graphMutationLock.unlock() }

        lock.lock()
        state.isFinishingSegment = true
        let url = state.activeURL
        let segmentID = state.activeSegmentID
        let writer = state.checkpointWriter
        lock.unlock()

        if segmentID != nil, writer == nil {
            fileWriteQueue.sync {}
        }

        let writerResult = writer?.finish()

        lock.lock()
        let frameCount = segmentID == state.activeSegmentID ? state.segmentFrames : 0
        state.activeFile = nil
        state.checkpointWriter = nil
        state.activeURL = nil
        state.activeSegmentID = nil
        state.segmentFrames = 0
        state.isFinishingSegment = false
        lock.unlock()

        let recordedFrames = writerResult?.totalFrames ?? frameCount
        guard let url, recordedFrames > 0 else {
            throw AudioRecorder.RecordingError.noRecording
        }
        return SegmentResult(
            audioURL: url,
            finalCheckpoint: writerResult?.finalCheckpoint,
            writerFailure: writerResult?.failure
        )
    }

    func rotateSegmentCheckpoint() -> MeetingAudioChunk? {
        lock.lock()
        let writer = state.checkpointWriter
        lock.unlock()
        return writer?.rotateCheckpoint()
    }

    func cancelSegment() {
        graphMutationLock.lock()
        defer { graphMutationLock.unlock() }

        lock.lock()
        state.isFinishingSegment = true
        let url = state.activeURL
        let segmentID = state.activeSegmentID
        let writer = state.checkpointWriter
        lock.unlock()

        if segmentID != nil, writer == nil {
            fileWriteQueue.sync {}
        }
        writer?.cancel()

        lock.lock()
        state.activeFile = nil
        state.checkpointWriter = nil
        state.activeURL = nil
        state.activeSegmentID = nil
        state.segmentFrames = 0
        state.isFinishingSegment = false
        lock.unlock()

        if let url {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func stop(deactivateSession: Bool = true) {
        graphMutationLock.lock()
        defer { graphMutationLock.unlock() }

        cancelSegment()
        let engine = currentEngine()
        tearDownGraph(engine)
        setConverter(nil)

        lock.lock()
        isStarting = false
        isEngineRunning = false
        state.latestPowerDB = -160
        state.lastInputBufferAt = nil
        state.lastStandbyInputBufferAt = nil
        lock.unlock()

        if deactivateSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func currentPower() -> Float {
        lock.lock()
        let value = state.latestPowerDB
        lock.unlock()
        return value
    }

    /// Fences the currently installed tap and clears its health evidence. This must
    /// be called as soon as an interruption/configuration event arrives so a callback
    /// already in flight before that event cannot satisfy a later health check.
    func invalidateInputHealth() {
        lock.lock()
        invalidateInputHealthLocked()
        lock.unlock()
    }

    /// Clears prior liveness evidence without invalidating the installed tap. A
    /// callback that began before this reset may still be written, but cannot make
    /// the post-event health probe pass; the next callback begins in the new epoch.
    func resetInputHealthEvidence() {
        lock.lock()
        state.inputHealthEpoch &+= 1
        state.lastInputBufferAt = nil
        state.lastStandbyInputBufferAt = nil
        state.latestPowerDB = -160
        lock.unlock()
    }

    func waitUntilCanAcceptStartCommand(timeout: TimeInterval = 1.5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if canAcceptStartCommand {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return canAcceptStartCommand
    }

    /// Repairs a phantom standby graph that reports running but is not delivering
    /// input callbacks. This method only starts the graph; callers must subsequently
    /// use `waitUntilCanAcceptStartCommand` so readiness is based on a real buffer.
    @discardableResult
    func ensureReadyForStartCommand(recreateEngine: Bool = false) throws -> Bool {
        graphMutationLock.lock()
        defer { graphMutationLock.unlock() }

        guard !isRecordingSegment else { return false }
        if canAcceptStartCommand, !recreateEngine {
            return true
        }

        _ = try AudioInputRouteManager.configureForRecording(
            stage: "keyboard standby recovery"
        )
        let targetFormat = try Self.makeTargetFormat()
        var engine = currentEngine()

        if recreateEngine {
            abandonGraphAfterMediaServicesReset(engine)
            engine = replaceEngine()
            setConverter(nil)
        } else {
            tearDownGraph(engine)
        }
        try configureAndInstallInputTap(on: engine, targetFormat: targetFormat)

        do {
            engine.prepare()
            try engine.start()
            setEngineRunning(engine.isRunning)
            return engine.isRunning
        } catch {
            tearDownGraph(engine)
            setEngineRunning(false)
            throw error
        }
    }

    /// Restarts the existing capture graph without replacing the active segment writer.
    /// This preserves the same continuous WAV/checkpoint sequence across lock-screen and
    /// competing-audio interruptions.
    @discardableResult
    func resumeCaptureIfNeeded(
        rebuildGraph: Bool = false,
        recreateEngine: Bool = false
    ) throws -> Bool {
        graphMutationLock.lock()
        defer { graphMutationLock.unlock() }

        guard isRecordingSegment else { return false }
        lock.lock()
        let inputHealthInvalidated = state.inputHealthInvalidated
        lock.unlock()
        let shouldRebuildGraph = rebuildGraph || inputHealthInvalidated
        var engine = currentEngine()
        if engine.isRunning, !shouldRebuildGraph, !recreateEngine {
            return true
        }

        _ = try AudioInputRouteManager.configureForRecording(
            stage: "keyboard voice note interruption recovery"
        )
        let targetFormat = try Self.makeTargetFormat()
        lock.lock()
        state.lastInputBufferAt = nil
        lock.unlock()

        if recreateEngine {
            abandonGraphAfterMediaServicesReset(engine)
            engine = replaceEngine()
            setConverter(nil)
            try configureAndInstallInputTap(on: engine, targetFormat: targetFormat)
        } else if shouldRebuildGraph {
            tearDownGraph(engine)
            try configureAndInstallInputTap(on: engine, targetFormat: targetFormat)
        } else {
            guard isTapInstalled else { return false }
        }

        do {
            engine.prepare()
            try engine.start()
            setEngineRunning(engine.isRunning)
            return engine.isRunning
        } catch {
            tearDownGraph(engine)
            setEngineRunning(false)
            throw error
        }
    }

    /// `AVAudioSession.mediaServicesWereResetNotification` invalidates the process's
    /// audio objects, not just the running graph. Recreate the engine while retaining
    /// the active segment's file/checkpoint writer and accumulated frame count.
    @discardableResult
    func recoverAfterMediaServicesReset() throws -> Bool {
        try resumeCaptureIfNeeded(rebuildGraph: true, recreateEngine: true)
    }

    private func handle(
        buffer: AVAudioPCMBuffer,
        targetFormat: AVAudioFormat,
        tapGeneration: UInt64
    ) {
        let file: AVAudioFile?
        let checkpointWriter: CheckpointingAudioWriter?
        let segmentID: UUID?
        let converter: AVAudioConverter?
        let inputHealthEpoch: UInt64

        lock.lock()
        guard tapGeneration == self.tapGeneration,
              !state.inputHealthInvalidated
        else {
            lock.unlock()
            return
        }
        if let activeFile = state.activeFile,
           let activeSegmentID = state.activeSegmentID,
           !state.isFinishingSegment
        {
            file = activeFile
            segmentID = activeSegmentID
            checkpointWriter = state.checkpointWriter
        } else if let activeSegmentID = state.activeSegmentID,
                  let writer = state.checkpointWriter,
                  !state.isFinishingSegment {
            file = nil
            segmentID = activeSegmentID
            checkpointWriter = writer
        } else {
            file = nil
            segmentID = nil
            checkpointWriter = nil
        }
        converter = self.converter
        inputHealthEpoch = state.inputHealthEpoch
        lock.unlock()

        guard let monoBuffer = convert(
            buffer: buffer,
            targetFormat: targetFormat,
            converter: converter
        ) else {
            invalidateInputHealth(ifCurrentTapGeneration: tapGeneration)
            return
        }
        let frameCount = Int(monoBuffer.frameLength)
        guard frameCount > 0 else { return }

        let powerDB = Self.powerDB(for: monoBuffer)
        let now = Date()
        guard let segmentID else {
            let handler: (@Sendable (Float, Bool, UUID?) -> Void)?
            lock.lock()
            let isCurrentStandbyInput = tapGeneration == self.tapGeneration
                && inputHealthEpoch == state.inputHealthEpoch
                && !state.inputHealthInvalidated
                && state.activeFile == nil
                && state.checkpointWriter == nil
            if isCurrentStandbyInput {
                handler = recordStandbyInputLocked(powerDB: powerDB, at: now)
            } else {
                handler = nil
            }
            lock.unlock()
            handler?(powerDB, false, nil)
            return
        }

        if let checkpointWriter {
            lock.lock()
            let shouldWrite = state.activeSegmentID == segmentID
                && state.checkpointWriter === checkpointWriter
                && !state.isFinishingSegment
                && tapGeneration == self.tapGeneration
                && !state.inputHealthInvalidated
            if shouldWrite {
                checkpointWriter.append(monoBuffer) { [weak self, weak checkpointWriter] in
                    guard let checkpointWriter else { return }
                    self?.recordSuccessfulCheckpointWrite(
                        segmentID: segmentID,
                        writer: checkpointWriter,
                        tapGeneration: tapGeneration,
                        inputHealthEpoch: inputHealthEpoch,
                        powerDB: powerDB,
                        receivedAt: now
                    )
                }
            }
            lock.unlock()
        } else if let file {
            let pendingWrite = PendingFileWrite(
                segmentID: segmentID,
                tapGeneration: tapGeneration,
                inputHealthEpoch: inputHealthEpoch,
                file: file,
                buffer: monoBuffer,
                frameCount: frameCount,
                powerDB: powerDB,
                receivedAt: now
            )
            lock.lock()
            let shouldEnqueue = state.activeSegmentID == segmentID
                && state.activeFile === file
                && !state.isFinishingSegment
                && tapGeneration == self.tapGeneration
                && !state.inputHealthInvalidated
            if shouldEnqueue {
                enqueue(pendingWrite)
            }
            lock.unlock()
        }
    }

    private func recordAcceptedInputLocked(
        powerDB: Float,
        at receivedAt: Date
    ) -> (@Sendable (Float, Bool, UUID?) -> Void)? {
        state.latestPowerDB = powerDB
        state.lastInputBufferAt = receivedAt
        guard receivedAt.timeIntervalSince(state.lastInputActivityNotifiedAt)
                >= Self.inputActivityNotificationInterval
        else {
            return nil
        }
        state.lastInputActivityNotifiedAt = receivedAt
        return inputActivityHandler
    }

    private func recordStandbyInputLocked(
        powerDB: Float,
        at receivedAt: Date
    ) -> (@Sendable (Float, Bool, UUID?) -> Void)? {
        state.latestPowerDB = powerDB
        state.lastStandbyInputBufferAt = receivedAt
        guard receivedAt.timeIntervalSince(state.lastInputActivityNotifiedAt) >= 0.5 else {
            return nil
        }
        state.lastInputActivityNotifiedAt = receivedAt
        return inputActivityHandler
    }

    private func enqueue(_ write: PendingFileWrite) {
        fileWriteQueue.async { [weak self] in
            do {
                try write.file.write(from: write.buffer)
                self?.recordSuccessfulFileWrite(write)
            } catch {
                self?.invalidateInputHealth(ifCurrentTapGeneration: write.tapGeneration)
            }
        }
    }

    private func recordSuccessfulFileWrite(_ write: PendingFileWrite) {
        let handler: (@Sendable (Float, Bool, UUID?) -> Void)?
        lock.lock()
        if state.activeSegmentID == write.segmentID,
           write.tapGeneration == tapGeneration,
           !state.inputHealthInvalidated,
           !state.isFinishingSegment
        {
            state.segmentFrames += AVAudioFramePosition(write.frameCount)
            if write.inputHealthEpoch == state.inputHealthEpoch {
                handler = recordAcceptedInputLocked(
                    powerDB: write.powerDB,
                    at: write.receivedAt
                )
            } else {
                handler = nil
            }
        } else {
            handler = nil
        }
        lock.unlock()
        handler?(write.powerDB, true, write.segmentID)
    }

    private func recordSuccessfulCheckpointWrite(
        segmentID: UUID,
        writer: CheckpointingAudioWriter,
        tapGeneration: UInt64,
        inputHealthEpoch: UInt64,
        powerDB: Float,
        receivedAt: Date
    ) {
        let handler: (@Sendable (Float, Bool, UUID?) -> Void)?
        lock.lock()
        if state.activeSegmentID == segmentID,
           state.checkpointWriter === writer,
           tapGeneration == self.tapGeneration,
           inputHealthEpoch == state.inputHealthEpoch,
           !state.inputHealthInvalidated,
           !state.isFinishingSegment
        {
            handler = recordAcceptedInputLocked(powerDB: powerDB, at: receivedAt)
        } else {
            handler = nil
        }
        lock.unlock()
        handler?(powerDB, true, segmentID)
    }

    private func convert(
        buffer: AVAudioPCMBuffer,
        targetFormat: AVAudioFormat,
        converter: AVAudioConverter?
    ) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0 else { return nil }
        guard let converter else {
            guard Self.formatsMatch(buffer.format, targetFormat) else { return nil }
            return copy(buffer)
        }

        guard Self.formatsMatch(buffer.format, converter.inputFormat),
              Self.formatsMatch(targetFormat, converter.outputFormat)
        else { return nil }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let frameCapacity = max(1, AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1)
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else { return nil }

        let inputState = ConverterInputState()
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, outStatus in
            guard !inputState.didProvideInput else {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputState.didProvideInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard error == nil,
              converted.frameLength > 0,
              Self.formatsMatch(converted.format, targetFormat)
        else { return nil }
        return converted
    }

    private func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }
        copy.frameLength = buffer.frameLength

        guard let source = buffer.floatChannelData,
              let destination = copy.floatChannelData
        else {
            return nil
        }

        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        for channel in 0..<channelCount {
            destination[channel].update(from: source[channel], count: frameLength)
        }
        return copy
    }

    private static func powerDB(for buffer: AVAudioPCMBuffer) -> Float {
        guard let floatData = buffer.floatChannelData?[0] else { return -160 }

        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return -160 }

        var sumSquares: Float = 0
        for index in 0..<frameCount {
            let sample = floatData[index]
            sumSquares += sample * sample
        }

        let rms = sqrt(sumSquares / Float(frameCount))
        return rms > 0.000_001 ? max(-160, min(0, 20 * log10(rms))) : -160
    }

    private func cleanupAfterFailedStart() {
        graphMutationLock.lock()
        defer { graphMutationLock.unlock() }

        let engine = currentEngine()
        tearDownGraph(engine)
        setConverter(nil)
        lock.lock()
        state = FileState()
        isStarting = false
        isEngineRunning = false
        lock.unlock()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func prepareForStart() {
        let engine = currentEngine()
        tearDownGraph(engine)
        setConverter(nil)

        lock.lock()
        state.activeFile = nil
        state.activeURL = nil
        state.activeSegmentID = nil
        state.segmentFrames = 0
        state.lastInputBufferAt = nil
        state.lastStandbyInputBufferAt = nil
        state.isFinishingSegment = false
        isEngineRunning = false
        lock.unlock()
    }

    private func beginStartingIfNeeded() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let engine = self.engine
        guard !isStarting, !(isEngineRunning && engine.isRunning) else {
            return false
        }
        isStarting = true
        return true
    }

    private var isTapInstalled: Bool {
        lock.lock()
        let installed = tapInstalled
        lock.unlock()
        return installed
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

    private func withGraphMutationLock<T>(_ body: () throws -> T) rethrows -> T {
        graphMutationLock.lock()
        defer { graphMutationLock.unlock() }
        return try body()
    }

    private func replaceEngine() -> AVAudioEngine {
        let replacement = AVAudioEngine()
        lock.lock()
        engine = replacement
        tapInstalled = false
        isEngineRunning = false
        lock.unlock()
        return replacement
    }

    private func activateTapGeneration() -> UInt64 {
        lock.lock()
        tapGeneration &+= 1
        state.inputHealthEpoch &+= 1
        state.inputHealthInvalidated = false
        state.lastInputBufferAt = nil
        state.lastStandbyInputBufferAt = nil
        let generation = tapGeneration
        lock.unlock()
        return generation
    }

    private func invalidateInputHealthLocked() {
        tapGeneration &+= 1
        state.inputHealthEpoch &+= 1
        state.inputHealthInvalidated = true
        state.lastInputBufferAt = nil
        state.lastStandbyInputBufferAt = nil
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
    ) throws {
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        setConverter(
            Self.requiresConversion(from: inputFormat, to: targetFormat)
                ? AVAudioConverter(from: inputFormat, to: targetFormat)
                : nil
        )
        installInputTap(on: engine, targetFormat: targetFormat)
        setTapInstalled(true)
    }

    private func tearDownGraph(_ engine: AVAudioEngine) {
        if isTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            setTapInstalled(false)
        }
        engine.stop()
        invalidateInputHealth()
    }

    private func abandonGraphAfterMediaServicesReset(_ engine: AVAudioEngine) {
        // The reset invalidates the old audio objects. Do not query the old input
        // node merely to remove its tap; stop it and fence any late callbacks.
        engine.stop()
        setTapInstalled(false)
        invalidateInputHealth()
    }

    private func setEngineStarting(_ starting: Bool) {
        lock.lock()
        isStarting = starting
        lock.unlock()
    }

    private func setEngineRunning(_ running: Bool) {
        lock.lock()
        isStarting = false
        isEngineRunning = running
        lock.unlock()
    }

    private static func makeTargetFormat() throws -> AVAudioFormat {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioRecorder.RecordingError.startFailed(stage: "keyboard session format")
        }
        return format
    }

    private static func requiresConversion(from inputFormat: AVAudioFormat, to targetFormat: AVAudioFormat) -> Bool {
        !formatsMatch(inputFormat, targetFormat)
    }

    private static func formatsMatch(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.sampleRate == rhs.sampleRate
            && lhs.channelCount == rhs.channelCount
            && lhs.commonFormat == rhs.commonFormat
            && lhs.isInterleaved == rhs.isInterleaved
    }
}
