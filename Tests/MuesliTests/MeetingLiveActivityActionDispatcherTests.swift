import XCTest
@testable import Muesli

@MainActor
final class MeetingLiveActivityActionDispatcherTests: XCTestCase {
    func testStopDispatchesTheLiveActivitySessionIdentifier() {
        defer { MeetingLiveActivityActionDispatcher.register(stopHandler: nil) }
        let sessionID = UUID()
        var receivedSessionID: UUID?
        MeetingLiveActivityActionDispatcher.register { receivedID in
            receivedSessionID = receivedID
            return true
        }

        XCTAssertTrue(MeetingLiveActivityActionDispatcher.stopMeetingRecording(sessionID: sessionID))
        XCTAssertEqual(receivedSessionID, sessionID)
    }

    func testStopIsRejectedWhenTheAppHasNoActiveHandler() {
        defer { MeetingLiveActivityActionDispatcher.register(stopHandler: nil) }
        MeetingLiveActivityActionDispatcher.register(stopHandler: nil)

        XCTAssertFalse(MeetingLiveActivityActionDispatcher.stopMeetingRecording(sessionID: UUID()))
    }
}
