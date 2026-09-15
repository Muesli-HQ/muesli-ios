import ActivityKit
import Foundation

/// A microphone session outlives individual recordings and has no history row.
struct KeyboardMicActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var isRecording: Bool
        var isReady: Bool
        var waveform: [Double]? = nil

        var title: String { isRecording ? "Listening" : (isReady ? "Mic ready" : "Mic paused") }
    }

    let sessionID: String
}
