import ActivityKit
import Foundation

struct MuesliLiveActivityAttributes: ActivityAttributes {
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
}
