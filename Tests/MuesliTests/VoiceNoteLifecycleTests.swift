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

    func testOnlyActiveLifecyclePhasesOwnAudioWork() {
        let id = UUID()
        var state = VoiceNoteLifecycleReducer.reduce(.init(), event: .recordingStarted(id))
        XCTAssertTrue(state.isWorkActive)

        state = VoiceNoteLifecycleReducer.reduce(state, event: .stopRequested(id))
        XCTAssertTrue(state.isWorkActive)
        state = VoiceNoteLifecycleReducer.reduce(state, event: .transcriptionStarted(id))
        XCTAssertTrue(state.isWorkActive)

        state = VoiceNoteLifecycleReducer.reduce(state, event: .transcriptionFailed(id))
        XCTAssertFalse(state.isWorkActive)
    }

    func testRequestOwnershipRejectsForeignCommandsOnlyWhileWorkIsActive() {
        let owner = UUID()
        let foreign = UUID()
        let activeOwnership = VoiceNoteRequestOwnership(requestID: owner, isWorkActive: true)

        XCTAssertTrue(activeOwnership.accepts(requestID: owner))
        XCTAssertFalse(activeOwnership.accepts(requestID: foreign))

        let retryableOwnership = VoiceNoteRequestOwnership(requestID: owner, isWorkActive: false)
        XCTAssertTrue(retryableOwnership.accepts(requestID: foreign))

        let unknownActiveOwnership = VoiceNoteRequestOwnership(requestID: nil, isWorkActive: true)
        XCTAssertFalse(unknownActiveOwnership.accepts(requestID: foreign))
    }

    func testLifecycleRunnerGenerationDistinguishesRetriesOfTheSameRequest() {
        let sessionID = UUID()
        let requestID = UUID()
        let first = VoiceNoteLifecycleRunner(sessionID: sessionID, requestID: requestID)
        let retry = VoiceNoteLifecycleRunner(sessionID: sessionID, requestID: requestID)

        XCTAssertEqual(first.sessionID, retry.sessionID)
        XCTAssertEqual(first.requestID, retry.requestID)
        XCTAssertNotEqual(first.id, retry.id)
    }

    func testCheckpointRetentionPolicyKeepsOnlyRecoverableAudio() {
        let protectedFailure = Muesli.RecordingSession(
            kind: .quickDictation,
            phase: .failed,
            audioFileName: "protected.wav",
            protectedAudioUntilTranscriptCompletes: true
        )
        XCTAssertFalse(
            VoiceNoteCheckpointRetentionPolicy.shouldDeleteCheckpoints(for: protectedFailure)
        )

        let explicitlyDeleted = Muesli.RecordingSession(
            kind: .quickDictation,
            phase: .failed,
            audioFileName: nil,
            protectedAudioUntilTranscriptCompletes: false
        )
        XCTAssertTrue(
            VoiceNoteCheckpointRetentionPolicy.shouldDeleteCheckpoints(for: explicitlyDeleted)
        )

        let failedShortNote = Muesli.RecordingSession(
            kind: .keyboardDictation,
            phase: .failed,
            audioFileName: "short.wav",
            longFormThresholdSeconds: 60
        )
        XCTAssertTrue(
            VoiceNoteCheckpointRetentionPolicy.shouldDeleteCheckpoints(for: failedShortNote)
        )

        let activeShortNote = Muesli.RecordingSession(
            kind: .keyboardDictation,
            phase: .recording,
            longFormThresholdSeconds: 60
        )
        XCTAssertFalse(
            VoiceNoteCheckpointRetentionPolicy.shouldDeleteCheckpoints(for: activeShortNote)
        )

        let completed = Muesli.RecordingSession(kind: .quickDictation, phase: .completed)
        XCTAssertTrue(VoiceNoteCheckpointRetentionPolicy.shouldDeleteCheckpoints(for: completed))
        XCTAssertTrue(VoiceNoteCheckpointRetentionPolicy.shouldDeleteCheckpoints(for: nil))
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
