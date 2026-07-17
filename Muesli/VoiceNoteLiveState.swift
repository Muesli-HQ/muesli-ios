import Foundation
import Observation

/// High-frequency presentation state for an active voice-note capture.
///
/// Keeping this state separate from `DictationCoordinator` prevents metering,
/// timer, and streaming-transcript updates from invalidating unrelated screens.
@MainActor
@Observable
final class VoiceNoteLiveState {
    private(set) var inputLevel = 0.0
    private(set) var elapsedSeconds = 0
    private(set) var transcript = ""

    func setInputLevel(_ value: Double) {
        guard value.isFinite else {
            inputLevel = 0
            return
        }
        inputLevel = min(max(value, 0), 1)
    }

    func setElapsedTime(_ value: TimeInterval) {
        elapsedSeconds = VoiceNoteElapsedClock.publishedSeconds(elapsed: value)
    }

    func setTranscript(_ value: String) {
        transcript = value
    }

    func resetInputLevel() {
        inputLevel = 0
    }

    func resetElapsedTime() {
        elapsedSeconds = 0
    }

    func resetTranscript() {
        transcript = ""
    }
}

enum VoiceNoteElapsedClock {
    static func exactElapsed(
        startedAt: Date?,
        now: Date = .now,
        fallback: TimeInterval = 0
    ) -> TimeInterval {
        let elapsed = startedAt.map { now.timeIntervalSince($0) } ?? fallback
        guard elapsed.isFinite else { return 0 }
        return max(0, elapsed)
    }

    static func publishedSeconds(elapsed: TimeInterval) -> Int {
        guard elapsed.isFinite else { return 0 }
        return max(0, Int(elapsed.rounded(.down)))
    }
}
