import XCTest
@testable import Muesli

/// Keyboard dictation and app-initiated voice notes are different constructs
/// that had been sharing behaviour by default. These pin the differences so
/// re-merging them takes a deliberate edit here, with a failing test to explain
/// what it changes.
final class RecordingSessionCapabilitiesTests: XCTestCase {
    func testEveryKindDeclaresEveryCapability() {
        // RecordingSessionKind is CaseIterable and the capabilities are
        // exhaustive switches, so this fails to compile -- not at runtime --
        // if a kind is added without deciding what it can do.
        for kind in RecordingSessionKind.allCases {
            _ = kind.supportsLongFormCapture
            _ = kind.liveActivityOffersStopControl
            _ = kind.liveActivityFollowsCaptureLifetime
        }
        XCTAssertEqual(RecordingSessionKind.allCases.count, 3)
    }

    /// Captures that run with Muesli's own UI off screen need a stop control on
    /// the Live Activity, because it is the only one the user can reach. A
    /// quick dictation has the app's recorder in front of it already.
    func testCapturesWithNoOnScreenStopOfferOneOnTheLiveActivity() {
        XCTAssertTrue(RecordingSessionKind.meeting.liveActivityOffersStopControl)
        XCTAssertTrue(RecordingSessionKind.keyboardDictation.liveActivityOffersStopControl)
        XCTAssertFalse(RecordingSessionKind.quickDictation.liveActivityOffersStopControl)
    }

    /// A Live Activity describes a recording in progress. No kind may show one
    /// for merely being ready to record -- which is what keyboard dictation did
    /// while keep-mic-on was armed.
    func testNoKindShowsALiveActivityWithoutCapture() {
        for kind in RecordingSessionKind.allCases {
            XCTAssertTrue(
                kind.liveActivityFollowsCaptureLifetime,
                "\(kind.title) can show a Live Activity with nothing recording"
            )
        }
    }

    func testLongFormTreatmentStillAppliesToKeyboardDictation() {
        // Current behaviour, recorded rather than endorsed: the coordinator
        // promotes keyboard sessions to "Long voice note" like any other.
        XCTAssertTrue(RecordingSessionKind.keyboardDictation.supportsLongFormCapture)
    }

    /// The widget target cannot see RecordingSessionKind, so capabilities have
    /// to survive the trip through the attributes rather than being re-derived
    /// from a display string on the far side.
    func testCapabilitiesSurviveTheTripToTheWidget() {
        for kind in RecordingSessionKind.allCases {
            let attributes = MuesliLiveActivityAttributes(
                sessionID: UUID().uuidString,
                requestID: nil,
                kind: kind.title,
                offersStopControl: kind.liveActivityOffersStopControl
            )
            XCTAssertEqual(
                attributes.showsStopControl,
                kind.liveActivityOffersStopControl,
                "\(kind.title) lost its stop-control capability in transit"
            )
        }
    }

    /// An activity started by an earlier build has no capability field. It must
    /// still render the way it did when it was started.
    func testActivitiesFromEarlierBuildsStillRender() {
        let legacyMeeting = MuesliLiveActivityAttributes(
            sessionID: UUID().uuidString,
            requestID: nil,
            kind: MuesliLiveActivityAttributes.meetingKind,
            offersStopControl: nil
        )
        XCTAssertTrue(legacyMeeting.showsStopControl)

        let legacyKeyboard = MuesliLiveActivityAttributes(
            sessionID: UUID().uuidString,
            requestID: nil,
            kind: RecordingSessionKind.keyboardDictation.title,
            offersStopControl: nil
        )
        XCTAssertFalse(legacyKeyboard.showsStopControl)
    }
}
