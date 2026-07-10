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

    func testLifecycleRejectsLongFormActivationAfterStop() {
        let id = UUID()
        var state = VoiceNoteLifecycleReducer.reduce(.init(), event: .recordingStarted(id))
        state = VoiceNoteLifecycleReducer.reduce(state, event: .stopRequested(id))

        let transition = VoiceNoteLifecycleReducer.transition(
            state,
            event: .longFormActivated(id)
        )

        XCTAssertFalse(transition.accepted)
        XCTAssertEqual(transition.state.phase, .stopping(id))
    }

    func testLifecycleRejectsOutOfOrderFinalizationAndQueueEvents() {
        let id = UUID()
        let recording = VoiceNoteLifecycleReducer.reduce(.init(), event: .recordingStarted(id))

        let finalized = VoiceNoteLifecycleReducer.transition(
            recording,
            event: .audioFinalized(id)
        )
        let queued = VoiceNoteLifecycleReducer.transition(
            recording,
            event: .transcriptionQueued(id)
        )

        XCTAssertFalse(finalized.accepted)
        XCTAssertFalse(queued.accepted)
        XCTAssertEqual(finalized.state, recording)
        XCTAssertEqual(queued.state, recording)
    }

    func testNewRecordingCanReplaceARecoverableFailedSession() {
        let failedID = UUID()
        let newID = UUID()
        var state = VoiceNoteLifecycleReducer.reduce(.init(), event: .retryRequested(failedID))
        state = VoiceNoteLifecycleReducer.reduce(state, event: .transcriptionStarted(failedID))
        state = VoiceNoteLifecycleReducer.reduce(state, event: .transcriptionFailed(failedID))

        let transition = VoiceNoteLifecycleReducer.transition(
            state,
            event: .recordingStarted(newID)
        )

        XCTAssertTrue(transition.accepted)
        XCTAssertEqual(transition.state.phase, .recordingShort(newID))
    }

    func testCheckpointDisabledPathCanMoveFromStoppingDirectlyToTranscribing() {
        let id = UUID()
        var state = VoiceNoteLifecycleReducer.reduce(.init(), event: .recordingStarted(id))
        state = VoiceNoteLifecycleReducer.reduce(state, event: .stopRequested(id))

        let transition = VoiceNoteLifecycleReducer.transition(
            state,
            event: .transcriptionStarted(id)
        )

        XCTAssertTrue(transition.accepted)
        XCTAssertEqual(transition.state.phase, .transcribing(id))
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

    func testLifecycleTransitionGraphIsExplicit() {
        let id = UUID()
        let states: [(name: String, state: VoiceNoteLifecycleState)] = [
            ("idle", .init()),
            ("recordingShort", .init(phase: .recordingShort(id))),
            ("recordingLongProtected", .init(phase: .recordingLongProtected(id))),
            ("stopping", .init(phase: .stopping(id))),
            ("audioSaved", .init(phase: .audioSaved(id))),
            ("transcriptionQueued", .init(phase: .transcriptionQueued(id))),
            ("transcribing", .init(phase: .transcribing(id))),
            ("failedRetryable", .init(phase: .failedRetryable(id))),
            ("cancelling", .init(phase: .cancelling(id))),
        ]
        let events: [(name: String, event: VoiceNoteLifecycleEvent)] = [
            ("recordingStarted", .recordingStarted(id)),
            ("longFormActivated", .longFormActivated(id)),
            ("stopRequested", .stopRequested(id)),
            ("audioFinalized", .audioFinalized(id)),
            ("transcriptionQueued", .transcriptionQueued(id)),
            ("transcriptionStarted", .transcriptionStarted(id)),
            ("transcriptionFailed", .transcriptionFailed(id)),
            ("retryRequested", .retryRequested(id)),
            ("cancelRequested", .cancelRequested(id)),
            ("finished", .finished(id)),
        ]
        let acceptedPairs: Set<String> = [
            "idle.recordingStarted",
            "idle.retryRequested",
            "recordingShort.recordingStarted",
            "recordingShort.longFormActivated",
            "recordingShort.stopRequested",
            "recordingShort.cancelRequested",
            "recordingShort.finished",
            "recordingLongProtected.stopRequested",
            "recordingLongProtected.cancelRequested",
            "recordingLongProtected.finished",
            "stopping.audioFinalized",
            "stopping.transcriptionStarted",
            "stopping.transcriptionFailed",
            "stopping.cancelRequested",
            "stopping.finished",
            "audioSaved.transcriptionQueued",
            "audioSaved.transcriptionStarted",
            "audioSaved.transcriptionFailed",
            "audioSaved.finished",
            "transcriptionQueued.transcriptionStarted",
            "transcriptionQueued.transcriptionFailed",
            "transcriptionQueued.finished",
            "transcribing.transcriptionFailed",
            "transcribing.finished",
            "failedRetryable.recordingStarted",
            "failedRetryable.retryRequested",
            "failedRetryable.finished",
            "cancelling.finished",
        ]

        for state in states {
            for event in events {
                let pair = "\(state.name).\(event.name)"
                let transition = VoiceNoteLifecycleReducer.transition(
                    state.state,
                    event: event.event
                )
                XCTAssertEqual(
                    transition.accepted,
                    acceptedPairs.contains(pair),
                    "Unexpected transition contract for \(pair)"
                )
                if !transition.accepted {
                    XCTAssertEqual(transition.state, state.state)
                }
            }
        }
    }

    func testFailedRetryRejectsAnotherSessionsRequest() {
        let activeID = UUID()
        let staleID = UUID()
        let state = VoiceNoteLifecycleState(phase: .failedRetryable(activeID))

        let transition = VoiceNoteLifecycleReducer.transition(
            state,
            event: .retryRequested(staleID)
        )

        XCTAssertFalse(transition.accepted)
        XCTAssertEqual(transition.state, state)
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

    func testThirtySecondThresholdCheckpointsBeforeLongFormActivation() {
        var schedule = VoiceNoteRecordingSchedule(thresholdSeconds: 30)

        XCTAssertEqual(schedule.nextDeadlineSeconds, 30)
        XCTAssertEqual(
            schedule.consumeNextDeadline(),
            [.checkpoint, .activateLongForm]
        )
        XCTAssertEqual(schedule.nextDeadlineSeconds, 60)
    }

    func testNonCheckpointThresholdActivatesAfterEarlierCheckpoint() {
        var schedule = VoiceNoteRecordingSchedule(thresholdSeconds: 45)

        XCTAssertEqual(schedule.consumeNextDeadline(), [.checkpoint])
        XCTAssertEqual(schedule.nextDeadlineSeconds, 45)
        XCTAssertEqual(schedule.consumeNextDeadline(), [.activateLongForm])
        XCTAssertEqual(schedule.nextDeadlineSeconds, 60)
    }

    func testSixtySecondThresholdKeepsCheckpointAndActivationSerialized() {
        var schedule = VoiceNoteRecordingSchedule(thresholdSeconds: 60)

        XCTAssertEqual(schedule.consumeNextDeadline(), [.checkpoint])
        XCTAssertEqual(schedule.nextDeadlineSeconds, 60)
        XCTAssertEqual(
            schedule.consumeNextDeadline(),
            [.checkpoint, .activateLongForm]
        )
        XCTAssertEqual(schedule.nextDeadlineSeconds, 90)
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

    func testFailureDispositionKeepsOnlyLongNotesRetryable() {
        let short = Muesli.RecordingSession(kind: .quickDictation, isLongForm: false)
        let long = Muesli.RecordingSession(kind: .quickDictation, isLongForm: true)

        XCTAssertEqual(VoiceNoteFailureLifecycleDisposition.resolve(for: short), .finished)
        XCTAssertEqual(VoiceNoteFailureLifecycleDisposition.resolve(for: long), .retryable)
    }

    func testRecordingTerminationCausePreservesSpecificFailureReason() {
        XCTAssertEqual(
            VoiceNoteRecordingTerminationCause.interrupted.failureReason,
            .interrupted
        )
        XCTAssertEqual(
            VoiceNoteRecordingTerminationCause.checkpointFailure.failureReason,
            .checkpointFailure
        )
    }

    func testFailureSessionPolicyProtectsOnlyRecoverableLongFormAudio() {
        let shortSession = Muesli.RecordingSession(
            kind: .keyboardDictation,
            phase: .transcribing,
            audioFileName: "short.wav"
        )
        let failedShortSession = VoiceNoteFailureSessionPolicy.prepare(
            shortSession,
            reason: .timeout,
            message: "Timed out",
            hasRecoverableAudio: true
        )

        XCTAssertEqual(failedShortSession.phase, .failed)
        XCTAssertEqual(failedShortSession.lastTranscriptionFailureReason, .timeout)
        XCTAssertFalse(failedShortSession.protectedAudioUntilTranscriptCompletes)

        let longSession = Muesli.RecordingSession(
            kind: .keyboardDictation,
            phase: .transcribing,
            audioFileName: "long.wav",
            isLongForm: true
        )
        let recoverableLongSession = VoiceNoteFailureSessionPolicy.prepare(
            longSession,
            reason: .timeout,
            message: "Timed out",
            hasRecoverableAudio: true
        )
        let unavailableLongSession = VoiceNoteFailureSessionPolicy.prepare(
            longSession,
            reason: .timeout,
            message: "Timed out",
            hasRecoverableAudio: false
        )

        XCTAssertTrue(recoverableLongSession.protectedAudioUntilTranscriptCompletes)
        XCTAssertFalse(unavailableLongSession.protectedAudioUntilTranscriptCompletes)
    }

    func testFailureTelemetryPolicyPreservesTimeoutStageNames() {
        XCTAssertEqual(
            VoiceNoteFailureTelemetryPolicy.stage(
                for: .timeout,
                standard: "transcription",
                timeout: "transcription_timeout"
            ),
            "transcription_timeout"
        )
        XCTAssertEqual(
            VoiceNoteFailureTelemetryPolicy.stage(
                for: .engineFailure,
                standard: "transcription",
                timeout: "transcription_timeout"
            ),
            "transcription"
        )
    }
}
