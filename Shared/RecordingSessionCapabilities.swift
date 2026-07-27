import Foundation

/// What each kind of capture is allowed to do.
///
/// `RecordingSessionKind` existed but was almost never consulted -- two
/// branches in the whole coordinator -- so keyboard dictation and app-initiated
/// voice notes silently shared behaviour that only suits one of them. These are
/// deliberately declared in one place, per kind, so a difference between the
/// two constructs is a value here rather than an `if` somewhere in a
/// six-thousand-line file.
///
/// Adding a case to `RecordingSessionKind` fails to compile until every
/// capability below has an answer for it.
extension RecordingSessionKind {
    /// Whether sustained capture is promoted to long-form treatment:
    /// checkpoint progress, durability messaging, the "Long voice note" phase.
    ///
    /// A keyboard dictation is a request for text to type. The user is waiting
    /// with a text field open, and the surfaces long-form mode drives -- the
    /// recorder card, the timeline row -- are not on screen.
    var supportsLongFormCapture: Bool {
        switch self {
        case .quickDictation, .meeting:
            true
        case .keyboardDictation:
            // Currently true in practice; DictationCoordinator promotes
            // keyboard sessions to "Long voice note". Left as-is here so this
            // type introduces no behaviour change, and can be flipped
            // deliberately.
            true
        }
    }

    /// Whether the Live Activity carries a stop control.
    ///
    /// Meetings run unattended for a long time, so stopping from the Lock
    /// Screen matters. Requires an App Intent that can stop *this* kind of
    /// capture -- see `StopMeetingRecordingIntent`.
    var liveActivityOffersStopControl: Bool {
        switch self {
        case .meeting, .keyboardDictation:
            // Both run with Muesli's own UI off screen -- a meeting because it
            // is unattended, a keyboard dictation because the host app is in
            // front. The Live Activity is the only stop control the user has.
            true
        case .quickDictation:
            // Started from Muesli's own recorder, which is on screen with a
            // stop button already.
            false
        }
    }

    /// Whether the Live Activity exists only for as long as audio is actually
    /// being captured.
    ///
    /// True for every kind. Keyboard dictation previously bound its Live
    /// Activity to keep-mic-on being armed, so a bar appeared when the keyboard
    /// merely became ready and stayed up with nothing recording.
    var liveActivityFollowsCaptureLifetime: Bool {
        switch self {
        case .quickDictation, .meeting, .keyboardDictation:
            true
        }
    }
}
