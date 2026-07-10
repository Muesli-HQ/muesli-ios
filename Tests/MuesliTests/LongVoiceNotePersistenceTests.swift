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
            scratchpadText: "Remember the second point"
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
        XCTAssertEqual(recovered.voiceNoteDurabilityEvidence, .durableCheckpoint)
    }

    func testLegacySessionDecodesLongVoiceNoteDefaults() throws {
        let session = RecordingSession(kind: .quickDictation, phase: .completed)
        let data = try JSONEncoder().encode(session)
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in [
            "isLongForm", "longFormActivatedAt", "longFormThresholdSeconds",
            "hasDurableAudioCheckpoint", "protectedAudioUntilTranscriptCompletes", "transcriptionRetryCount",
            "lastTranscriptionAttemptAt", "lastTranscriptionFailureReason", "scratchpadText"
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
}
