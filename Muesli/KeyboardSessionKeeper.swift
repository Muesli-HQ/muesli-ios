import AVFoundation
import Foundation
import os

final class KeyboardSessionKeeper: @unchecked Sendable {
    private struct FileState {
        var activeFile: AVAudioFile?
        var activeURL: URL?
        var activeSegmentID: UUID?
        var latestPowerDB: Float = -160
        var segmentFrames: AVAudioFramePosition = 0
        var lastInputBufferAt: Date?
        var lastInputActivityNotifiedAt = Date.distantPast
        var isFinishingSegment = false
    }

    private struct PendingFileWrite: @unchecked Sendable {
        let segmentID: UUID
        let file: AVAudioFile
        let buffer: AVAudioPCMBuffer
        let frameCount: Int
    }

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private let fileWriteQueue = DispatchQueue(label: "com.muesli.keyboardSessionKeeper.fileWrite")
    private var state = FileState()
    private var converter: AVAudioConverter?
    private var isEngineRunning = false
    private var isStarting = false
    private var tapInstalled = false
    private var inputActivityHandler: (@Sendable (_ powerDB: Float, _ isCapturing: Bool) -> Void)?

    private static let sampleRate: Double = 16_000
    private static let bufferSize: AVAudioFrameCount = 2_048

    static func discardAudioTap(_ buffer: AVAudioPCMBuffer, when _: AVAudioTime) {
        _ = buffer.frameLength
    }

    var isRunning: Bool {
        lock.lock()
        let shouldBeRunning = isEngineRunning
        lock.unlock()
        return shouldBeRunning && engine.isRunning
    }

    var canAcceptStartCommand: Bool {
        lock.lock()
        let shouldBeRunning = isEngineRunning
        let hasTap = tapInstalled
        lock.unlock()

        return shouldBeRunning && hasTap && engine.isRunning
    }

    var isRecordingSegment: Bool {
        lock.lock()
        let recording = state.activeFile != nil
        lock.unlock()
        return recording
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
            _ = try AudioInputRouteManager.configureForRecording(stage: "keyboard session")
            prepareForStart()

            let targetFormat = try Self.makeTargetFormat()
            let inputNode = engine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)
            converter = inputFormat.sampleRate != targetFormat.sampleRate || inputFormat.channelCount != targetFormat.channelCount
                ? AVAudioConverter(from: inputFormat, to: targetFormat)
                : nil

            inputNode.installTap(onBus: 0, bufferSize: Self.bufferSize, format: nil) { [weak self] buffer, _ in
                self?.handle(buffer: buffer, targetFormat: targetFormat)
            }
            setTapInstalled(true)
            engine.prepare()
            try engine.start()

            setEngineRunning(true)
        } catch {
            cleanupAfterFailedStart()
            if error is AudioRecorder.RecordingError {
                throw error
            }
            throw AudioRecorder.RecordingError.startFailed(stage: "keyboard session")
        }
    }

    func setInputActivityHandler(
        _ handler: (@Sendable (_ powerDB: Float, _ isCapturing: Bool) -> Void)?
    ) {
        lock.lock()
        inputActivityHandler = handler
        lock.unlock()
    }

    func beginSegment(outputURL: URL) throws {
        guard isRunning else {
            throw AudioRecorder.RecordingError.startFailed(stage: "keyboard session inactive")
        }

        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let file = try AVAudioFile(forWriting: outputURL, settings: Self.makeTargetFormat().settings)
        let segmentID = UUID()

        lock.lock()
        state.activeFile = file
        state.activeURL = outputURL
        state.activeSegmentID = segmentID
        state.segmentFrames = 0
        state.isFinishingSegment = false
        lock.unlock()
    }

    @discardableResult
    func finishSegment() throws -> URL {
        lock.lock()
        state.isFinishingSegment = true
        let url = state.activeURL
        let segmentID = state.activeSegmentID
        lock.unlock()

        if segmentID != nil {
            fileWriteQueue.sync {}
        }

        lock.lock()
        let frameCount = segmentID == state.activeSegmentID ? state.segmentFrames : 0
        state.activeFile = nil
        state.activeURL = nil
        state.activeSegmentID = nil
        state.segmentFrames = 0
        state.isFinishingSegment = false
        lock.unlock()

        guard let url, frameCount > 0 else {
            throw AudioRecorder.RecordingError.noRecording
        }
        return url
    }

    func cancelSegment() {
        lock.lock()
        state.isFinishingSegment = true
        let url = state.activeURL
        let segmentID = state.activeSegmentID
        lock.unlock()

        if segmentID != nil {
            fileWriteQueue.sync {}
        }

        lock.lock()
        state.activeFile = nil
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
        cancelSegment()
        if isTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            setTapInstalled(false)
        }
        engine.stop()
        converter = nil

        lock.lock()
        isStarting = false
        isEngineRunning = false
        state.latestPowerDB = -160
        state.lastInputBufferAt = nil
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

    private func handle(buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) {
        markInputBufferReceived()

        guard let monoBuffer = convert(buffer: buffer, targetFormat: targetFormat),
              let floatData = monoBuffer.floatChannelData?[0]
        else { return }

        let frameCount = Int(monoBuffer.frameLength)
        guard frameCount > 0 else { return }

        var sumSquares: Float = 0
        for index in 0..<frameCount {
            let sample = floatData[index]
            sumSquares += sample * sample
        }
        let rms = sqrt(sumSquares / Float(frameCount))
        let powerDB = rms > 0.000_001 ? max(-160, min(0, 20 * log10(rms))) : -160

        let handler: (@Sendable (_ powerDB: Float, _ isCapturing: Bool) -> Void)?
        let shouldNotifyActivity: Bool
        let isCapturing: Bool
        let now = Date()

        lock.lock()
        if let file = state.activeFile,
           let segmentID = state.activeSegmentID,
           !state.isFinishingSegment
        {
            enqueue(PendingFileWrite(
                segmentID: segmentID,
                file: file,
                buffer: monoBuffer,
                frameCount: frameCount
            ))
            isCapturing = true
        } else {
            isCapturing = false
        }
        state.latestPowerDB = powerDB
        state.lastInputBufferAt = now
        shouldNotifyActivity = now.timeIntervalSince(state.lastInputActivityNotifiedAt) >= 0.5
        if shouldNotifyActivity {
            state.lastInputActivityNotifiedAt = now
        }
        handler = inputActivityHandler
        lock.unlock()

        if shouldNotifyActivity {
            handler?(powerDB, isCapturing)
        }
    }

    private func enqueue(_ write: PendingFileWrite) {
        fileWriteQueue.async { [weak self] in
            do {
                try write.file.write(from: write.buffer)
                self?.recordWrittenFrames(write.frameCount, for: write.segmentID)
            } catch {
                // Preserve the live session; stop/finish will surface missing audio if writes fail.
            }
        }
    }

    private func recordWrittenFrames(_ frameCount: Int, for segmentID: UUID) {
        lock.lock()
        if state.activeSegmentID == segmentID {
            state.segmentFrames += AVAudioFramePosition(frameCount)
        }
        lock.unlock()
    }

    private func markInputBufferReceived() {
        lock.lock()
        state.lastInputBufferAt = Date()
        lock.unlock()
    }

    private func convert(buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let converter else {
            return buffer
        }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let frameCapacity = max(1, AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1)
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else { return nil }

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

        guard error == nil else { return nil }
        return converted
    }

    private func cleanupAfterFailedStart() {
        if isTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            setTapInstalled(false)
        }
        engine.stop()
        converter = nil
        lock.lock()
        state = FileState()
        isStarting = false
        isEngineRunning = false
        lock.unlock()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func prepareForStart() {
        if isTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            setTapInstalled(false)
        }
        engine.stop()
        converter = nil

        lock.lock()
        state.activeFile = nil
        state.activeURL = nil
        state.activeSegmentID = nil
        state.segmentFrames = 0
        state.lastInputBufferAt = nil
        state.isFinishingSegment = false
        isEngineRunning = false
        lock.unlock()
    }

    private func beginStartingIfNeeded() -> Bool {
        lock.lock()
        defer { lock.unlock() }
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
}
