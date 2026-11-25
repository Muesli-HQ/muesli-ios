import AVFoundation
import Foundation
import Speech
import UIKit

/// Why in-keyboard dictation cannot run right now. The keyboard falls back to
/// the Muesli handoff in every case except `.available`.
enum InKeyboardDictationAvailability: Equatable, Sendable {
    case available
    /// This keyboard has no in-keyboard session (for example no Full Access).
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

/// Joins Apple Speech results into one transcript for the whole recording.
///
/// On-device dictation ends an utterance after a pause and starts the next
/// result from empty, so `bestTranscription` only ever holds the latest
/// utterance. Using it alone inserted just the last sentence. Utterances are
/// committed when Speech marks one finished (`speechRecognitionMetadata`) or
/// when a result starts later in the audio than the one before it.
struct InKeyboardTranscriptAccumulator: Equatable, Sendable {
    /// Corrections of one utterance keep its start time; a new utterance
    /// starts at least this much later.
    static let restartThreshold: TimeInterval = 0.5

    private struct Utterance: Equatable, Sendable {
        var text: String
        var start: TimeInterval?
    }

    private var committed: [Utterance] = []
    private var current = Utterance(text: "", start: nil)

    var text: String {
        (committed + [current])
            .map(\.text)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// - Parameters:
    ///   - start: timestamp of the result's first segment, if any.
    ///   - endsUtterance: Speech attached utterance metadata to this result.
    mutating func apply(_ result: String, start: TimeInterval?, endsUtterance: Bool) {
        let next = Utterance(text: result.trimmingCharacters(in: .whitespacesAndNewlines), start: start)
        if let first = committed.first, Self.sameStart(start, first.start),
           Self.normalized(next.text).hasPrefix(Self.normalized(committed.map(\.text).joined(separator: " "))) {
            // Speech did not restart: this result covers the whole recording.
            committed = []
        } else if current.text.isEmpty, let last = committed.last, Self.sameStart(start, last.start),
                  Self.overlaps(next.text, last.text) {
            // A repeat of the utterance just committed (for example the final
            // result after endAudio()): replace it instead of adding it twice.
            committed.removeLast()
        } else if !current.text.isEmpty, !Self.sameStart(start, current.start) {
            commitCurrent()
        }
        if !next.text.isEmpty || current.text.isEmpty { current = next }
        if endsUtterance { commitCurrent() }
    }

    private mutating func commitCurrent() {
        if !current.text.isEmpty { committed.append(current) }
        current = Utterance(text: "", start: nil)
    }

    /// Results without timing are treated as revisions of the same utterance.
    private static func sameStart(_ lhs: TimeInterval?, _ rhs: TimeInterval?) -> Bool {
        guard let lhs, let rhs else { return true }
        return abs(lhs - rhs) <= restartThreshold
    }

    /// True when one text extends the other, as revisions of one utterance do.
    private static func overlaps(_ lhs: String, _ rhs: String) -> Bool {
        let lhs = normalized(lhs), rhs = normalized(rhs)
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        return lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs)
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

struct InKeyboardDictationHandlers {
    var onListening: @MainActor () -> Void = {}
    var onPartial: @MainActor (String) -> Void = { _ in }
    var onLevel: @MainActor (Double) -> Void = { _ in }
    /// The recording ended while the keyboard model is still loading; the
    /// transcript waits for it. Carries the model's name.
    var onPreparingModel: @MainActor (String) -> Void = { _ in }
    /// Final transcript (possibly empty when no speech was heard) and the
    /// engine that produced it.
    var onCompleted: @MainActor (String, String) -> Void = { _, _ in }
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

/// A speech model that runs inside the keyboard process (Parakeet, shared by
/// the app). Abstracted so the session is testable without FluidAudio.
@MainActor
protocol InKeyboardModelTranscribing: AnyObject {
    /// Loaded, or loading: a recording can rely on it either way, because
    /// `transcribe` waits for a load in progress.
    var canTranscribe: Bool { get }
    /// Still loading (compiling the first time, otherwise a warm load).
    var isPreparing: Bool { get }
    var displayName: String? { get }
    var engineIdentifier: String? { get }
    func transcribe(_ samples: [Float]) async throws -> String
}

/// Records with `WebAudioCapture` and transcribes on the iPhone, so audio never
/// leaves it. When the app has shared a Parakeet model that fits the keyboard's
/// memory, Parakeet writes the final text. Apple Speech (forced on-device)
/// streams the live partials and is the fallback whenever Parakeet is not
/// ready, the recording is too long for it, or it fails.
@MainActor
final class InKeyboardDictationSession: InKeyboardDictating {
    static let engineIdentifier = "apple-speech-keyboard"
    private static let finalResultTimeout: Duration = .seconds(4)
    private static let maximumModelSamples = Int(KeyboardSpeechModel.maximumDurationSeconds * WebAudioCapture.sampleRate)

    private let capture = WebAudioCapture()
    private let recognizer: SFSpeechRecognizer?
    private let audioFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: WebAudioCapture.sampleRate,
        channels: 1,
        interleaved: true
    )
    private let model: (any InKeyboardModelTranscribing)?

    /// Fires when the capture page loads (or reloads after a WebKit crash).
    var onReady: (() -> Void)?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var handlers: InKeyboardDictationHandlers?
    private var transcript = InKeyboardTranscriptAccumulator()
    private var finalResultTimeoutTask: Task<Void, Never>?
    /// Incremented per recording so Speech callbacks that hop to the main
    /// actor after a cancel cannot drive the next recording.
    private var generation = 0
    private var didStartCapture = false
    private var captureStartFailed = false
    /// This recording's audio for the keyboard model, if it is in use.
    private var modelSamples: [Int16]?
    private var modelSamplesOverflowed = false
    private var modelTranscriptionTask: Task<Void, Never>?

    init(
        locale: Locale = .current,
        model: (any InKeyboardModelTranscribing)? = nil
    ) {
        recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        self.model = model
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
        guard hasFullAccess else { return .needsFullAccess }
        guard AVAudioApplication.shared.recordPermission == .granted else { return .needsMicrophonePermission }
        if model?.canTranscribe != true {
            // Without the keyboard model, Apple Speech must be usable.
            guard SFSpeechRecognizer.authorizationStatus() == .authorized else { return .needsSpeechPermission }
            guard let recognizer else { return .recognizerUnavailable }
            guard recognizer.supportsOnDeviceRecognition else { return .onDeviceRecognitionUnsupported }
            guard recognizer.isAvailable else { return .recognizerUnavailable }
        }
        guard capture.isReady else { return .captureNotReady }
        guard !captureStartFailed else { return .captureFailed }
        return .available
    }

    func start(handlers: InKeyboardDictationHandlers) -> Bool {
        guard self.handlers == nil, capture.isReady, !captureStartFailed else { return false }
        let usesModel = model?.canTranscribe == true
        let appleRecognizer = Self.usableAppleRecognizer(recognizer)
        guard usesModel || appleRecognizer != nil else { return false }

        self.handlers = handlers
        transcript = InKeyboardTranscriptAccumulator()
        didStartCapture = false
        modelSamples = usesModel ? [] : nil
        modelSamplesOverflowed = false
        generation += 1
        let generation = generation
        if let appleRecognizer {
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = true
            request.addsPunctuation = true
            request.taskHint = .dictation
            self.request = request
            task = appleRecognizer.recognitionTask(
                with: request,
                resultHandler: Self.makeResultHandler { [weak self] update in
                    guard let self, self.generation == generation else { return }
                    self.handleRecognition(update)
                }
            )
        }
        KeyboardDiagnosticsLog.record("inline.engine", [
            "final": usesModel ? (model?.engineIdentifier ?? "model") : Self.engineIdentifier,
            "partials": appleRecognizer == nil ? "none" : "apple"
        ])
        capture.start()
        return true
    }

    private static func usableAppleRecognizer(_ recognizer: SFSpeechRecognizer?) -> SFSpeechRecognizer? {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              let recognizer,
              recognizer.supportsOnDeviceRecognition,
              recognizer.isAvailable else { return nil }
        return recognizer
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
        if frames > 0, modelSamples != nil, !modelSamplesOverflowed {
            if modelSamples!.count + Int(frames) > Self.maximumModelSamples {
                // Too long for the keyboard model; Apple Speech's text is used.
                modelSamplesOverflowed = true
                modelSamples = []
            } else {
                data.withUnsafeBytes { raw in
                    modelSamples!.append(contentsOf: raw.bindMemory(to: Int16.self))
                }
            }
        }
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
        if let samples = modelSamples, !modelSamplesOverflowed, !samples.isEmpty, let model {
            transcribeWithModel(model, samples: samples)
            return
        }
        if request == nil {
            // No Apple Speech fallback is running (keyboard model only).
            complete(with: "", engine: model?.engineIdentifier ?? Self.engineIdentifier)
            return
        }
        // Speech normally answers endAudio() with a final result; don't let a
        // missing one strand the keyboard in "Transcribing".
        finalResultTimeoutTask?.cancel()
        finalResultTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.finalResultTimeout)
            guard !Task.isCancelled, let self else { return }
            self.complete(with: self.transcript.text, engine: Self.engineIdentifier)
        }
    }

    /// Parakeet writes the final text; Apple Speech's transcript so far is the
    /// fallback if it fails.
    private func transcribeWithModel(_ model: any InKeyboardModelTranscribing, samples: [Int16]) {
        modelSamples = nil
        let generation = generation
        let engine = model.engineIdentifier ?? "parakeet-keyboard"
        if model.isPreparing {
            handlers?.onPreparingModel(model.displayName ?? "your model")
        }
        modelTranscriptionTask = Task { @MainActor [weak self] in
            let floats = samples.map { Float($0) / Float(Int16.max) }
            let result: Result<String, Error>
            do {
                result = .success(try await model.transcribe(floats))
            } catch {
                result = .failure(error)
            }
            guard let self, self.generation == generation, !Task.isCancelled else { return }
            switch result {
            case .success(let text) where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                self.complete(with: text, engine: engine)
            case .success:
                // Parakeet heard nothing; trust Apple's text if it has any.
                self.complete(with: self.transcript.text, engine: Self.engineIdentifier)
            case .failure(let error):
                KeyboardDiagnosticsLog.record("inline.modelFailed", [
                    "reason": String(String(describing: error).prefix(48))
                ])
                if self.transcript.text.isEmpty {
                    self.fail(error.localizedDescription)
                } else {
                    self.complete(with: self.transcript.text, engine: Self.engineIdentifier)
                }
            }
        }
    }

    private func handleRecognition(_ update: RecognitionUpdate) {
        let text = update.text
        let isFinal = update.isFinal
        let errorDescription = update.errorDescription
        let isNoSpeechError = update.isNoSpeechError
        guard let handlers else { return }
        // With the keyboard model writing the final text, Apple Speech only
        // feeds partials: its final result or error must not end the session.
        let feedsPartialsOnly = modelSamples != nil || modelTranscriptionTask != nil
        if let text {
            transcript.apply(text, start: update.firstSegmentStart, endsUtterance: update.endsUtterance)
            if isFinal, !feedsPartialsOnly {
                complete(with: transcript.text, engine: Self.engineIdentifier)
            } else if !isFinal {
                handlers.onPartial(transcript.text)
            }
            return
        }
        guard let errorDescription, !feedsPartialsOnly else { return }
        if isNoSpeechError || !transcript.text.isEmpty {
            complete(with: transcript.text, engine: Self.engineIdentifier)
        } else {
            fail(errorDescription)
        }
    }

    private func complete(with text: String, engine: String) {
        guard let handlers else { return }
        reset()
        handlers.onCompleted(text, engine)
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
        modelTranscriptionTask?.cancel()
        modelTranscriptionTask = nil
        modelSamples = nil
        modelSamplesOverflowed = false
        task?.cancel()
        task = nil
        request = nil
        transcript = InKeyboardTranscriptAccumulator()
        if capture.isCapturing { capture.stop() }
    }

    fileprivate struct RecognitionUpdate: Sendable {
        let text: String?
        let firstSegmentStart: TimeInterval?
        let endsUtterance: Bool
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
                firstSegmentStart: result?.bestTranscription.segments.first?.timestamp,
                endsUtterance: result?.speechRecognitionMetadata != nil,
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
