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
}
