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
        // Optional for Live Activities created by older app versions.
        var waveform: [Double]? = nil
        var copyURL: URL? = nil

        var isCapturingAudio: Bool {
            switch phase.lowercased() {
            case "listening", "recording", "notepad", "long voice note": true
            default: false
            }
        }
    }

    var sessionID: String
    var requestID: String?
    /// Display title of the capture kind. Presentation only -- do not branch on
    /// it. The widget runs in a separate target that cannot see
    /// `RecordingSessionKind`, so capabilities travel as explicit fields below.
    var kind: String

    /// Optional so an activity started by an earlier build still decodes; when
    /// absent, fall back to the old meaning of `kind`.
    var offersStopControl: Bool?
    var showsDictationWaveform: Bool? = nil

    var showsStopControl: Bool {
        offersStopControl ?? isMeeting
    }

    var isMeeting: Bool {
        kind == Self.meetingKind
    }
}
