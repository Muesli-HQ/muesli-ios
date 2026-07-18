import XCTest
@testable import Muesli

final class LongVoiceNotePersistenceTests: XCTestCase {
    func testLongVoiceNoteMetadataAndScratchpadPersist() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-long-note-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SharedStore(containerURL: directory)
        let activatedAt = Date(timeIntervalSince1970: 200)
        let attemptedAt = Date(timeIntervalSince1970: 300)
        let recoveryValidatedAt = Date(timeIntervalSince1970: 400)
        let interruptedAt = Date(timeIntervalSince1970: 500)
        let draftUpdatedAt = Date(timeIntervalSince1970: 510)
        let session = RecordingSession(
            kind: .quickDictation,
            phase: .failed,
            audioFileName: "protected.wav",
            isLongForm: true,
            longFormActivatedAt: activatedAt,
            longFormThresholdSeconds: 60,
            hasDurableAudioCheckpoint: true,
            protectedAudioUntilTranscriptCompletes: true,
            transcriptionRetryCount: 2,
            lastTranscriptionAttemptAt: attemptedAt,
            lastTranscriptionFailureReason: .timeout,
            scratchpadText: "Remember the second point",
            longFormRecoveryValidatedAt: recoveryValidatedAt,
            captureInterruptionReason: .appSuspended,
            captureInterruptedAt: interruptedAt,
            draftTranscriptText: "A durable partial transcript",
            draftTranscriptUpdatedAt: draftUpdatedAt
        )

        try store.saveSession(session)
        let recovered = try XCTUnwrap(try store.recordingSession(id: session.id))

        XCTAssertTrue(recovered.isLongForm)
        XCTAssertEqual(recovered.longFormActivatedAt, activatedAt)
        XCTAssertEqual(recovered.longFormThresholdSeconds, 60)
        XCTAssertTrue(recovered.hasDurableAudioCheckpoint)
        XCTAssertTrue(recovered.protectedAudioUntilTranscriptCompletes)
        XCTAssertEqual(recovered.transcriptionRetryCount, 2)
        XCTAssertEqual(recovered.lastTranscriptionAttemptAt, attemptedAt)
        XCTAssertEqual(recovered.lastTranscriptionFailureReason, .timeout)
        XCTAssertEqual(recovered.scratchpadText, "Remember the second point")
        XCTAssertEqual(recovered.longFormRecoveryValidatedAt, recoveryValidatedAt)
        XCTAssertEqual(recovered.captureInterruptionReason, .appSuspended)
        XCTAssertEqual(recovered.captureInterruptedAt, interruptedAt)
        XCTAssertEqual(recovered.draftTranscriptText, "A durable partial transcript")
        XCTAssertEqual(recovered.draftTranscriptUpdatedAt, draftUpdatedAt)
        XCTAssertEqual(recovered.voiceNoteDurabilityEvidence, .durableCheckpoint)
    }

    func testLegacySessionDecodesLongVoiceNoteDefaults() throws {
        let session = RecordingSession(kind: .quickDictation, phase: .completed)
        let data = try JSONEncoder().encode(session)
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in [
            "isLongForm", "longFormActivatedAt", "longFormThresholdSeconds",
            "hasDurableAudioCheckpoint", "protectedAudioUntilTranscriptCompletes", "transcriptionRetryCount",
            "lastTranscriptionAttemptAt", "lastTranscriptionFailureReason", "scratchpadText",
            "longFormRecoveryValidatedAt", "captureInterruptionReason", "captureInterruptedAt",
            "draftTranscriptText", "draftTranscriptUpdatedAt"
        ] {
            payload.removeValue(forKey: key)
        }

        let decoded = try JSONDecoder().decode(
            RecordingSession.self,
            from: JSONSerialization.data(withJSONObject: payload)
        )

        XCTAssertFalse(decoded.isLongForm)
        XCTAssertNil(decoded.longFormActivatedAt)
        XCTAssertNil(decoded.longFormThresholdSeconds)
        XCTAssertFalse(decoded.hasDurableAudioCheckpoint)
        XCTAssertFalse(decoded.protectedAudioUntilTranscriptCompletes)
        XCTAssertEqual(decoded.transcriptionRetryCount, 0)
        XCTAssertNil(decoded.lastTranscriptionFailureReason)
        XCTAssertNil(decoded.scratchpadText)
        XCTAssertNil(decoded.longFormRecoveryValidatedAt)
        XCTAssertNil(decoded.captureInterruptionReason)
        XCTAssertNil(decoded.captureInterruptedAt)
        XCTAssertNil(decoded.draftTranscriptText)
        XCTAssertNil(decoded.draftTranscriptUpdatedAt)
        XCTAssertEqual(decoded.voiceNoteDurabilityEvidence, .unavailable)
    }

    func testDurabilityEvidenceDoesNotTreatAFileNameAsACheckpoint() {
        let referencedOnly = RecordingSession(
            kind: .quickDictation,
            phase: .failed,
            audioFileName: "unverified.wav"
        )

        XCTAssertEqual(referencedOnly.voiceNoteDurabilityEvidence, .audioReferenceOnly)
    }

    func testTranscriptionRetryRequiresVerifiedProtectedAudio() {
        let retryable = RecordingSession(
            kind: .quickDictation,
            phase: .failed,
            audioFileName: "voice-note.wav",
            protectedAudioUntilTranscriptCompletes: true
        )
        XCTAssertTrue(retryable.canRetryVoiceNoteTranscription)

        var unverified = retryable
        unverified.protectedAudioUntilTranscriptCompletes = false
        XCTAssertFalse(unverified.canRetryVoiceNoteTranscription)

        var missingAudio = retryable
        missingAudio.audioFileName = nil
        XCTAssertFalse(missingAudio.canRetryVoiceNoteTranscription)

        var completed = retryable
        completed.phase = .completed
        XCTAssertFalse(completed.canRetryVoiceNoteTranscription)
    }

    func testInterruptedVoiceNoteStillOwnsActiveWork() {
        let session = RecordingSession(
            kind: .keyboardDictation,
            phase: .interrupted,
            source: "keyboard",
            captureInterruptionReason: .appSuspended
        )

        XCTAssertTrue(session.hasActiveVoiceNoteWork)
        XCTAssertTrue(session.isKeyboardOwnedVoiceNote)
    }

    func testVoiceNoteWorkOwnershipDistinguishesAppAndKeyboardSessions() {
        let appSession = RecordingSession(
            kind: .quickDictation,
            phase: .recording,
            source: "app"
        )
        XCTAssertTrue(appSession.hasActiveVoiceNoteWork)
        XCTAssertFalse(appSession.isKeyboardOwnedVoiceNote)

        let keyboardSession = RecordingSession(
            kind: .keyboardDictation,
            phase: .transcribing,
            source: "keyboard"
        )
        XCTAssertTrue(keyboardSession.hasActiveVoiceNoteWork)
        XCTAssertTrue(keyboardSession.isKeyboardOwnedVoiceNote)

        let completedAppSession = RecordingSession(
            kind: .quickDictation,
            phase: .completed,
            source: "app"
        )
        XCTAssertFalse(completedAppSession.hasActiveVoiceNoteWork)
    }

    func testUserAuthoredNotesRecognizeManualNotesAndScratchpadText() {
        var session = RecordingSession(kind: .quickDictation, phase: .completed)
        XCTAssertFalse(session.hasUserAuthoredNotes)

        session.manualNotes = "  Follow up with the team.  "
        XCTAssertTrue(session.hasUserAuthoredNotes)

        session.manualNotes = "  \n "
        session.scratchpadText = "Capture the launch idea."
        XCTAssertTrue(session.hasUserAuthoredNotes)

        session.scratchpadText = "\n  "
        XCTAssertFalse(session.hasUserAuthoredNotes)
    }
}
