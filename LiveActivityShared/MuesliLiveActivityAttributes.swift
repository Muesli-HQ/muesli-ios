import ActivityKit
import Foundation

struct MuesliLiveActivityAttributes: ActivityAttributes {
    static let meetingKind = "Meeting"

    struct ContentState: Codable, Hashable {
        var title: String
        var phase: String
        var detail: String
        var startedAt: Date
        var accent: String
    }

    var sessionID: String
    var requestID: String?
    var kind: String

    var isMeeting: Bool {
        kind == Self.meetingKind
    }
}
