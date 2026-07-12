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
}
