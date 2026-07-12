import XCTest
@testable import Muesli

final class MeetingLifecycleReducerTests: XCTestCase {
    func testLifecycleMovesThroughRecordingAndTranscription() {
        let sessionID = UUID()

        var state = MeetingLifecycleReducer.reduce(
            MeetingLifecycleState(),
            event: .startRequested(sessionID)
        )
        XCTAssertEqual(state.phase, .starting(sessionID))
        XCTAssertEqual(state.activeSessionID, sessionID)
        XCTAssertTrue(state.isRecordingVisible)

        state = MeetingLifecycleReducer.reduce(state, event: .recordingStarted(sessionID))
        XCTAssertEqual(state.phase, .recording(sessionID))
        XCTAssertTrue(state.isRecordingVisible)

        state = MeetingLifecycleReducer.reduce(state, event: .stopRequested(sessionID))
        XCTAssertEqual(state.phase, .stopping(sessionID))
        XCTAssertTrue(state.isRecordingVisible)

        state = MeetingLifecycleReducer.reduce(state, event: .transcriptionStarted(sessionID))
        XCTAssertEqual(state.phase, .transcribing(sessionID))
        XCTAssertFalse(state.isRecordingVisible)

        state = MeetingLifecycleReducer.reduce(state, event: .finished(sessionID))
        XCTAssertEqual(state.phase, .idle)
        XCTAssertNil(state.activeSessionID)
    }

    func testLifecycleIgnoresEventsForStaleSessions() {
        let activeID = UUID()
        let staleID = UUID()
        let activeState = MeetingLifecycleReducer.reduce(
            MeetingLifecycleState(),
            event: .startRequested(activeID)
        )

        XCTAssertEqual(
            MeetingLifecycleReducer.reduce(activeState, event: .recordingStarted(staleID)),
            activeState
        )
        XCTAssertEqual(
            MeetingLifecycleReducer.reduce(activeState, event: .finished(staleID)),
            activeState
        )
    }

    func testStartAndTranscriptionCannotReplaceActiveMeeting() {
        let activeID = UUID()
        let competingID = UUID()
        let recording = MeetingLifecycleReducer.reduce(
            MeetingLifecycleReducer.reduce(.init(), event: .startRequested(activeID)),
            event: .recordingStarted(activeID)
        )

        for event in [
            MeetingLifecycleEvent.startRequested(competingID),
            .transcriptionStarted(competingID),
        ] {
            let transition = MeetingLifecycleReducer.transition(recording, event: event)
            XCTAssertFalse(transition.accepted)
            XCTAssertEqual(transition.state, recording)
        }
    }

    func testDuplicateStopAndLateRecordingEventsAreRejected() {
        let sessionID = UUID()
        var state = MeetingLifecycleReducer.reduce(.init(), event: .startRequested(sessionID))
        state = MeetingLifecycleReducer.reduce(state, event: .recordingStarted(sessionID))
        state = MeetingLifecycleReducer.reduce(state, event: .stopRequested(sessionID))

        for event in [
            MeetingLifecycleEvent.stopRequested(sessionID),
            .recordingStarted(sessionID),
        ] {
            let transition = MeetingLifecycleReducer.transition(state, event: event)
            XCTAssertFalse(transition.accepted)
            XCTAssertEqual(transition.state, state)
        }
    }

    func testPersistedRecoveryCanEnterCancellationFromIdle() {
        let sessionID = UUID()
        let transition = MeetingLifecycleReducer.transition(
            .init(),
            event: .cancelRequested(sessionID)
        )

        XCTAssertTrue(transition.accepted)
        XCTAssertEqual(transition.state.phase, .cancelling(sessionID))
        XCTAssertEqual(
            MeetingLifecycleReducer.reduce(transition.state, event: .finished(sessionID)).phase,
            .idle
        )
    }

    func testLifecycleCancellationBecomesNonRecordingTerminalWork() {
        let sessionID = UUID()
        var state = MeetingLifecycleReducer.reduce(
            MeetingLifecycleState(),
            event: .startRequested(sessionID)
        )

        state = MeetingLifecycleReducer.reduce(state, event: .cancelRequested(sessionID))

        XCTAssertEqual(state.phase, .cancelling(sessionID))
        XCTAssertTrue(state.isCancelling)
        XCTAssertFalse(state.isRecordingVisible)
    }

    func testLifecycleReportsOnlyTheActiveStartupSessionAsStarting() {
        let sessionID = UUID()
        let otherID = UUID()
        let state = MeetingLifecycleReducer.reduce(
            MeetingLifecycleState(),
            event: .startRequested(sessionID)
        )

        XCTAssertTrue(state.isStarting(sessionID: sessionID))
        XCTAssertFalse(state.isStarting(sessionID: otherID))
        XCTAssertFalse(MeetingLifecycleState().isStarting(sessionID: sessionID))
    }

    func testLifecycleOwnershipIsScopedToItsSession() {
        let sessionID = UUID()
        let otherID = UUID()
        let state = MeetingLifecycleState(phase: .transcribing(sessionID))

        XCTAssertTrue(state.owns(sessionID: sessionID))
        XCTAssertFalse(state.owns(sessionID: otherID))
        XCTAssertFalse(MeetingLifecycleState().owns(sessionID: sessionID))
    }

    func testOnlyStartupAndRecordingAcceptCaptureStopCommands() {
        let sessionID = UUID()

        XCTAssertTrue(
            MeetingLifecycleState(phase: .starting(sessionID)).acceptsCaptureStopRequest
        )
        XCTAssertTrue(
            MeetingLifecycleState(phase: .recording(sessionID)).acceptsCaptureStopRequest
        )

        for phase in [
            MeetingLifecycleState.Phase.idle,
            .stopping(sessionID),
            .transcribing(sessionID),
            .cancelling(sessionID),
        ] {
            XCTAssertFalse(
                MeetingLifecycleState(phase: phase).acceptsCaptureStopRequest,
                "Unexpected capture stop availability for \(phase)"
            )
        }
    }

    func testSessionInventoryPreservesActiveMeetingMissingFromPersistedSnapshot() {
        let activeMeeting = Muesli.RecordingSession(
            kind: .meeting,
            title: "Live meeting",
            phase: .recording
        )
        let completedMeeting = Muesli.RecordingSession(
            kind: .meeting,
            title: "Earlier meeting",
            phase: .completed
        )

        let sessions = RecordingSessionInventory.preservingActiveSession(
            activeMeeting,
            in: [completedMeeting]
        )

        XCTAssertEqual(sessions.map { $0.id }, [activeMeeting.id, completedMeeting.id])
    }

    func testSessionInventoryDoesNotDuplicatePersistedActiveMeeting() {
        let activeMeeting = Muesli.RecordingSession(kind: .meeting, phase: .recording)

        let sessions = RecordingSessionInventory.preservingActiveSession(
            activeMeeting,
            in: [activeMeeting]
        )

        XCTAssertEqual(sessions, [activeMeeting])
    }

    func testRuntimeInvariantDetectsRecordingWithoutRecorder() {
        let sessionID = UUID()
        let snapshot = MeetingRuntimeSnapshot(
            lifecycle: MeetingLifecycleState(phase: .recording(sessionID)),
            activeSessionID: sessionID,
            persistedSessionIDs: [sessionID],
            recorderIsPresent: false
        )

        XCTAssertEqual(
            MeetingRuntimeInvariant.issues(in: snapshot),
            [.missingRecorder(sessionID)]
        )
    }

    func testRuntimeInvariantAllowsExpectedRecorderAbsence() {
        let sessionID = UUID()
        for phase in [
            MeetingLifecycleState.Phase.starting(sessionID),
            .transcribing(sessionID),
            .cancelling(sessionID),
        ] {
            let snapshot = MeetingRuntimeSnapshot(
                lifecycle: MeetingLifecycleState(phase: phase),
                activeSessionID: sessionID,
                persistedSessionIDs: [sessionID],
                recorderIsPresent: false
            )
            XCTAssertTrue(MeetingRuntimeInvariant.issues(in: snapshot).isEmpty)
        }
    }

    func testRuntimeInvariantRequiresPersistedSessionToBeRestoredInMemory() {
        let sessionID = UUID()
        let snapshot = MeetingRuntimeSnapshot(
            lifecycle: MeetingLifecycleState(phase: .transcribing(sessionID)),
            activeSessionID: nil,
            persistedSessionIDs: [sessionID],
            recorderIsPresent: false
        )

        XCTAssertEqual(
            MeetingRuntimeInvariant.issues(in: snapshot),
            [.activeSessionNeedsRestore(sessionID)]
        )
    }

    func testRuntimeInvariantDetectsOrphanedAndConflictingOwnership() {
        let expectedID = UUID()
        let otherID = UUID()
        XCTAssertEqual(
            MeetingRuntimeInvariant.issues(in: MeetingRuntimeSnapshot(
                lifecycle: .init(),
                activeSessionID: nil,
                persistedSessionIDs: [],
                recorderIsPresent: true
            )),
            [.orphanedRecorder]
        )

        let issues = MeetingRuntimeInvariant.issues(in: MeetingRuntimeSnapshot(
            lifecycle: MeetingLifecycleState(phase: .recording(expectedID)),
            activeSessionID: otherID,
            persistedSessionIDs: [],
            recorderIsPresent: true
        ))
        XCTAssertEqual(issues, [
            .conflictingActiveSession(expected: expectedID, actual: otherID),
            .missingSession(expectedID),
        ])
    }

    func testRuntimeInvariantDetectsActiveMeetingWithoutLifecycleOwnership() {
        let sessionID = UUID()
        let issues = MeetingRuntimeInvariant.issues(in: MeetingRuntimeSnapshot(
            lifecycle: .init(),
            activeSessionID: sessionID,
            persistedSessionIDs: [sessionID],
            recorderIsPresent: true
        ))

        XCTAssertEqual(issues, [
            .orphanedActiveSession(sessionID),
            .orphanedRecorder,
        ])
    }

    func testRuntimeInvariantRejectsRecorderDuringTranscription() {
        let sessionID = UUID()
        let issues = MeetingRuntimeInvariant.issues(in: MeetingRuntimeSnapshot(
            lifecycle: MeetingLifecycleState(phase: .transcribing(sessionID)),
            activeSessionID: sessionID,
            persistedSessionIDs: [sessionID],
            recorderIsPresent: true
        ))

        XCTAssertEqual(issues, [.recorderPresentOutsideCapture(sessionID)])
    }
}
