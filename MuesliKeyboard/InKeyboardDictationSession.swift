import AVFoundation
import Foundation
import Speech
import UIKit

/// Why in-keyboard dictation cannot run right now. The keyboard falls back to
/// the Muesli handoff in every case except `.available`.
enum InKeyboardDictationAvailability: Equatable, Sendable {
    case available
    case disabled
    case needsFullAccess
    case needsMicrophonePermission
    case needsSpeechPermission
    case onDeviceRecognitionUnsupported
    case recognizerUnavailable
    case captureNotReady
    /// The microphone failed to start in this keyboard session (for example
    /// `getUserMedia` was rejected). Cleared when the capture page reloads.
    case captureFailed

    var fallbackReason: String {
        switch self {
        case .available: "available"
        case .disabled: "disabled"
        case .needsFullAccess: "fullAccess"
        case .needsMicrophonePermission: "microphonePermission"
        case .needsSpeechPermission: "speechPermission"
        case .onDeviceRecognitionUnsupported: "onDeviceUnsupported"
        case .recognizerUnavailable: "recognizerUnavailable"
        case .captureNotReady: "captureNotReady"
        case .captureFailed: "captureFailed"
        }
    }
}

struct InKeyboardDictationHandlers {
    var onListening: @MainActor () -> Void = {}
    var onPartial: @MainActor (String) -> Void = { _ in }
    var onLevel: @MainActor (Double) -> Void = { _ in }
    /// Final transcript (possibly empty when no speech was heard).
    var onCompleted: @MainActor (String) -> Void = { _ in }
    var onFailed: @MainActor (String) -> Void = { _ in }
}

/// In-keyboard dictation engine, abstracted so `KeyboardController` is
/// testable without WebKit or Speech.
@MainActor
protocol InKeyboardDictating: AnyObject {
    func availability(hasFullAccess: Bool) -> InKeyboardDictationAvailability
    /// Returns false if capture could not be started; no handler fires then.
    func start(handlers: InKeyboardDictationHandlers) -> Bool
    /// Stops the microphone and delivers the final transcript via `onCompleted`.
    func finish()
    /// Stops the microphone and discards the transcript. No handler fires.
    func cancel()
}

/// Records with `WebAudioCapture` and transcribes with Apple Speech, forced
/// on-device so audio never leaves the iPhone (matching Muesli's local-first
/// default). Muesli's Parakeet/Whisper models stay in the app: they do not fit
/// a keyboard extension's memory budget.
@MainActor
final class InKeyboardDictationSession: InKeyboardDictating {
    static let engineIdentifier = "apple-speech-keyboard"
    private static let finalResultTimeout: Duration = .seconds(4)

    private let capture = WebAudioCapture()
    private let recognizer: SFSpeechRecognizer?
    private let audioFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: WebAudioCapture.sampleRate,
        channels: 1,
        interleaved: true
    )
    private let isPreferenceEnabled: () -> Bool

    /// Fires when the capture page loads (or reloads after a WebKit crash).
    var onReady: (() -> Void)?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var handlers: InKeyboardDictationHandlers?
    private var latestTranscript = ""
    private var finalResultTimeoutTask: Task<Void, Never>?
    /// Incremented per recording so Speech callbacks that hop to the main
    /// actor after a cancel cannot drive the next recording.
    private var generation = 0
    private var didStartCapture = false
    private var captureStartFailed = false

    init(
        locale: Locale = .current,
        isPreferenceEnabled: @escaping () -> Bool = { InKeyboardDictationPreferences.isEnabled() }
    ) {
        recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        self.isPreferenceEnabled = isPreferenceEnabled
        capture.onReady = { [weak self] in
            self?.captureStartFailed = false
            self?.onReady?()
        }
        capture.onStarted = { [weak self] in
            guard let self, self.handlers != nil else { return }
            self.didStartCapture = true
            self.handlers?.onListening()
        }
        capture.onAudio = { [weak self] data, rms in self?.append(data, rms: rms) }
        capture.onEnded = { [weak self] reason in self?.captureEnded(reason) }
    }

    /// Hosts the hidden capture web view. Call once the keyboard view exists.
    func attach(to view: UIView) {
        capture.attach(to: view)
    }

    func tearDown() {
        cancel()
        capture.tearDown()
    }

    func availability(hasFullAccess: Bool) -> InKeyboardDictationAvailability {
        guard isPreferenceEnabled() else { return .disabled }
        guard hasFullAccess else { return .needsFullAccess }
        guard AVAudioApplication.shared.recordPermission == .granted else { return .needsMicrophonePermission }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { return .needsSpeechPermission }
        guard let recognizer else { return .recognizerUnavailable }
        guard recognizer.supportsOnDeviceRecognition else { return .onDeviceRecognitionUnsupported }
        guard recognizer.isAvailable else { return .recognizerUnavailable }
        guard capture.isReady else { return .captureNotReady }
        guard !captureStartFailed else { return .captureFailed }
        return .available
    }

    func start(handlers: InKeyboardDictationHandlers) -> Bool {
        guard self.handlers == nil, let recognizer, capture.isReady, !captureStartFailed else { return false }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true
        request.taskHint = .dictation

        self.request = request
        self.handlers = handlers
        latestTranscript = ""
        didStartCapture = false
        generation += 1
        let generation = generation
        task = recognizer.recognitionTask(
            with: request,
            resultHandler: Self.makeResultHandler { [weak self] update in
                guard let self, self.generation == generation else { return }
                self.handleRecognition(update)
            }
        )
        capture.start()
        return true
    }

    func finish() {
        guard handlers != nil else { return }
        capture.stop()
    }

    func cancel() {
        guard handlers != nil else { return }
        reset()
    }

    private func append(_ data: Data, rms: Float) {
        handlers?.onLevel(Double(min(max(rms * 8, 0), 1)))
        let frames = AVAudioFrameCount(data.count / MemoryLayout<Int16>.size)
        guard frames > 0,
              let request,
              let audioFormat,
              let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: frames),
              let channel = buffer.int16ChannelData?[0] else { return }
        buffer.frameLength = frames
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: Int16.self).baseAddress else { return }
            channel.update(from: base, count: Int(frames))
        }
        request.append(buffer)
    }

    private func captureEnded(_ reason: String) {
        guard handlers != nil else { return }
        KeyboardDiagnosticsLog.record("inline.captureEnded", [
            "reason": reason == WebAudioCapture.stoppedReason ? "stopped" : String(reason.prefix(48))
        ])
        if reason != WebAudioCapture.stoppedReason, !didStartCapture {
            // The microphone never started, so there is nothing to transcribe.
            // Fail now and route the next Record to the Muesli handoff.
            captureStartFailed = true
            fail(reason)
            return
        }
        request?.endAudio()
        // Speech normally answers endAudio() with a final result; don't let a
        // missing one strand the keyboard in "Transcribing".
        finalResultTimeoutTask?.cancel()
        finalResultTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.finalResultTimeout)
            guard !Task.isCancelled, let self else { return }
            self.complete(with: self.latestTranscript)
        }
    }

    private func handleRecognition(_ update: RecognitionUpdate) {
        let text = update.text
        let isFinal = update.isFinal
        let errorDescription = update.errorDescription
        let isNoSpeechError = update.isNoSpeechError
        guard let handlers else { return }
        if let text {
            latestTranscript = text
            if isFinal {
                complete(with: text)
            } else {
                handlers.onPartial(text)
            }
            return
        }
        guard let errorDescription else { return }
        if isNoSpeechError || !latestTranscript.isEmpty {
            complete(with: latestTranscript)
        } else {
            fail(errorDescription)
        }
    }

    private func complete(with text: String) {
        guard let handlers else { return }
        reset()
        handlers.onCompleted(text)
    }

    private func fail(_ message: String) {
        guard let handlers else { return }
        reset()
        handlers.onFailed(message)
    }

    private func reset() {
        handlers = nil
        generation += 1
        didStartCapture = false
        finalResultTimeoutTask?.cancel()
        finalResultTimeoutTask = nil
        task?.cancel()
        task = nil
        request = nil
        latestTranscript = ""
        if capture.isCapturing { capture.stop() }
    }

    fileprivate struct RecognitionUpdate: Sendable {
        let text: String?
        let isFinal: Bool
        let errorDescription: String?
        let isNoSpeechError: Bool
    }

    /// Built outside main-actor isolation: Speech calls this on its own queue,
    /// and a closure inferred as @MainActor would trap there under Swift 6.
    nonisolated private static func makeResultHandler(
        deliver: @escaping @MainActor @Sendable (RecognitionUpdate) -> Void
    ) -> @Sendable (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            // Extract Sendable values before hopping off Speech's queue.
            let update = RecognitionUpdate(
                text: result?.bestTranscription.formattedString,
                isFinal: result?.isFinal ?? false,
                errorDescription: error.map { ($0 as NSError).localizedDescription },
                isNoSpeechError: error.map(isNoSpeechError) ?? false
            )
            Task { @MainActor in deliver(update) }
        }
    }

    /// kAFAssistantErrorDomain 1110: "No speech detected".
    nonisolated private static func isNoSpeechError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1110
    }
}
