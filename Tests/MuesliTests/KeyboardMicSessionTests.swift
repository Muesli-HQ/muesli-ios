import XCTest
@testable import Muesli

final class KeyboardMicSessionTests: XCTestCase {
    func testLifecycleKeepsOneMicSessionAcrossCompletedDictations() throws {
        var state = KeyboardSessionReducer.reduce(.init(), event: .micRequested)
        let id = try XCTUnwrap(state.micSession.id)
        state = KeyboardSessionReducer.reduce(state, event: .startRequested)
        state = KeyboardSessionReducer.reduce(state, event: .startSucceeded)
        for _ in 0..<2 {
            let request = UUID()
            state = KeyboardSessionReducer.reduce(state, event: .handoffStarted(request))
            state = KeyboardSessionReducer.reduce(state, event: .recordingStarted(request))
            state = KeyboardSessionReducer.reduce(state, event: .transcribing(request))
            state = KeyboardSessionReducer.reduce(state, event: .requestFinished)
            XCTAssertEqual(state.phase, .ready)
            XCTAssertTrue(state.isArmed)
            XCTAssertEqual(state.micSession.id, id)
        }
    }

    func testLifecycleMicOffPreservesTranscriptDeliveryAndRejectsOldOwnership() throws {
        var state = KeyboardSessionReducer.reduce(.init(), event: .micRequested)
        let oldID = try XCTUnwrap(state.micSession.id)
        state = KeyboardSessionReducer.reduce(state, event: .startSucceeded)
        let request = UUID()
        state = KeyboardSessionReducer.reduce(state, event: .transcribing(request))
        state = KeyboardSessionReducer.reduce(state, event: .micStopped)
        state = KeyboardSessionReducer.reduce(state, event: .standbyStopped(preserveHandoff: true))
        XCTAssertEqual(state.phase, .transcribing(request))
        XCTAssertFalse(state.isArmed)
        XCTAssertTrue(state.micSession.isPaused)
        state = KeyboardSessionReducer.reduce(state, event: .requestFinished)
        XCTAssertEqual(state.phase, .off)
        state = KeyboardSessionReducer.reduce(state, event: .micRequested)
        XCTAssertFalse(state.micSession.owns(oldID))
        XCTAssertFalse(state.micSession.isPaused)
    }

    func testAStoredPreferenceDoesNotCreateAnActiveSession() {
        let session = KeyboardMicSession()
        XCTAssertNil(session.id)
    }

    func testRepeatedStartsShareOneSessionUntilExplicitMicOff() {
        var session = KeyboardMicSession()
        let first = session.begin()
        let startupGeneration = session.generation
        XCTAssertEqual(session.begin(), first)
        session.stop()
        XCTAssertNil(session.id)
        XCTAssertTrue(session.isPaused)
        XCTAssertNotEqual(session.generation, startupGeneration)
        XCTAssertFalse(session.owns(first))
        let second = session.begin()
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(session.isPaused)
        XCTAssertFalse(session.owns(first), "A stale Island may not stop the next microphone session")
    }

    func testTurningOffDuringStartupInvalidatesItsOwnership() {
        var session = KeyboardMicSession()
        let starting = session.begin()
        session.stop()
        XCTAssertFalse(session.owns(starting))
        _ = session.begin()
        XCTAssertFalse(session.owns(starting), "A delayed permission callback cannot revive the old session")
    }

    @MainActor
    func testMicOffIntentWaitsForAcknowledgedShutdownAndPassesSessionIdentity() async {
        let sessionID = UUID()
        var stopped = false
        KeyboardMicActionDispatcher.register { id in
            XCTAssertEqual(id, sessionID)
            await Task.yield()
            stopped = true
            return true
        }
        defer { KeyboardMicActionDispatcher.register(nil) }
        let result = await KeyboardMicActionDispatcher.turnOff(sessionID: sessionID)
        XCTAssertTrue(result)
        XCTAssertTrue(stopped)
    }

    @MainActor
    func testMissingStopHandlerDoesNotClaimSuccess() async {
        KeyboardMicActionDispatcher.register(nil)
        let result = await KeyboardMicActionDispatcher.turnOff(sessionID: UUID())
        XCTAssertFalse(result)
    }
}
