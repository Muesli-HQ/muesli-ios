import XCTest
@testable import Muesli

@MainActor
final class MeetingLiveActivityActionDispatcherTests: XCTestCase {
    func testOnlyMeetingAttributesExposeTheMeetingStopControl() {
        let meeting = MuesliLiveActivityAttributes(
            sessionID: UUID().uuidString,
            requestID: nil,
            kind: RecordingSessionKind.meeting.title
        )
        let dictation = MuesliLiveActivityAttributes(
            sessionID: UUID().uuidString,
            requestID: nil,
            kind: RecordingSessionKind.quickDictation.title
        )

        XCTAssertTrue(meeting.isMeeting)
        XCTAssertFalse(dictation.isMeeting)
    }

    func testStopDispatchesTheLiveActivitySessionIdentifier() {
        defer { MeetingLiveActivityActionDispatcher.register(stopHandler: nil) }
        let sessionID = UUID()
        var receivedSessionID: UUID?
        MeetingLiveActivityActionDispatcher.register { receivedID in
            receivedSessionID = receivedID
            return .accepted
        }

        XCTAssertEqual(
            MeetingLiveActivityActionDispatcher.stopMeetingRecording(sessionID: sessionID),
            .accepted
        )
        XCTAssertEqual(receivedSessionID, sessionID)
    }

    func testStopPreservesAnIdempotentAlreadyHandledResult() {
        defer { MeetingLiveActivityActionDispatcher.register(stopHandler: nil) }
        MeetingLiveActivityActionDispatcher.register { _ in .alreadyHandled }

        XCTAssertEqual(
            MeetingLiveActivityActionDispatcher.stopMeetingRecording(sessionID: UUID()),
            .alreadyHandled
        )
    }

    func testStopIsRejectedWhenTheAppHasNoActiveHandler() {
        defer { MeetingLiveActivityActionDispatcher.register(stopHandler: nil) }
        MeetingLiveActivityActionDispatcher.register(stopHandler: nil)

        XCTAssertEqual(
            MeetingLiveActivityActionDispatcher.stopMeetingRecording(sessionID: UUID()),
            .unavailable
        )
    }

    func testRecentEndedSessionIDsRemainBoundedAndEvictTheOldest() {
        var sessionIDs = BoundedRecentSessionIDs(capacity: 2)
        let first = UUID()
        let second = UUID()
        let third = UUID()

        sessionIDs.insert(first)
        sessionIDs.insert(second)
        sessionIDs.insert(first)
        sessionIDs.insert(third)

        XCTAssertFalse(sessionIDs.contains(first))
        XCTAssertTrue(sessionIDs.contains(second))
        XCTAssertTrue(sessionIDs.contains(third))
    }
}
