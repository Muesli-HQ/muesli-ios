import XCTest
#if canImport(MuesliDev)
@testable import MuesliDev
private typealias StopStore = MuesliDev.SharedStore
private typealias StopSession = MuesliDev.RecordingSession
#else
@testable import Muesli
private typealias StopStore = Muesli.SharedStore
private typealias StopSession = Muesli.RecordingSession
#endif

@MainActor
final class VoiceNoteTranscriptionStopTests: XCTestCase {
    func testRetiredNemotronSessionFallsBackToSavedAudio() async throws {
        let text = try await RealtimeTranscriptionRecovery.finishOrUseSavedAudio(
            validateOwnership: {}, finish: { throw CancellationError() }
        )
        XCTAssertTrue(text.isEmpty, "Empty live text must select the saved-audio path")
    }

    func testBackendFailureFallsBackAndSuccessfulLiveTextIsPreserved() async throws {
        let failed = try await RealtimeTranscriptionRecovery.finishOrUseSavedAudio(
            validateOwnership: {}, finish: { throw CocoaError(.coderInvalidValue) }
        )
        XCTAssertTrue(failed.isEmpty)
        let success = try await RealtimeTranscriptionRecovery.finishOrUseSavedAudio(
            validateOwnership: {}, finish: { "live transcript" }
        )
        XCTAssertEqual(success, "live transcript")
    }

    func testUserCancellationDuringFinishDoesNotFallBackOrReturnLateText() async {
        for backendThrows in [false, true] {
            let task = Task { @MainActor in
                try await RealtimeTranscriptionRecovery.finishOrUseSavedAudio(
                    validateOwnership: {}, finish: {
                        withUnsafeCurrentTask { $0?.cancel() }
                        if backendThrows { throw CancellationError() }
                        return "late transcript"
                    }
                )
            }
            do {
                _ = try await task.value
                XCTFail("User cancellation must prevent both fallback and late success")
            } catch { XCTAssertTrue(error is CancellationError) }
        }
    }

    func testLostRecordingOwnershipDuringFinishPreventsFallback() async {
        var ownsRecording = true
        do {
            _ = try await RealtimeTranscriptionRecovery.finishOrUseSavedAudio {
                guard ownsRecording else { throw CancellationError() }
            } finish: {
                ownsRecording = false
                throw CancellationError()
            }
            XCTFail("A cancelled or replaced recording must not start fallback")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testAlreadyCancelledRequestNeverCallsBackend() async {
        var calledBackend = false
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await RealtimeTranscriptionRecovery.finishOrUseSavedAudio(
                validateOwnership: {}, finish: {
                    calledBackend = true
                    return "unexpected"
                }
            )
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled request must stop immediately")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(calledBackend)
    }

    func testStopReleasesJobPreservesQuickNoteAndIgnoresLateWork() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = StopStore(containerURL: directory)
        let audioURL = try store.audioFileURL(fileName: "stop-test.wav")
        try FileManager.default.createDirectory(at: audioURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let audio = Data("saved recording".utf8)
        try audio.write(to: audioURL)
        let session = StopSession(requestID: UUID(), kind: .quickDictation, phase: .failed,
                                  audioFileName: "stop-test.wav", source: "app",
                                  protectedAudioUntilTranscriptCompletes: true)
        try store.saveSession(session)
        let coordinator = DictationCoordinator(store: store)
        coordinator.modelPreparation = .init(phase: .ready, status: "Ready")
        XCTAssertFalse(coordinator.canStopVoiceNoteTranscription)
        coordinator.retryVoiceNoteTranscription(sessionID: session.id)
        XCTAssertTrue(coordinator.canStopVoiceNoteTranscription)
        coordinator.stopVoiceNoteTranscription()
        XCTAssertFalse(coordinator.canStopVoiceNoteTranscription)
        let saved = try XCTUnwrap(store.activeRecordingSession(id: session.id))
        XCTAssertEqual(saved.phase, .failed)
        XCTAssertEqual(saved.lastTranscriptionFailureReason, .interrupted)
        XCTAssertTrue(saved.canRetryVoiceNoteTranscription)
        XCTAssertFalse(saved.isLongForm)
        XCTAssertEqual(try Data(contentsOf: audioURL), audio)
        coordinator.openLongVoiceNote(saved)
        XCTAssertNil(coordinator.presentedLongVoiceNoteSessionID)

        // The cancelled retry task gets a chance to run after a new UI state.
        coordinator.statusText = "Ready"
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(coordinator.statusText, "Ready")
        XCTAssertEqual(try store.activeRecordingSession(id: session.id)?.phase, .failed)
        XCTAssertEqual(try Data(contentsOf: audioURL), audio)
        coordinator.stopVoiceNoteTranscription() // Repeated taps are harmless.
        XCTAssertEqual(coordinator.statusText, "Ready")

        coordinator.recoverVoiceNoteFromDashboard(saved)
        XCTAssertNil(coordinator.presentedLongVoiceNoteSessionID)
        XCTAssertTrue(coordinator.canStopVoiceNoteTranscription)
        XCTAssertFalse(coordinator.canRetrySavedVoiceNote)
        XCTAssertEqual(coordinator.statusText, "Transcribing")
        XCTAssertEqual(try store.activeRecordingSession(id: saved.id)?.phase, .transcriptionQueued)
        coordinator.stopVoiceNoteTranscription()
        XCTAssertTrue(coordinator.canRetrySavedVoiceNote)
    }

    func testCancellationReleasesWaiterWithoutWaitingForBackendAndIgnoresLateCompletion() async {
        let control = OfflineTranscriptionJobControl<String>()
        control.cancel()
        control.resume(returning: .completed("late backend result"))
        do {
            _ = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<OfflineTranscriptionJobOutcome<String>, Error>) in
                control.setContinuation(continuation)
            }
            XCTFail("Cancelled work must not return a transcript")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(control.isFinished)
    }

    func testQuickNoteRetryFailureKeepsProtectedAudio() {
        let session = StopSession(requestID: UUID(), kind: .quickDictation, phase: .transcribing,
                                  audioFileName: "saved.wav", source: "app",
                                  protectedAudioUntilTranscriptCompletes: true)
        let failed = VoiceNoteFailureSessionPolicy.prepare(session, reason: .timeout,
            message: "Stalled", hasRecoverableAudio: true)
        XCTAssertTrue(failed.protectedAudioUntilTranscriptCompletes)
        XCTAssertTrue(failed.canRetryVoiceNoteTranscription)
        let missing = VoiceNoteFailureSessionPolicy.prepare(session, reason: .timeout,
            message: "Missing audio", hasRecoverableAudio: false)
        XCTAssertFalse(missing.canRetryVoiceNoteTranscription)
    }
}
