import XCTest
@testable import Muesli

final class KeyboardHandoffInvariantTests: XCTestCase {
    func testOlderRequestCannotOverwriteNewerActiveRequest() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let olderRequestID = UUID()
        let newerRequestID = UUID()
        let newerActive = KeyboardHandoffState(
            requestID: newerRequestID,
            phase: .recordingStarted,
            message: "Listening",
            createdAt: Date(timeIntervalSince1970: 200),
            updatedAt: Date(timeIntervalSince1970: 210)
        )
        let lateOlderCompletion = KeyboardHandoffState(
            requestID: olderRequestID,
            phase: .resultReady,
            message: "Late result",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 300)
        )

        XCTAssertTrue(try fixture.store.saveKeyboardHandoffState(newerActive))
        XCTAssertFalse(try fixture.store.saveKeyboardHandoffState(lateOlderCompletion))
        XCTAssertEqual(try fixture.store.keyboardHandoffState(), newerActive)
    }

    func testNewerRequestCanStartAfterTerminalOlderRequest() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let terminalOlderRequest = KeyboardHandoffState(
            requestID: UUID(),
            phase: .inserted,
            message: "Inserted",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 150)
        )
        let newerStart = KeyboardHandoffState(
            requestID: UUID(),
            phase: .startRequested,
            message: "Starting",
            createdAt: Date(timeIntervalSince1970: 200),
            updatedAt: Date(timeIntervalSince1970: 200)
        )

        XCTAssertTrue(try fixture.store.saveKeyboardHandoffState(terminalOlderRequest))
        XCTAssertTrue(try fixture.store.saveKeyboardHandoffState(newerStart))
        XCTAssertEqual(try fixture.store.keyboardHandoffState(), newerStart)
    }

    func testFailedRequestRetryWithNewAttemptCanReachResultReady() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let failed = KeyboardHandoffState(
            requestID: UUID(),
            phase: .failed,
            message: "Transcription failed",
            recoveryAttemptCount: 1,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        let retrying = failed.advanced(
            to: .transcribingStarted,
            message: "Retrying transcription",
            recoveryAttemptCount: 2,
            updatedAt: Date(timeIntervalSince1970: 300)
        )
        let resultReady = retrying.advanced(
            to: .resultReady,
            message: "Ready to insert",
            updatedAt: Date(timeIntervalSince1970: 400)
        )

        XCTAssertTrue(try fixture.store.saveKeyboardHandoffState(failed))
        XCTAssertTrue(try fixture.store.saveKeyboardHandoffState(retrying))
        XCTAssertTrue(try fixture.store.saveKeyboardHandoffState(resultReady))
        XCTAssertEqual(try fixture.store.keyboardHandoffState(), resultReady)
    }

    func testConditionalPendingCommandClearPreservesNewerCommand() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let requestID = UUID()
        let consumedStop = DictationCommand(
            requestID: requestID,
            action: .stop,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let newerCancel = DictationCommand(
            requestID: requestID,
            action: .cancel,
            createdAt: Date(timeIntervalSince1970: 200)
        )

        try fixture.store.saveCommand(consumedStop)
        XCTAssertEqual(try fixture.store.pendingCommand(), consumedStop)

        try fixture.store.saveCommand(newerCancel)
        XCTAssertFalse(try fixture.store.clearPendingCommand(id: consumedStop.id))
        XCTAssertEqual(try fixture.store.pendingCommand(), newerCancel)

        XCTAssertTrue(try fixture.store.clearPendingCommand(id: newerCancel.id))
        XCTAssertNil(try fixture.store.pendingCommand())
    }

    func testAtomicCompletionRejectsMismatchedKeyboardHandoffWithoutPartialWrites() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let requestID = UUID()
        let currentSession = RecordingSession(
            requestID: requestID,
            kind: .keyboardDictation,
            phase: .transcribing,
            source: "keyboard"
        )
        try fixture.store.saveSession(currentSession)
        let sessionBeforeAttempt = try XCTUnwrap(
            try fixture.store.recordingSession(id: currentSession.id)
        )

        let statusBeforeAttempt = DictationStatus(
            requestID: requestID,
            phase: .transcribing,
            message: "Transcribing"
        )
        try fixture.store.saveStatus(statusBeforeAttempt)
        let handoffBeforeAttempt = KeyboardHandoffState(
            requestID: requestID,
            phase: .transcribingStarted,
            message: "Transcribing",
            createdAt: currentSession.createdAt,
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        XCTAssertTrue(try fixture.store.saveKeyboardHandoffState(handoffBeforeAttempt))

        let transcript = Transcript(
            sessionID: currentSession.id,
            text: "Must commit as one coherent request",
            engineIdentifier: "test-engine"
        )
        var completedSession = currentSession
        completedSession.phase = .completed
        completedSession.transcriptID = transcript.id
        completedSession.engineIdentifier = transcript.engineIdentifier
        let result = DictationResult(
            requestID: requestID,
            sessionID: currentSession.id,
            text: transcript.text,
            engineIdentifier: transcript.engineIdentifier,
            source: "keyboard"
        )
        let mismatchedHandoff = KeyboardHandoffState(
            requestID: UUID(),
            phase: .resultReady,
            message: "Wrong request",
            createdAt: Date(timeIntervalSince1970: 300),
            updatedAt: Date(timeIntervalSince1970: 300)
        )

        XCTAssertFalse(try fixture.store.completeVoiceNoteSession(
            completedSession,
            transcript: transcript,
            result: result,
            keyboardHandoffState: mismatchedHandoff
        ))

        XCTAssertEqual(try fixture.store.recordingSession(id: currentSession.id), sessionBeforeAttempt)
        XCTAssertNil(try fixture.store.transcript(for: currentSession.id))
        XCTAssertNil(try fixture.store.result(for: requestID))
        XCTAssertTrue(try fixture.store.resultsHistory().isEmpty)
        XCTAssertEqual(try fixture.store.status(), statusBeforeAttempt)
        XCTAssertEqual(try fixture.store.keyboardHandoffState(), handoffBeforeAttempt)
    }

    private func makeFixture() throws -> StoreFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-handoff-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return StoreFixture(
            directory: directory,
            store: SharedStore(containerURL: directory)
        )
    }
}

private struct StoreFixture {
    let directory: URL
    let store: SharedStore

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}
