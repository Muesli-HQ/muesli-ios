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

    func testStopDispatchesTheLiveActivitySessionIdentifier() async {
        defer { MeetingLiveActivityActionDispatcher.register(stopHandler: nil) }
        let sessionID = UUID()
        var receivedSessionID: UUID?
        MeetingLiveActivityActionDispatcher.register { receivedID in
            await Task.yield()
            receivedSessionID = receivedID
            return .accepted
        }

        let result = await MeetingLiveActivityActionDispatcher.stopMeetingRecording(sessionID: sessionID)
        XCTAssertEqual(result, .accepted)
        XCTAssertEqual(receivedSessionID, sessionID)
    }

    func testStopPreservesAnIdempotentAlreadyHandledResult() async {
        defer { MeetingLiveActivityActionDispatcher.register(stopHandler: nil) }
        MeetingLiveActivityActionDispatcher.register { _ in .alreadyHandled }

        let result = await MeetingLiveActivityActionDispatcher.stopMeetingRecording(sessionID: UUID())
        XCTAssertEqual(result, .alreadyHandled)
    }

    func testStopIsRejectedWhenTheAppHasNoActiveHandler() async {
        defer { MeetingLiveActivityActionDispatcher.register(stopHandler: nil) }
        MeetingLiveActivityActionDispatcher.register(stopHandler: nil)

        let result = await MeetingLiveActivityActionDispatcher.stopMeetingRecording(sessionID: UUID())
        XCTAssertEqual(result, .unavailable)
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
