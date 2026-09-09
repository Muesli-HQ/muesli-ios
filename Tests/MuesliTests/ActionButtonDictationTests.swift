import XCTest
import AppIntents
import AVFoundation
@testable import Muesli

@MainActor
final class ActionButtonDictationTests: XCTestCase {
    func testRecorderCapturesSamplesWithPlaybackDisabled() async throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw XCTSkip("Grant microphone permission to the simulator host before running the hardware capture test.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = StreamingMeetingRecorder()
        let samples = expectation(description: "Microphone samples reach the consumer")
        samples.assertForOverFulfill = false
        recorder.onAudioSamples = { buffer in
            if !buffer.isEmpty { samples.fulfill() }
        }
        try recorder.start(chunksDirectory: directory, retainedAudioURL: nil)
        defer { recorder.cancel() }
        XCTAssertFalse(recorder.isPlaybackEnabled)
        await fulfillment(of: [samples], timeout: 5)
        XCTAssertTrue(recorder.isCapturingAudio)
        XCTAssertFalse(recorder.isPlaybackEnabled)
    }

    func testStartProducesNoShortcutOutputItem() {
        XCTAssertNil(ActionButtonShortcutOutput.intentResult(nil).value)
        XCTAssertNil(ActionButtonShortcutOutput.intentResult("").value)
        XCTAssertNil(ActionButtonShortcutOutput.intentResult(" \n ").value)
    }

    func testCompletedTranscriptRemainsShortcutOutput() {
        XCTAssertEqual(ActionButtonShortcutOutput.intentResult("Hello Pico").value, "Hello Pico")
    }

    func testEmptyConfirmationIsSuppressed() {
        XCTAssertNil(ActionButtonClipboardConfirmation.nonemptyTranscript(" \n"))
        XCTAssertEqual(ActionButtonClipboardConfirmation.nonemptyTranscript("Hello Pico"), "Hello Pico")
    }

    func testCaptureStartsBeforePublishingLiveActivity() async throws {
        var events: [String] = []
        try await ActionButtonCaptureStartup.run {
            events.append("audio")
        } publishActivity: {
            events.append("activity")
        } cancelAudio: { events.append("cancel") }
        XCTAssertEqual(events, ["audio", "activity"])
    }

    func testLiveActivityFailureStopsAudioWithoutRetry() async {
        var events: [String] = []
        do {
            try await ActionButtonCaptureStartup.run {
                events.append("audio")
            } publishActivity: {
                events.append("activity")
                throw CancellationError()
            } cancelAudio: { events.append("cancel") }
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual(events, ["audio", "activity", "cancel"])
        }
    }

    func testAudioFailureDoesNotPublishListeningActivity() async {
        var events: [String] = []
        do {
            try await ActionButtonCaptureStartup.run {
                events.append("audio")
                throw CancellationError()
            } publishActivity: {
                events.append("activity")
            } cancelAudio: { events.append("cancel") }
            XCTFail("Expected failure")
        } catch { XCTAssertEqual(events, ["audio", "cancel"]) }
    }

    func testShortcutWaitsForItsCompletedTranscript() async throws {
        var reads = 0
        let text = try await ActionButtonShortcutOutput.waitForTranscript(pollInterval: .milliseconds(1)) {
            reads += 1
            return reads == 3 ? "Ready for the system clipboard" : nil
        }
        XCTAssertEqual(text, "Ready for the system clipboard")
        XCTAssertEqual(reads, 3)
    }

    func testMissingModelReleasesActionButtonHandoff() async throws {
        guard let model = LocalTranscriptionModel.allCases.first(where: { !$0.isDownloaded }) else {
            throw XCTSkip("Requires an undownloaded model")
        }
        let defaults = UserDefaults.standard
        let keys = [MuesliPreferences.transcriptionModelKey,
                    MuesliPreferences.manuallyRemovedTranscriptionModelKey,
                    MuesliPreferences.keyboardSessionModeKey]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(model.rawValue, forKey: keys[0])
        defaults.set(model.rawValue, forKey: keys[1]) // No network download in this test.
        defaults.set(false, forKey: keys[2])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = Muesli.SharedStore(containerURL: directory)
        let coordinator = DictationCoordinator(store: store)
        guard case .failed = await coordinator.toggleActionButtonDictation() else {
            return XCTFail("Missing model must reject capture")
        }
        XCTAssertFalse(coordinator.isRecording)
        XCTAssertFalse(coordinator.isKeyboardHandoffActive)
        XCTAssertEqual(try store.keyboardModelCatalog()?.canSelectModels, true)
        XCTAssertEqual(try store.keyboardHandoffState().phase, .failed)
    }

    func testActionButtonHardwareExcludesUnsupportedDevices() {
        for identifier in ["iPhone16,1", "iPhone16,2", "iPhone17,1", "iPhone17,5", "iPhone18,3"] {
            XCTAssertTrue(ActionButtonHardware.supports(identifier: identifier), identifier)
        }
        for identifier in ["iPhone15,4", "iPhone15,5", "iPhone14,6", "iPad16,1", "arm64", "", "iPhone99,1"] {
            XCTAssertFalse(ActionButtonHardware.supports(identifier: identifier), identifier)
        }
    }

    func testHealthyTranscriptionCanOutliveFiveMinutes() async throws {
        let start = ContinuousClock().now
        var elapsed = Duration.zero
        var reads = 0
        let text = try await ActionButtonShortcutOutput.waitForTranscript(
            pollInterval: .milliseconds(1), now: { start.advanced(by: elapsed) }
        ) {
            reads += 1
            elapsed += .seconds(120)
            return reads == 4 ? "A longer transcription" : nil
        }
        XCTAssertEqual(text, "A longer transcription")
        XCTAssertEqual(reads, 4)
    }

    func testTranscriptionFailureEndsUnboundedShortcutWait() async {
        do {
            _ = try await ActionButtonShortcutOutput.waitForTranscript {
                throw ActionButtonCaptureError.unavailable("Transcription failed")
            }
            XCTFail("A failed job must end the shortcut")
        } catch { XCTAssertEqual(error.localizedDescription, "Transcription failed") }
    }

    func testShortcutRejectsEmptyCompletedTranscript() async {
        for emptyText in ["", " \n\t"] {
            do {
                _ = try await ActionButtonShortcutOutput.waitForTranscript { emptyText }
                XCTFail("An empty completion must not look like a successful clipboard copy")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("Nothing was copied"))
            }
        }
    }

    func testShortcutTimeoutDoesNotReturnAnOldTranscript() async {
        do {
            _ = try await ActionButtonShortcutOutput.waitForTranscript(timeout: .zero) { nil }
            XCTFail("An unfinished result must not masquerade as a completed transcript")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("saved in Muesli"))
        }
    }

    private func isolatedVerificationStore() -> (SetupVerificationStore, UserDefaults, String) {
        let suiteName = "muesli-setup-verification-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (SetupVerificationStore(defaults: defaults), defaults, suiteName)
    }

    func testDispatcherForwardsToggleResult() async {
        defer { ActionButtonCaptureDispatcher.register(toggleHandler: nil) }
        var callCount = 0
        var receivedMode: Muesli.ActionButtonCaptureMode?
        let sessionID = UUID()
        ActionButtonCaptureDispatcher.register { mode in
            receivedMode = mode
            callCount += 1
            return .started(sessionID: sessionID)
        }

        let result = await ActionButtonCaptureDispatcher.toggle(.meeting)
        XCTAssertEqual(result, .started(sessionID: sessionID))
        XCTAssertEqual(receivedMode, .meeting)
        XCTAssertEqual(callCount, 1)
    }

    func testDispatcherIsUnavailableWithoutAppRuntime() async {
        defer { ActionButtonCaptureDispatcher.register(toggleHandler: nil) }
        ActionButtonCaptureDispatcher.register(toggleHandler: nil)

        let result = await ActionButtonCaptureDispatcher.toggle(.meeting)
        XCTAssertEqual(result, .unavailable)
    }

    func testLegacyKeyboardStatusDecodesAsVisible() throws {
        struct LegacyStatus: Encodable {
            let lastSeenAt: Date
            let hasOpenAccess: Bool
        }

        let encoded = try JSONEncoder().encode(LegacyStatus(lastSeenAt: .now, hasOpenAccess: true))
        let decoded = try JSONDecoder().decode(KeyboardExtensionStatus.self, from: encoded)

        XCTAssertTrue(decoded.hasOpenAccess)
        XCTAssertTrue(decoded.isVisible)
    }

    func testKeyboardControllerPublishesVisibilityLifecycle() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("action-button-keyboard-status-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let eventBus = ActionButtonStubEventBus()
        let store = SharedStore(containerURL: directory, eventPoster: eventBus)
        let controller = KeyboardController(store: store, eventBus: eventBus)
        controller.startObservingSharedState(hasOpenAccess: false)

        XCTAssertEqual(try store.keyboardExtensionStatus()?.isVisible, true)
        XCTAssertEqual(try store.keyboardExtensionStatus()?.hasOpenAccess, false)

        controller.stopObservingSharedState()

        XCTAssertEqual(try store.keyboardExtensionStatus()?.isVisible, false)
    }

    func testKeyboardProofRequiresTheCurrentNonce() {
        let (verificationStore, defaults, suiteName) = isolatedVerificationStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = verificationStore.beginKeyboardChallenge()
        let second = verificationStore.beginKeyboardChallenge()

        verificationStore.saveKeyboardReceipt(for: first, hasFullAccess: true)

        XCTAssertNil(verificationStore.keyboardReceipt(for: second))
    }

    func testKeyboardControllerInsertsNonceAndReportsFullAccess() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("action-button-keyboard-proof-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let (verificationStore, defaults, suiteName) = isolatedVerificationStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let challenge = verificationStore.beginKeyboardChallenge()
        let eventBus = ActionButtonStubEventBus()
        let controller = KeyboardController(
            store: SharedStore(containerURL: directory, eventPoster: eventBus),
            eventBus: eventBus,
            setupVerificationStore: verificationStore
        )
        var insertedText: String?
        controller.textInserter = { insertedText = $0 }
        controller.startObservingSharedState(hasOpenAccess: true)
        defer { controller.stopObservingSharedState() }

        controller.verifyKeyboardSetup()

        XCTAssertEqual(insertedText, challenge.responseToken)
        XCTAssertEqual(
            verificationStore.keyboardReceipt(for: challenge)?.hasFullAccess,
            true
        )
    }

    func testKeyboardWithoutFullAccessCannotCreateFullAccessReceipt() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("action-button-keyboard-read-only-proof-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let (verificationStore, defaults, suiteName) = isolatedVerificationStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let challenge = verificationStore.beginKeyboardChallenge()
        let eventBus = ActionButtonStubEventBus()
        let controller = KeyboardController(
            store: SharedStore(containerURL: directory, eventPoster: eventBus),
            eventBus: eventBus,
            setupVerificationStore: verificationStore
        )
        var insertedText: String?
        controller.textInserter = { insertedText = $0 }
        controller.startObservingSharedState(hasOpenAccess: false)
        defer { controller.stopObservingSharedState() }

        controller.verifyKeyboardSetup()

        XCTAssertEqual(insertedText, challenge.responseToken)
        XCTAssertNil(verificationStore.keyboardReceipt(for: challenge))
    }

    func testActionButtonProofRequiresStartThenStop() {
        let (verificationStore, defaults, suiteName) = isolatedVerificationStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let challenge = verificationStore.beginActionButtonChallenge()

        verificationStore.recordActionButtonEvent(.stopped)
        XCTAssertNil(verificationStore.actionButtonReceipt(for: challenge))

        verificationStore.recordActionButtonEvent(.started)
        XCTAssertFalse(verificationStore.actionButtonReceipt(for: challenge)?.isVerified ?? true)

        verificationStore.recordActionButtonEvent(.stopped)
        XCTAssertTrue(verificationStore.actionButtonReceipt(for: challenge)?.isVerified == true)
    }

    func testClipboardResultCannotInsertBeforeFinalHandoffArrives() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("muesli-clipboard-race-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SharedStore(containerURL: directory, eventPoster: ActionButtonStubEventBus())
        let requestID = UUID()
        let session = RecordingSession(requestID: requestID, kind: .keyboardDictation, phase: .completed, source: ActionButtonCaptureSource.clipboard)
        try store.saveSession(session)
        try store.saveKeyboardHandoffState(.init(requestID: requestID, phase: .transcribingStarted))
        try store.saveResult(.init(requestID: requestID, sessionID: session.id, text: "Clipboard only", engineIdentifier: "test", source: ActionButtonCaptureSource.clipboard))
        let controller = KeyboardController(store: store, eventBus: ActionButtonStubEventBus())
        var inserted = ""
        controller.textInserter = { inserted += $0 }
        controller.startObservingSharedState(hasOpenAccess: true)
        defer { controller.stopObservingSharedState() }
        XCTAssertEqual(inserted, "")
        // Explicitly choosing Insert Latest remains a user-authorized action.
        controller.insertLatestDictation()
        XCTAssertEqual(inserted, "Clipboard only")
    }

    func testMeetingVerificationRejectsDictationEvents() {
        let (store, defaults, suiteName) = isolatedVerificationStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let challenge = store.beginActionButtonChallenge(mode: .meeting)
        let sessionID = UUID()
        store.recordActionButtonEvent(.started, mode: .dictation, sessionID: sessionID)
        store.recordActionButtonEvent(.stopped, mode: .dictation, sessionID: sessionID)
        XCTAssertNil(store.actionButtonReceipt(for: challenge))
        store.recordActionButtonEvent(.started, mode: .meeting, sessionID: sessionID)
        store.recordActionButtonEvent(.stopped, mode: .meeting, sessionID: sessionID)
        XCTAssertEqual(store.actionButtonReceipt(for: challenge)?.isVerified, true)
    }

    func testVerificationRejectsStopFromAnotherRecording() {
        let (store, defaults, suiteName) = isolatedVerificationStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let challenge = store.beginActionButtonChallenge()
        let sessionID = UUID()
        store.recordActionButtonEvent(.started, sessionID: sessionID)
        store.recordActionButtonEvent(.stopped, sessionID: UUID())
        XCTAssertEqual(store.actionButtonReceipt(for: challenge)?.isVerified, false)
        store.recordActionButtonEvent(.stopped, sessionID: sessionID)
        XCTAssertEqual(store.actionButtonReceipt(for: challenge)?.isVerified, true)
    }

    func testChangingModeInvalidatesPreviousVerification() {
        let (store, defaults, suiteName) = isolatedVerificationStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let old = store.beginActionButtonChallenge()
        store.recordActionButtonEvent(.started)
        store.recordActionButtonEvent(.stopped)
        let current = store.beginActionButtonChallenge(mode: .meeting)
        XCTAssertNil(store.actionButtonReceipt(for: old))
        XCTAssertNil(store.actionButtonReceipt(for: current))
    }

    func testLegacyChallengeRetainsDictationMeaning() throws {
        struct LegacyChallenge: Encodable {
            let id: UUID
            let createdAt: Date
            let expiresAt: Date
        }
        let data = try JSONEncoder().encode(LegacyChallenge(id: UUID(), createdAt: .now, expiresAt: .distantFuture))
        let decoded = try JSONDecoder().decode(ActionButtonSetupVerificationChallenge.self, from: data)
        XCTAssertEqual(decoded.captureMode, .dictation)
    }

    func testStopWithEarlierTimestampDoesNotVerify() {
        let (store, defaults, suiteName) = isolatedVerificationStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date.now
        let challenge = store.beginActionButtonChallenge(now: now)
        store.recordActionButtonEvent(.started, now: now.addingTimeInterval(2))
        store.recordActionButtonEvent(.stopped, now: now.addingTimeInterval(1))
        XCTAssertEqual(store.actionButtonReceipt(for: challenge)?.isVerified, false)
    }

    func testExpiredChallengesAreNotAccepted() {
        let (verificationStore, defaults, suiteName) = isolatedVerificationStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let start = Date(timeIntervalSince1970: 100)
        let keyboard = verificationStore.beginKeyboardChallenge(now: start, lifetime: 1)
        let actionButton = verificationStore.beginActionButtonChallenge(now: start, lifetime: 1)

        verificationStore.saveKeyboardReceipt(
            for: keyboard,
            hasFullAccess: true,
            now: start.addingTimeInterval(2)
        )
        verificationStore.recordActionButtonEvent(.started, now: start.addingTimeInterval(2))

        XCTAssertNil(verificationStore.activeKeyboardChallenge(now: start.addingTimeInterval(2)))
        XCTAssertNil(verificationStore.keyboardReceipt(for: keyboard))
        XCTAssertNil(verificationStore.activeActionButtonChallenge(now: start.addingTimeInterval(2)))
        XCTAssertNil(verificationStore.actionButtonReceipt(for: actionButton))
    }
}

private final class ActionButtonStubEventBus: CrossProcessEventStreaming, @unchecked Sendable {
    func post(_ event: CrossProcessEvent) {}

    func events() -> AsyncStream<CrossProcessEvent> {
        AsyncStream { _ in }
    }
}
