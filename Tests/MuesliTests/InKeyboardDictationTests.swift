import AVFoundation
import Speech
import XCTest
@testable import Muesli

/// Drives `KeyboardController`'s in-keyboard dictation path with a fake engine,
/// so WebKit capture and Apple Speech are out of the loop.
@MainActor
final class InKeyboardDictationTests: XCTestCase {
    private var directory: URL!
    private var store: SharedStore!
    private var controller: KeyboardController!
    private var engine: FakeInKeyboardDictation!
    private var insertedText: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("in-keyboard-dictation-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bus = BufferedEventBus()
        store = SharedStore(containerURL: directory, eventPoster: bus)
        controller = KeyboardController(store: store, eventBus: bus)
        engine = FakeInKeyboardDictation()
        controller.inKeyboardDictation = engine
        controller.currentFullAccess = { true }
        insertedText = []
        controller.textInserter = { [weak self] text in self?.insertedText.append(text) }
        controller.prepareInitialPresentationState()
    }

    override func tearDown() async throws {
        controller = nil
        engine = nil
        store = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try await super.tearDown()
    }

    func testUnavailableEngineFallsBackToMuesliHandoff() throws {
        engine.availability = .needsSpeechPermission
        controller.refreshInKeyboardAvailability()
        XCTAssertTrue(controller.opensMuesliFromPrimaryButton)

        controller.startDictation()

        XCTAssertEqual(engine.startCount, 0)
        XCTAssertFalse(controller.isInKeyboardCaptureActive)
        XCTAssertEqual(controller.dictationPhase, .requested)
        XCTAssertNotNil(try store.keyboardHandoffState().requestID, "handoff claimed a request")
    }

    func testAvailableEngineRecordsInKeyboardWithoutOpeningMuesli() throws {
        controller.refreshInKeyboardAvailability()
        XCTAssertFalse(controller.opensMuesliFromPrimaryButton, "Record must not be a Link to Muesli")

        controller.startDictation()

        XCTAssertEqual(engine.startCount, 1)
        XCTAssertTrue(controller.isInKeyboardCaptureActive)
        XCTAssertEqual(controller.dictationPhase, .recording)
        XCTAssertEqual(controller.primaryButtonRole, .stop)
        XCTAssertNil(try store.keyboardHandoffState().requestID, "no handoff request is claimed")
    }

    func testMountedLaunchLinkUsesHandoffEvenWhenInlineCaptureBecomesAvailable() throws {
        engine.availability = .captureNotReady
        controller.refreshInKeyboardAvailability()
        XCTAssertTrue(controller.opensMuesliFromPrimaryButton)

        engine.availability = .available
        controller.primaryLaunchAction()

        XCTAssertEqual(engine.startCount, 0)
        XCTAssertFalse(controller.isInKeyboardCaptureActive)
        XCTAssertNotNil(try store.keyboardHandoffState().requestID)
        XCTAssertNil(try store.pendingCommand())
    }

    func testRejectedInlineButtonOffersLaunchLinkBeforeClaimingHandoff() throws {
        engine.acceptsStart = false
        XCTAssertFalse(controller.opensMuesliFromPrimaryButton)

        controller.primaryAction()

        XCTAssertEqual(engine.startCount, 1)
        XCTAssertTrue(controller.opensMuesliFromPrimaryButton)
        XCTAssertFalse(controller.isInKeyboardCaptureActive)
        XCTAssertNil(try store.keyboardHandoffState().requestID)
        controller.prepareInitialPresentationState()
        XCTAssertTrue(controller.opensMuesliFromPrimaryButton, "An availability refresh must preserve the offered link")

        controller.primaryLaunchAction()

        XCTAssertEqual(engine.startCount, 1)
        XCTAssertNotNil(try store.keyboardHandoffState().requestID)
    }

    func testMountedInlineButtonDoesNotClaimForegroundHandoffWhenAvailabilityChanges() throws {
        XCTAssertFalse(controller.opensMuesliFromPrimaryButton)
        engine.availability = .recognizerUnavailable

        controller.primaryAction()

        XCTAssertEqual(engine.startCount, 0)
        XCTAssertTrue(controller.opensMuesliFromPrimaryButton)
        XCTAssertNil(try store.keyboardHandoffState().requestID)
    }

    func testPartialThenFinalInsertsTranscriptAndSavesHistoryOnly() throws {
        controller.startDictation()
        engine.handlers?.onListening()
        engine.handlers?.onPartial("Hello")
        XCTAssertEqual(controller.liveTranscript, "Hello")
        XCTAssertTrue(controller.showsLiveTranscript)
        XCTAssertTrue(insertedText.isEmpty, "partials are shown, not typed")

        controller.primaryAction()
        XCTAssertEqual(engine.finishCount, 1)
        XCTAssertEqual(controller.dictationPhase, .transcribing)

        engine.handlers?.onCompleted("  Hello world  ", InKeyboardDictationSession.engineIdentifier)

        XCTAssertEqual(insertedText, ["Hello world"])
        XCTAssertEqual(controller.dictationPhase, .idle)
        XCTAssertFalse(controller.isInKeyboardCaptureActive)
        XCTAssertEqual(controller.statusText, "Inserted")
        let saved = try XCTUnwrap(store.resultsHistory().first)
        XCTAssertEqual(saved.text, "Hello world")
        XCTAssertEqual(saved.engineIdentifier, InKeyboardDictationSession.engineIdentifier)
        XCTAssertTrue(try store.pendingKeyboardDeliveries().isEmpty)
        XCTAssertNil(try store.status().requestID, "app dictation status is untouched")

        controller.prepareInitialPresentationState()
        XCTAssertEqual(insertedText, ["Hello world"], "a refresh never re-inserts")
    }

    func testStopWaitsForKeyboardModelThenSavesItsEngine() throws {
        controller.startDictation()
        controller.primaryAction()
        engine.handlers?.onPreparingModel("Parakeet Redux")

        XCTAssertTrue(controller.isPreparingInKeyboardModel)
        XCTAssertEqual(controller.statusText, "Preparing Parakeet Redux…")
        XCTAssertTrue(insertedText.isEmpty)

        engine.handlers?.onCompleted("Hello from Parakeet", "parakeet-redux-keyboard")

        XCTAssertFalse(controller.isPreparingInKeyboardModel)
        XCTAssertEqual(insertedText, ["Hello from Parakeet"])
        XCTAssertEqual(try XCTUnwrap(store.resultsHistory().first).engineIdentifier, "parakeet-redux-keyboard")
    }

    func testReachingTheModelLimitStopsLikeTappingStop() throws {
        controller.startDictation()
        engine.handlers?.onListening()

        engine.handlers?.onReachedLimit()

        XCTAssertEqual(engine.finishCount, 1, "the recording is ended and transcribed, not dropped")
        XCTAssertEqual(controller.dictationPhase, .transcribing)

        engine.handlers?.onCompleted("Three minutes of speech", "parakeet-redux-keyboard")
        XCTAssertEqual(insertedText, ["Three minutes of speech"])
    }

    func testDismissingWhileTheModelHoldsTheAudioSavesItsTranscriptToHistory() throws {
        controller.startDictation()
        engine.handlers?.onListening()
        engine.holdsModelAudio = true

        controller.abandonInKeyboardDictationForDisappearance()

        XCTAssertEqual(engine.cancelCount, 0, "the model's audio is not discarded")
        XCTAssertEqual(engine.finishCount, 1, "the mic stops")
        XCTAssertTrue(try store.resultsHistory().isEmpty)

        engine.handlers?.onCompleted("Said before dismissing", "phonon-2.5-keyboard")

        XCTAssertTrue(insertedText.isEmpty, "the field it was meant for is gone")
        let saved = try XCTUnwrap(store.resultsHistory().first)
        XCTAssertEqual(saved.text, "Said before dismissing")
        XCTAssertEqual(saved.engineIdentifier, "phonon-2.5-keyboard")
        XCTAssertFalse(controller.isInKeyboardCaptureActive)
    }

    func testAccumulatorNeverDropsASentenceThatSharesOpeningWords() {
        var transcript = InKeyboardTranscriptAccumulator()
        transcript.apply("I like tea.", start: 0.0, endsUtterance: true)
        transcript.apply("I like coffee.", start: 0.0, endsUtterance: false)

        XCTAssertEqual(transcript.text, "I like tea. I like coffee.")
    }

    func testAccumulatorKeepsASentenceWhenTheNextOneStartsWithItsFirstLetters() {
        var transcript = InKeyboardTranscriptAccumulator()
        transcript.apply("Another idea.", start: 0.0, endsUtterance: true)
        transcript.apply("A", start: 0.0, endsUtterance: false)
        XCTAssertEqual(transcript.text, "Another idea. A")

        transcript.apply("A second one.", start: 0.0, endsUtterance: true)
        XCTAssertEqual(transcript.text, "Another idea. A second one.")
    }

    func testAccumulatorKeepsAShortSentenceThatPrefixesTheNextWord() {
        var transcript = InKeyboardTranscriptAccumulator()
        transcript.apply("No.", start: 0.0, endsUtterance: true)
        transcript.apply("Nothing else.", start: 0.0, endsUtterance: true)
        XCTAssertEqual(transcript.text, "No. Nothing else.")
    }

    func testAccumulatorReplacesARepeatedFinalResult() {
        var transcript = InKeyboardTranscriptAccumulator()
        transcript.apply("Hello there", start: 0.0, endsUtterance: true)
        transcript.apply("Hello there.", start: 0.0, endsUtterance: true)
        XCTAssertEqual(transcript.text, "Hello there.")
    }

    func testAccumulatorKeepsADifferentSentenceWithTheSameStart() {
        var transcript = InKeyboardTranscriptAccumulator()
        transcript.apply("Good morning.", start: 0.0, endsUtterance: true)
        transcript.apply("Send the report today.", start: 0.0, endsUtterance: false)

        XCTAssertEqual(transcript.text, "Good morning. Send the report today.")
    }

    func testEmptyFinalInsertsNothing() throws {
        controller.startDictation()
        controller.primaryAction()
        engine.handlers?.onCompleted("   ", InKeyboardDictationSession.engineIdentifier)

        XCTAssertTrue(insertedText.isEmpty)
        XCTAssertEqual(controller.statusText, "No speech heard")
        XCTAssertTrue(try store.resultsHistory().isEmpty)
    }

    func testCancelDiscardsWithoutInserting() throws {
        controller.startDictation()
        engine.handlers?.onPartial("Never mind")

        controller.cancelActiveDictation()

        XCTAssertEqual(engine.cancelCount, 1)
        XCTAssertFalse(controller.isInKeyboardCaptureActive)
        XCTAssertEqual(controller.dictationPhase, .idle)
        XCTAssertTrue(insertedText.isEmpty)
        XCTAssertTrue(try store.resultsHistory().isEmpty)
    }

    func testFailureSettlesToFailedAndAllowsRetry() throws {
        controller.startDictation()
        engine.handlers?.onFailed("Speech unavailable")

        XCTAssertEqual(controller.dictationPhase, .failed)
        XCTAssertFalse(controller.isInKeyboardCaptureActive)

        controller.primaryAction()
        XCTAssertEqual(engine.startCount, 2)
        XCTAssertTrue(controller.isInKeyboardCaptureActive)
    }

    func testDismissingKeyboardReleasesMicAndKeepsSpeechInHistory() throws {
        controller.startDictation()
        engine.handlers?.onPartial("Half a thought")

        controller.stopObservingSharedState()

        XCTAssertEqual(engine.cancelCount, 1)
        XCTAssertFalse(controller.isInKeyboardCaptureActive)
        XCTAssertTrue(insertedText.isEmpty)
        XCTAssertEqual(try store.resultsHistory().first?.text, "Half a thought")
    }

    func testRefreshDuringCaptureDoesNotAdoptAnAppRequest() throws {
        controller.startDictation()
        XCTAssertTrue(controller.isInKeyboardCaptureActive)

        // A recent finished status for an unrelated request would otherwise be
        // adopted by apply(status:) and flip the keyboard to .finished.
        try store.saveResult(.init(requestID: UUID(), text: "Elsewhere", engineIdentifier: "test"))
        controller.prepareInitialPresentationState()

        XCTAssertEqual(controller.dictationPhase, .recording)
        XCTAssertTrue(controller.isInKeyboardCaptureActive)
        XCTAssertTrue(insertedText.isEmpty)
    }

    func testAppRuntimeAndTranscriptEventsDoNotReplaceInlineCaptureState() async throws {
        controller.startObservingSharedState()
        defer { controller.stopObservingSharedState() }
        controller.startDictation()
        engine.handlers?.onListening()
        engine.handlers?.onPartial("Inline speech")
        engine.handlers?.onLevel(0.25)

        let unrelatedRequest = UUID()
        try store.saveKeyboardRuntimeStatus(.init(
            isActive: true,
            activeRequestID: unrelatedRequest,
            phase: .recording,
            canAcceptStartCommand: true,
            inputLevel: 0.75
        ))
        try store.saveKeyboardLiveTranscript(.init(requestID: unrelatedRequest, text: "App speech"))
        // The catalog event arrives after the two events above on the same stream.
        try store.saveKeyboardModelCatalog(.init(selectedRawValue: "test", models: [], canSelectModels: true))
        try await waitForModelCatalog(selectedRawValue: "test")

        XCTAssertEqual(controller.inputLevel, 0.25)
        XCTAssertEqual(controller.liveTranscript, "Inline speech")
        XCTAssertEqual(controller.dictationPhase, .recording)
    }

    func testKeyboardModelPickSwitchesAtOnceAndPreservesInlineCaptureStatus() async throws {
        let model = KeyboardTranscriptionModelOption(
            rawValue: "new", displayName: "New model", shortName: "New", capabilityLabel: "Ready", isReady: true
        )
        try store.saveKeyboardModelCatalog(.init(selectedRawValue: "old", models: [model], canSelectModels: true))
        controller.startObservingSharedState()
        defer { controller.stopObservingSharedState() }
        var reloads = 0
        controller.onTranscriptionModelChanged = { reloads += 1 }
        controller.selectTranscriptionModel(model)
        XCTAssertFalse(controller.isModelSelectionPending, "the keyboard switches without waiting for the app")
        XCTAssertEqual(controller.modelChipTitle, "New")
        XCTAssertEqual(reloads, 1, "the in-keyboard engine is told to load the new model")
        XCTAssertEqual(try store.keyboardModelCatalog()?.selectedRawValue, "new")
        controller.startDictation()
        engine.handlers?.onListening()

        // The controller already shows "new", so wait for a catalog it has not
        // applied yet (one more model) before checking the status survived it.
        let another = KeyboardTranscriptionModelOption(
            rawValue: "another", displayName: "Another model", shortName: "Another", capabilityLabel: "Ready", isReady: true
        )
        try store.saveKeyboardModelCatalog(.init(selectedRawValue: "new", models: [model, another], canSelectModels: true))
        let deadline = ContinuousClock.now + .seconds(2)
        while controller.modelCatalog?.models.count != 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(controller.modelCatalog?.models.count, 2, "The catalog event was not observed")

        XCTAssertFalse(controller.isModelSelectionPending)
        XCTAssertEqual(controller.statusText, "Listening on device")
    }

    private func waitForModelCatalog(selectedRawValue: String) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while controller.modelCatalog?.selectedRawValue != selectedRawValue, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(controller.modelCatalog?.selectedRawValue, selectedRawValue, "The catalog event was not observed")
    }

    func testCaptureCountsAsStartingUntilTheMicListens() throws {
        controller.startDictation()
        XCTAssertTrue(controller.isStartingCapture)
        engine.handlers?.onListening()
        XCTAssertFalse(controller.isStartingCapture)
    }

    func testLateCallbacksFromAnEndedCaptureAreIgnored() throws {
        controller.startDictation()
        let staleHandlers = engine.handlers
        controller.cancelActiveDictation()

        staleHandlers?.onCompleted("Late text", InKeyboardDictationSession.engineIdentifier)

        XCTAssertTrue(insertedText.isEmpty)
        XCTAssertEqual(controller.dictationPhase, .idle)
    }

    func testPostProcessingRespectsMirroredFlagsAndTrims() throws {
        let suite = "in-keyboard-dictation-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let word = CustomWord(word: "Muesli")

        InKeyboardDictationPreferences.mirrorPostProcessing(
            fillerWordRemoval: false,
            customDictionary: false,
            in: defaults
        )
        XCTAssertEqual(
            InKeyboardDictationPreferences.postProcess(" museli rocks ", customWords: [word], defaults: defaults),
            "museli rocks"
        )
        XCTAssertFalse(InKeyboardDictationPreferences.showsLiveTranscript(in: defaults), "waveform is the default")
    }

    func testLiveTranscriptReplacesWaveformOnlyWhenPreferred() throws {
        controller.inKeyboardLiveTranscriptPreference = { false }
        controller.startDictation()
        engine.handlers?.onPartial("Hello there")
        XCTAssertFalse(controller.showsInKeyboardLiveTranscript)
        engine.handlers?.onCompleted("Hello there", InKeyboardDictationSession.engineIdentifier)
        XCTAssertFalse(controller.showsInKeyboardLiveTranscript)

        controller.inKeyboardLiveTranscriptPreference = { true }
        controller.startDictation()
        engine.handlers?.onPartial("Hello again")
        XCTAssertTrue(controller.showsInKeyboardLiveTranscript)
        XCTAssertTrue(controller.showsLiveTranscript)
        XCTAssertEqual(controller.liveTranscript, "Hello again")
    }

    // MARK: - Transcript accumulation

    func testAccumulatorKeepsEveryUtteranceAcrossSpeechRestarts() {
        var transcript = InKeyboardTranscriptAccumulator()
        transcript.apply("Hello", start: 0.2, endsUtterance: false)
        transcript.apply("Hello world.", start: 0.2, endsUtterance: false)
        // Speech restarts after a pause without marking the utterance done.
        transcript.apply("This is", start: 3.1, endsUtterance: false)
        transcript.apply("This is the second part.", start: 3.1, endsUtterance: false)
        transcript.apply("And a third", start: 7.4, endsUtterance: false)

        XCTAssertEqual(transcript.text, "Hello world. This is the second part. And a third")
    }

    func testAccumulatorCommitsOnUtteranceMetadataWithoutDuplicatingFinal() {
        var transcript = InKeyboardTranscriptAccumulator()
        transcript.apply("First sentence.", start: 0.1, endsUtterance: true)
        transcript.apply("Second", start: 0.1, endsUtterance: false)
        transcript.apply("Second sentence.", start: 0.1, endsUtterance: true)
        // The final result after endAudio() repeats the last utterance.
        transcript.apply("Second sentence.", start: 0.1, endsUtterance: false)

        XCTAssertEqual(transcript.text, "First sentence. Second sentence.")
    }

    func testAccumulatorTreatsFullTranscriptResultAsReplacement() {
        var transcript = InKeyboardTranscriptAccumulator()
        transcript.apply("One two.", start: 0.0, endsUtterance: true)
        transcript.apply("One two. Three four.", start: 0.0, endsUtterance: false)

        XCTAssertEqual(transcript.text, "One two. Three four.")
    }

    func testAccumulatorRevisionsReplaceTheCurrentUtterance() {
        var transcript = InKeyboardTranscriptAccumulator()
        transcript.apply("Their", start: 0.4, endsUtterance: false)
        transcript.apply("There we go", start: 0.4, endsUtterance: false)
        transcript.apply("", start: nil, endsUtterance: false)

        XCTAssertEqual(transcript.text, "There we go")
    }

    func testSpeechPermissionPromptOnlyWhenIdleAndUndetermined() {
        XCTAssertTrue(InKeyboardDictationPermissionPrompt.shouldPrompt(
            isRecording: false, microphone: .granted, speech: .notDetermined))
        XCTAssertFalse(InKeyboardDictationPermissionPrompt.shouldPrompt(
            isRecording: true, microphone: .granted, speech: .notDetermined))
        XCTAssertFalse(InKeyboardDictationPermissionPrompt.shouldPrompt(
            isRecording: false, microphone: .undetermined, speech: .notDetermined))
        XCTAssertFalse(InKeyboardDictationPermissionPrompt.shouldPrompt(
            isRecording: false, microphone: .granted, speech: .denied))
    }
}

@MainActor
private final class FakeInKeyboardDictation: InKeyboardDictating {
    var availability: InKeyboardDictationAvailability = .available
    var acceptsStart = true
    var handlers: InKeyboardDictationHandlers?
    var startCount = 0
    var finishCount = 0
    var cancelCount = 0
    var holdsModelAudio = false

    func availability(hasFullAccess: Bool) -> InKeyboardDictationAvailability {
        hasFullAccess ? availability : .needsFullAccess
    }

    func start(handlers: InKeyboardDictationHandlers) -> Bool {
        startCount += 1
        guard acceptsStart else { return false }
        self.handlers = handlers
        return true
    }

    func finish() {
        finishCount += 1
    }

    func cancel() {
        cancelCount += 1
        handlers = nil
    }
}

private final class BufferedEventBus: CrossProcessEventStreaming, Sendable {
    private let channel = AsyncStream<CrossProcessEvent>.makeStream()

    func post(_ event: CrossProcessEvent) {
        channel.continuation.yield(event)
    }

    func events() -> AsyncStream<CrossProcessEvent> {
        channel.stream
    }
}
