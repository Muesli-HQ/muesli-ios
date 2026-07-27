import XCTest
@testable import Muesli

/// First unit coverage for the keyboard extension.
///
/// `MuesliKeyboard/` was compiled into no test target, so every keyboard
/// regression was device-only. That gap is why a branch could pass its whole
/// suite and still ship a keyboard that would not start dictation.
///
/// These drive `KeyboardController` the way the extension does -- by writing
/// shared state and refreshing -- rather than by calling private helpers, so
/// they exercise the same cross-process path the real keyboard takes.
@MainActor
final class KeyboardControllerTests: XCTestCase {
    private var directory: URL!
    private var store: SharedStore!
    private var bus: StubEventBus!
    private var controller: KeyboardController!
    private var insertedText: [String] = []

    private let requestID = UUID()

    override func setUp() async throws {
        try await super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("keyboard-controller-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        bus = StubEventBus()
        store = SharedStore(containerURL: directory, eventPoster: bus)
        controller = KeyboardController(store: store, eventBus: bus)
        insertedText = []
        controller.textInserter = { [weak self] text in self?.insertedText.append(text) }
    }

    override func tearDown() async throws {
        controller = nil
        store = nil
        bus = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func recordingStatus(
        level: Double,
        request: UUID? = nil,
        age: TimeInterval = 0
    ) -> KeyboardRuntimeStatus {
        KeyboardRuntimeStatus(
            isActive: true,
            activeRequestID: request ?? requestID,
            phase: .recording,
            supportsBackgroundStart: true,
            inputLevel: level,
            updatedAt: Date().addingTimeInterval(-age)
        )
    }

    private func handoff(_ phase: KeyboardHandoffPhase) -> KeyboardHandoffState {
        KeyboardHandoffState(requestID: requestID, phase: phase)
    }

    // MARK: - Waveform

    /// iOS destroys and rebuilds the keyboard constantly -- three times inside
    /// one thirty-second dictation, per device diagnostics. A rebuilt keyboard
    /// has adopted no request yet, and previously that made it discard levels
    /// that were fractions of a second old, collapsing every bar to zero while
    /// the pill still said "Listening".
    func testARebuiltKeyboardStillRendersTheWaveform() throws {
        try store.saveKeyboardRuntimeStatus(recordingStatus(level: 0.62))
        try store.saveKeyboardHandoffState(handoff(.recordingStarted))

        controller.prepareInitialPresentationState()

        XCTAssertEqual(controller.dictationPhase, .recording)
        XCTAssertEqual(controller.inputLevel, 0.62, accuracy: 0.001)
        XCTAssertTrue(controller.showsActiveWaveform)
    }

    /// The freshness rule still has to hold: a recording whose levels stopped
    /// arriving is stalled, and the bars should settle rather than freeze on
    /// whatever arrived last.
    func testAStalledRecordingSettlesTheWaveform() throws {
        try store.saveKeyboardRuntimeStatus(recordingStatus(level: 0.62, age: 5))
        try store.saveKeyboardHandoffState(handoff(.recordingStarted))

        controller.prepareInitialPresentationState()

        XCTAssertEqual(controller.inputLevel, 0)
    }

    /// The waveform follows whatever the app is recording, without checking
    /// that the level names the request this keyboard adopted.
    ///
    /// That match used to be required. It was not protecting anything: a
    /// recording the keyboard does not own blocks the keyboard and hides the
    /// waveform card entirely, so there is no path where a foreign level is
    /// drawn. What it did do was blank the waveform every time iOS rebuilt the
    /// keyboard, because a rebuilt one has adopted no request yet.
    func testTheWaveformFollowsWhateverTheAppIsRecording() throws {
        try store.saveKeyboardRuntimeStatus(recordingStatus(level: 0.62))
        try store.saveKeyboardHandoffState(handoff(.recordingStarted))
        controller.prepareInitialPresentationState()
        XCTAssertEqual(controller.inputLevel, 0.62, accuracy: 0.001)

        try store.saveKeyboardRuntimeStatus(recordingStatus(level: 0.9, request: UUID()))
        controller.prepareInitialPresentationState()

        XCTAssertEqual(controller.inputLevel, 0.9, accuracy: 0.001)
    }

    /// The controller outlives a dismissal, so a retained level was replayed
    /// through the launch snapshot on the way back in.
    func testDismissalSettlesLiveInput() throws {
        try store.saveKeyboardRuntimeStatus(recordingStatus(level: 0.62))
        try store.saveKeyboardHandoffState(handoff(.recordingStarted))
        controller.prepareInitialPresentationState()
        XCTAssertEqual(controller.inputLevel, 0.62, accuracy: 0.001)

        controller.stopObservingSharedState()

        XCTAssertEqual(controller.inputLevel, 0)
        XCTAssertEqual(controller.liveTranscript, "")
    }

    // MARK: - Terminal states

    func testAnInsertedSessionLeavesNoActiveCard() throws {
        try store.saveKeyboardHandoffState(handoff(.inserted))

        controller.prepareInitialPresentationState()

        XCTAssertEqual(controller.dictationPhase, .idle)
        XCTAssertFalse(controller.showsActiveWaveform)
        XCTAssertFalse(controller.canCancelActiveDictation)
    }

    func testACancelledSessionLeavesNoActiveCard() throws {
        try store.saveKeyboardHandoffState(handoff(.cancelled))

        controller.prepareInitialPresentationState()

        XCTAssertEqual(controller.dictationPhase, .idle)
        XCTAssertFalse(controller.showsActiveWaveform)
    }

    // MARK: - Insertion

    func testACompletedResultIsInsertedOnce() throws {
        let result = DictationResult(requestID: requestID, text: "hello there", engineIdentifier: "test")
        try store.saveResult(result)
        try store.saveKeyboardHandoffState(handoff(.resultReady))

        controller.prepareInitialPresentationState()
        XCTAssertEqual(insertedText, ["hello there"])

        // A second refresh must not paste the same transcript again.
        controller.prepareInitialPresentationState()
        XCTAssertEqual(insertedText, ["hello there"])
    }

    /// Known defect, pinned rather than left undocumented.
    ///
    /// Both processes write `keyboard_handoff_state` with no sequence number,
    /// and `KeyboardHandoffState.advanced(to:)` performs no ordering check. So
    /// a late `.resultReady` from the app can land after the extension has
    /// already written `.inserted`, regressing a terminal phase. The extension
    /// re-adopts the request it just finished, `insertCompletedResult` returns
    /// early on its idempotency latch without reconciling, and the keyboard
    /// strands on "Transcribing" with its primary button disabled.
    ///
    /// This is the defect behind the original bug report. It is unfixed on
    /// `main`; fixing it needs monotonic transitions at the storage layer.
    /// When that lands this test fails as an unexpected pass -- delete the
    /// `XCTExpectFailure` then.
    func testLateResultReadyStrandsTheKeyboard() throws {
        let result = DictationResult(requestID: requestID, text: "already sent", engineIdentifier: "test")
        try store.saveResult(result)
        try store.saveKeyboardHandoffState(handoff(.resultReady))
        controller.prepareInitialPresentationState()
        XCTAssertEqual(insertedText, ["already sent"])
        XCTAssertEqual(controller.dictationPhase, .idle)

        // The app, still inside an await gap, writes .resultReady for a request
        // the keyboard has already inserted and marked .inserted.
        try store.saveKeyboardHandoffState(handoff(.resultReady))

        XCTExpectFailure("Terminal handoff phases are not yet monotonic; see Context/findings-2026-07-26") {
            controller.prepareInitialPresentationState()
            XCTAssertEqual(
                controller.dictationPhase,
                .idle,
                "text was already inserted, so the keyboard must not return to a working state"
            )
            XCTAssertFalse(controller.isPrimaryButtonDisabled, "the user cannot start another dictation")
        }
    }
}

private final class StubEventBus: CrossProcessEventStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CrossProcessEvent] = []

    var postedEvents: [CrossProcessEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func post(_ event: CrossProcessEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    /// Never yields: these tests drive refreshes explicitly so assertions are
    /// deterministic rather than racing a notification.
    func events() -> AsyncStream<CrossProcessEvent> {
        AsyncStream { _ in }
    }
}
