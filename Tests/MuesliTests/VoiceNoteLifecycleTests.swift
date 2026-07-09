import XCTest
@testable import Muesli

final class VoiceNoteLifecycleTests: XCTestCase {
    func testLifecycleMovesThroughProtectedRecordingAndCompletion() {
        let id = UUID()
        var state = VoiceNoteLifecycleReducer.reduce(.init(), event: .recordingStarted(id))
        XCTAssertEqual(state.phase, .recordingShort(id))

        state = VoiceNoteLifecycleReducer.reduce(state, event: .longFormActivated(id))
        XCTAssertEqual(state.phase, .recordingLongProtected(id))
        XCTAssertTrue(state.isLongFormVisible)

        state = VoiceNoteLifecycleReducer.reduce(state, event: .stopRequested(id))
        state = VoiceNoteLifecycleReducer.reduce(state, event: .audioFinalized(id))
        state = VoiceNoteLifecycleReducer.reduce(state, event: .transcriptionQueued(id))
        state = VoiceNoteLifecycleReducer.reduce(state, event: .transcriptionStarted(id))
        state = VoiceNoteLifecycleReducer.reduce(state, event: .finished(id))
        XCTAssertEqual(state.phase, .idle)
    }

    func testLifecycleRejectsStaleSessionEvents() {
        let active = UUID()
        let stale = UUID()
        let state = VoiceNoteLifecycleReducer.reduce(.init(), event: .recordingStarted(active))
        XCTAssertEqual(
            VoiceNoteLifecycleReducer.reduce(state, event: .longFormActivated(stale)),
            state
        )
    }

    func testLifecycleRejectsLateEventsAfterFinishing() {
        let id = UUID()
        let idle = VoiceNoteLifecycleState()

        XCTAssertEqual(
            VoiceNoteLifecycleReducer.reduce(idle, event: .transcriptionQueued(id)),
            idle
        )
        XCTAssertEqual(
            VoiceNoteLifecycleReducer.reduce(idle, event: .transcriptionStarted(id)),
            idle
        )
        XCTAssertEqual(
            VoiceNoteLifecycleReducer.reduce(idle, event: .cancelRequested(id)),
            idle
        )
    }

    func testFailureCanRetry() {
        let id = UUID()
        var state = VoiceNoteLifecycleReducer.reduce(.init(), event: .retryRequested(id))
        state = VoiceNoteLifecycleReducer.reduce(state, event: .transcriptionStarted(id))
        state = VoiceNoteLifecycleReducer.reduce(state, event: .transcriptionFailed(id))
        XCTAssertEqual(state.phase, .failedRetryable(id))

        state = VoiceNoteLifecycleReducer.reduce(state, event: .retryRequested(id))
        XCTAssertEqual(state.phase, .transcriptionQueued(id))
    }

    func testProtectedAudioSurvivesFailureUntilExplicitlyRetainedOrCompleted() {
        let protected = Muesli.RecordingSession(
            kind: .quickDictation,
            protectedAudioUntilTranscriptCompletes: true
        )
        XCTAssertFalse(VoiceNoteAudioRetentionPolicy.shouldDeleteAudioAfterFailure(protected))

        let short = Muesli.RecordingSession(kind: .quickDictation)
        XCTAssertTrue(VoiceNoteAudioRetentionPolicy.shouldDeleteAudioAfterFailure(short))

        let retained = Muesli.RecordingSession(kind: .quickDictation, keepsAudioRecording: true)
        XCTAssertFalse(VoiceNoteAudioRetentionPolicy.shouldDeleteAudioAfterSuccess(retained))
    }
}
