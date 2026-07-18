import XCTest
@testable import Muesli

@MainActor
final class KeyboardControllerPresentationTests: XCTestCase {
    func testColdReconciliationRestoresRequestBeforeApplyingFreshMeterLevel() throws {
        let fixture = try makeRecordingFixture(level: 0.82)
        defer { fixture.cleanup() }

        let controller = KeyboardController(store: fixture.store, eventBus: fixture.bus)
        controller.reconcileSharedPresentationState()

        XCTAssertEqual(controller.dictationPhase, .recording)
        XCTAssertEqual(controller.primaryButtonTitle, "Stop")
        XCTAssertFalse(controller.isPrimaryButtonDisabled)
        XCTAssertEqual(controller.waveformMode, .level)
        XCTAssertEqual(try XCTUnwrap(controller.waveformLevel), 0.82, accuracy: 0.001)
        XCTAssertEqual(controller.liveTranscript, "Before lock and after lock")
    }

    func testStaleMeterDoesNotDisableControlsOrMutateDurableRecording() throws {
        let fixture = try makeRecordingFixture(
            level: 0.91,
            runtimeUpdatedAt: Date().addingTimeInterval(-10),
            handoffUpdatedAt: Date().addingTimeInterval(-60)
        )
        defer { fixture.cleanup() }

        let controller = KeyboardController(store: fixture.store, eventBus: fixture.bus)
        controller.reconcileSharedPresentationState()

        XCTAssertEqual(controller.dictationPhase, .recording)
        XCTAssertEqual(controller.primaryButtonTitle, "Stop")
        XCTAssertFalse(controller.isPrimaryButtonDisabled)
        XCTAssertTrue(controller.isCaptureRecovering)
        XCTAssertEqual(controller.waveformMode, .waiting)
        XCTAssertNil(controller.waveformLevel)
        XCTAssertEqual(try fixture.store.keyboardHandoffState().phase, .recordingStarted)
        XCTAssertEqual(
            try fixture.store.recordingSession(id: fixture.session.id)?.phase,
            .recording
        )
    }

    func testRecoveringRuntimeUsesWaitingPresentationUntilFreshLevelsResume() throws {
        let fixture = try makeRecordingFixture(level: 0.91, isRecoveringCapture: true)
        defer { fixture.cleanup() }

        let controller = KeyboardController(store: fixture.store, eventBus: fixture.bus)
        controller.reconcileSharedPresentationState()

        XCTAssertEqual(controller.dictationPhase, .recording)
        XCTAssertEqual(controller.primaryButtonTitle, "Stop")
        XCTAssertFalse(controller.isPrimaryButtonDisabled)
        XCTAssertTrue(controller.isCaptureRecovering)
        XCTAssertEqual(controller.waveformMode, .waiting)
        XCTAssertNil(controller.waveformLevel)

        try fixture.store.saveKeyboardRuntimeStatus(.init(
            isActive: true,
            activeRequestID: fixture.session.requestID,
            phase: .recording,
            message: "Listening",
            supportsBackgroundStart: false,
            inputLevel: 0.64
        ))
        controller.reconcileSharedPresentationState()

        XCTAssertFalse(controller.isCaptureRecovering)
        XCTAssertEqual(controller.waveformMode, .level)
        XCTAssertEqual(try XCTUnwrap(controller.waveformLevel), 0.64, accuracy: 0.001)
    }

    func testHostResumeRecreatesWaveformLeafAndReconcilesActiveState() throws {
        let fixture = try makeRecordingFixture(level: 0.52)
        defer { fixture.cleanup() }

        let controller = KeyboardController(store: fixture.store, eventBus: fixture.bus)
        let initialGeneration = controller.waveformRenderGeneration
        controller.activatePresentationLease()
        controller.resumeAfterHostActivation()
        defer { controller.stopObservingSharedState() }

        XCTAssertEqual(controller.waveformRenderGeneration, initialGeneration + 1)
        XCTAssertEqual(controller.dictationPhase, .recording)
        XCTAssertEqual(try XCTUnwrap(controller.waveformLevel), 0.52, accuracy: 0.001)
    }

    func testMissedResultNotificationInsertsExactlyOnceAndRepairsTerminalUI() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bus = SilentCrossProcessEventBus()
        let store = SharedStore(containerURL: directory, eventPoster: bus)
        let requestID = UUID()
        let session = RecordingSession(
            requestID: requestID,
            kind: .keyboardDictation,
            phase: .completed,
            source: "keyboard"
        )
        try store.saveSession(session)
        try store.saveStatus(.init(requestID: requestID, phase: .finished))
        try store.saveKeyboardHandoffState(.init(
            requestID: requestID,
            phase: .resultReady,
            message: "Ready to insert"
        ))
        let result = DictationResult(
            requestID: requestID,
            sessionID: session.id,
            text: "Recovered once",
            engineIdentifier: "test-engine",
            source: "keyboard"
        )
        try store.saveResult(result)

        var inserted: [String] = []
        let controller = KeyboardController(store: store, eventBus: bus)
        controller.textInserter = { inserted.append($0) }
        controller.activatePresentationLease()
        controller.reconcileSharedPresentationState()

        XCTAssertEqual(inserted, ["Recovered once"])
        XCTAssertEqual(controller.dictationPhase, .idle)
        XCTAssertEqual(controller.primaryButtonTitle, "Record")
        XCTAssertEqual(try store.keyboardHandoffState().phase, .inserted)

        let lateResultReady = KeyboardHandoffState(
            requestID: requestID,
            phase: .resultReady,
            message: "Late result-ready",
            updatedAt: Date().addingTimeInterval(1)
        )
        XCTAssertFalse(try store.saveKeyboardHandoffState(lateResultReady))
        controller.reconcileSharedPresentationState()

        XCTAssertEqual(inserted, ["Recovered once"])
        XCTAssertEqual(controller.dictationPhase, .idle)
        XCTAssertNotEqual(controller.primaryButtonTitle, "Transcribing")
    }

    func testPreloadedControllerCannotConsumeResultBeforePresentationBecomesEligible() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bus = SilentCrossProcessEventBus()
        let store = SharedStore(containerURL: directory, eventPoster: bus)
        let requestID = UUID()
        try store.saveKeyboardHandoffState(.init(requestID: requestID, phase: .resultReady))
        try store.saveResult(.init(
            requestID: requestID,
            text: "Only the visible keyboard may insert",
            engineIdentifier: "test"
        ))

        var hiddenInsertions: [String] = []
        let preloaded = KeyboardController(store: store, eventBus: bus)
        preloaded.textInserter = { hiddenInsertions.append($0) }
        preloaded.reconcileSharedPresentationState()

        XCTAssertTrue(hiddenInsertions.isEmpty)
        XCTAssertNotNil(try store.result(for: requestID))

        var visibleInsertions: [String] = []
        let visible = KeyboardController(store: store, eventBus: bus)
        visible.textInserter = { visibleInsertions.append($0) }
        visible.activatePresentationLease()
        visible.reconcileSharedPresentationState()

        XCTAssertEqual(visibleInsertions, ["Only the visible keyboard may insert"])
        XCTAssertTrue(hiddenInsertions.isEmpty)
        XCTAssertNil(try store.result(for: requestID))
    }

    func testAbandonedInsertionRequiresTwoStepConfirmationAndClearsAfterTerminalHandoff() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bus = SilentCrossProcessEventBus()
        let store = SharedStore(containerURL: directory, eventPoster: bus)
        let requestID = UUID()
        let oldTime = Date().addingTimeInterval(-60)
        let oldOwner = UUID()
        try store.saveKeyboardHandoffState(.init(requestID: requestID, phase: .resultReady))
        try store.saveResult(.init(
            requestID: requestID,
            text: "Recover only when missing",
            engineIdentifier: "test"
        ))
        XCTAssertTrue(try store.acquireKeyboardPresentationLease(ownerID: oldOwner, now: oldTime))
        XCTAssertEqual(try store.claimKeyboardResultInsertion(
            claim: .init(
                id: UUID(),
                requestID: requestID,
                ownerID: oldOwner,
                claimedAt: oldTime
            ),
            now: oldTime
        ), .acquired)

        var inserted: [String] = []
        let controller = KeyboardController(store: store, eventBus: bus)
        controller.textInserter = { inserted.append($0) }
        controller.activatePresentationLease()
        controller.reconcileSharedPresentationState()

        XCTAssertEqual(controller.primaryButtonTitle, "Review recovered text")
        controller.primaryAction()
        XCTAssertTrue(inserted.isEmpty)
        XCTAssertEqual(controller.primaryButtonTitle, "Insert if missing")
        XCTAssertEqual(controller.statusText, "Verify the text is missing before inserting")

        controller.primaryAction()
        XCTAssertEqual(inserted, ["Recover only when missing"])
        XCTAssertEqual(try store.keyboardHandoffState().phase, .inserted)
        XCTAssertNotEqual(controller.primaryButtonRole, .manualInsert)
    }

    private func makeRecordingFixture(
        level: Double,
        isRecoveringCapture: Bool = false,
        runtimeUpdatedAt: Date = .now,
        handoffUpdatedAt: Date = .now
    ) throws -> RecordingFixture {
        let directory = try makeTemporaryDirectory()
        let bus = SilentCrossProcessEventBus()
        let store = SharedStore(containerURL: directory, eventPoster: bus)
        let requestID = UUID()
        let session = RecordingSession(
            requestID: requestID,
            kind: .keyboardDictation,
            phase: .recording,
            source: "keyboard"
        )
        try store.saveSession(session)
        try store.saveStatus(.init(requestID: requestID, phase: .recording))
        try store.saveKeyboardHandoffState(.init(
            requestID: requestID,
            phase: .recordingStarted,
            message: "Listening",
            updatedAt: handoffUpdatedAt
        ))
        try store.saveKeyboardRuntimeStatus(.init(
            isActive: true,
            activeRequestID: requestID,
            phase: .recording,
            message: "Listening",
            supportsBackgroundStart: false,
            inputLevel: level,
            isRecoveringCapture: isRecoveringCapture,
            updatedAt: runtimeUpdatedAt
        ))
        try store.saveKeyboardLiveTranscript(.init(
            requestID: requestID,
            text: "Before lock and after lock"
        ))
        return RecordingFixture(
            directory: directory,
            bus: bus,
            store: store,
            session: session
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private struct RecordingFixture {
    let directory: URL
    let bus: SilentCrossProcessEventBus
    let store: SharedStore
    let session: RecordingSession

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class SilentCrossProcessEventBus: CrossProcessEventStreaming, @unchecked Sendable {
    func post(_: CrossProcessEvent) {}

    func events() -> AsyncStream<CrossProcessEvent> {
        AsyncStream { _ in }
    }
}
