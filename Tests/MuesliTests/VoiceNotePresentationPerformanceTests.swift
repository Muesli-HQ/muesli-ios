import XCTest
import Observation
@testable import Muesli

final class VoiceNotePresentationPerformanceTests: XCTestCase {
    func testElapsedClockKeepsExactLifecycleTimeAndPublishesWholeSeconds() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)

        let beforeThreshold = VoiceNoteElapsedClock.exactElapsed(
            startedAt: start,
            now: start.addingTimeInterval(29.999)
        )
        XCTAssertEqual(VoiceNoteElapsedClock.publishedSeconds(elapsed: beforeThreshold), 29)

        let atThreshold = VoiceNoteElapsedClock.exactElapsed(
            startedAt: start,
            now: start.addingTimeInterval(30)
        )
        XCTAssertEqual(atThreshold, 30, accuracy: 0.000_1)
        XCTAssertEqual(VoiceNoteElapsedClock.publishedSeconds(elapsed: atThreshold), 30)

        let afterThreshold = VoiceNoteElapsedClock.exactElapsed(
            startedAt: start,
            now: start.addingTimeInterval(30.1)
        )
        XCTAssertGreaterThan(afterThreshold, 30)
        XCTAssertEqual(VoiceNoteElapsedClock.publishedSeconds(elapsed: afterThreshold), 30)
    }

    func testElapsedClockClampsInvalidAndNegativeValues() {
        XCTAssertEqual(
            VoiceNoteElapsedClock.exactElapsed(startedAt: nil, fallback: -.infinity),
            0
        )
        XCTAssertEqual(VoiceNoteElapsedClock.publishedSeconds(elapsed: -.infinity), 0)
        XCTAssertEqual(VoiceNoteElapsedClock.publishedSeconds(elapsed: -5), 0)
    }

    func testHistoryPresentationPrecomputesStableFilteredTimelines() {
        let requestID = UUID()
        let sessionID = UUID()
        let result = Muesli.DictationResult(
            requestID: requestID,
            sessionID: sessionID,
            text: "A local note",
            createdAt: Date(timeIntervalSinceReferenceDate: 200),
            engineIdentifier: "parakeet",
            source: "ios"
        )
        let session = Muesli.RecordingSession(
            id: sessionID,
            requestID: requestID,
            kind: .quickDictation,
            createdAt: Date(timeIntervalSinceReferenceDate: 200),
            phase: .completed,
            source: "ios"
        )
        let presentation = VoiceNoteHistoryPresentation(
            revision: 1,
            history: [result],
            sessions: [session]
        )

        XCTAssertEqual(presentation.timeline(for: .all).count, 1)
        XCTAssertEqual(presentation.timeline(for: .thisIPhone).count, 1)
        XCTAssertTrue(presentation.timeline(for: .fromMac).isEmpty)
        XCTAssertTrue(presentation.matches(history: [result], sessions: [session]))
        XCTAssertEqual(
            presentation.updated(history: [result], sessions: [session]).revision,
            presentation.revision
        )
    }

    func testLargeHistoryRemoteInsertionPreservesEveryExistingRowIdentity() {
        let existing = (0..<2_600).map { index in
            Muesli.DictationResult(
                requestID: UUID(),
                text: "Local note \(index)",
                createdAt: Date(timeIntervalSinceReferenceDate: TimeInterval(index)),
                engineIdentifier: "parakeet",
                source: "ios"
            )
        }.reversed()
        let before = VoiceNoteHistoryPresentation(
            revision: 1,
            history: Array(existing),
            sessions: []
        )
        let remote = Muesli.DictationResult(
            requestID: UUID(),
            text: "New Mac note",
            createdAt: Date(timeIntervalSinceReferenceDate: 3_000),
            engineIdentifier: "icloud",
            source: "macos"
        )
        let afterHistory = [remote] + Array(existing)
        let after = VoiceNoteHistoryPresentation(
            revision: 2,
            history: afterHistory,
            sessions: []
        )

        let beforeIDs = before.timeline(for: .all).map(\.id)
        let afterIDs = after.timeline(for: .all).map(\.id)
        XCTAssertEqual(afterIDs.count, 2_601)
        XCTAssertEqual(Set(afterIDs).count, 2_601)
        XCTAssertEqual(afterIDs.first, "result-\(remote.id.uuidString)")
        XCTAssertEqual(Array(afterIDs.dropFirst()), beforeIDs)
        XCTAssertEqual(after.timeline(for: .fromMac).map(\.id), [afterIDs[0]])
        XCTAssertFalse(before.matches(history: afterHistory, sessions: []))
        XCTAssertTrue(after.matches(history: afterHistory, sessions: []))
        XCTAssertEqual(
            before.updated(history: afterHistory, sessions: []).revision,
            before.revision + 1
        )
    }

    func testTimelineBuilderMergesRecoverableNotesByCreationDate() {
        let completed = Muesli.DictationResult(
            requestID: UUID(),
            text: "Completed",
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            engineIdentifier: "parakeet",
            source: "ios"
        )
        let recoverable = Muesli.RecordingSession(
            kind: .quickDictation,
            createdAt: Date(timeIntervalSinceReferenceDate: 200),
            phase: .failed,
            source: "ios",
            isLongForm: true
        )

        let items = VoiceNoteTimelineBuilder.build(
            from: VoiceNoteTimelineInput(
                history: [completed],
                sessions: [recoverable],
                sourceFilter: .all
            )
        )

        XCTAssertEqual(items.count, 2)
        guard case .recoverable(let first) = items.first else {
            return XCTFail("The newest recoverable session should lead the timeline")
        }
        XCTAssertEqual(first.id, recoverable.id)
    }

    func testTranscriptPreviewIsBoundedAndPreservesTheNewestText() {
        let ending = "this is the newest live transcript phrase"
        let transcript = String(repeating: "older words ", count: 100) + ending
        let preview = VoiceNoteTranscriptPreview.text(from: transcript)

        XCTAssertLessThanOrEqual(preview.count, VoiceNoteTranscriptPreview.maximumCharacters + 1)
        XCTAssertTrue(preview.hasSuffix(ending))
        XCTAssertTrue(preview.hasPrefix("…"))
        XCTAssertEqual(VoiceNoteTranscriptPreview.text(from: "   \n"), "")
    }

    @MainActor
    func testLiveStateMutationsDoNotInvalidateItsOwner() {
        let owner = VoiceNoteObservationOwner()
        let ownerInvalidation = expectation(description: "Parent observation remains stable")
        ownerInvalidation.isInverted = true

        withObservationTracking {
            _ = owner.historyRevision
            _ = owner.liveState
        } onChange: {
            ownerInvalidation.fulfill()
        }

        owner.liveState.setInputLevel(0.72)
        owner.liveState.setElapsedTime(18.4)
        owner.liveState.setTranscript("A partial transcript")

        wait(for: [ownerInvalidation], timeout: 0.01)
        XCTAssertEqual(owner.liveState.inputLevel, 0.72, accuracy: 0.000_1)
        XCTAssertEqual(owner.liveState.elapsedSeconds, 18)
        XCTAssertEqual(owner.liveState.transcript, "A partial transcript")
    }
}

@MainActor
@Observable
private final class VoiceNoteObservationOwner {
    let liveState = VoiceNoteLiveState()
    var historyRevision = 0
}
