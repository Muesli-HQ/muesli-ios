import XCTest
@testable import Muesli

final class HistorySearchTests: XCTestCase {
    func testSyncedDeletionHidesRetainedTranscriptButKeepsUnfinishedNoteSearchable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = Muesli.SharedStore(containerURL: directory)
        let requestID = UUID()
        let session = Muesli.RecordingSession(requestID: requestID, kind: .quickDictation, phase: .completed)
        let draft = Muesli.RecordingSession(kind: .quickDictation, scratchpadText: "dentist tomorrow")
        try store.saveSession(session)
        try store.saveSession(draft)
        try store.saveResult(.init(requestID: requestID, sessionID: session.id, text: "older result", engineIdentifier: "local"))
        try store.saveTranscript(.init(sessionID: session.id, text: "dentist appointment", engineIdentifier: "local"))

        func search() async throws -> [HistorySearchMatch] {
            let snapshot = try store.historySnapshot()
            let input = HistorySearchInput(query: "dentist", history: snapshot.history, sessions: snapshot.sessions,
                                           transcripts: Dictionary(uniqueKeysWithValues: snapshot.transcripts.map { ($0.sessionID, $0) }),
                                           deletedResultSessionIDs: snapshot.deletedResultSessionIDs)
            return try await input.matches()
        }

        let before = try await search()
        XCTAssertEqual(before.count, 2)
        XCTAssertTrue(before.contains { $0.excerpt == "dentist appointment" })
        var deletion = try XCTUnwrap(store.textRecordsNeedingSync().first { $0.kind == .dictation })
        deletion.updatedAt = Date().addingTimeInterval(60)
        deletion.isDeleted = true
        XCTAssertTrue(try store.upsertSyncedTextRecord(deletion))
        XCTAssertNotNil(try store.transcript(for: session.id))
        let after = try await search()
        XCTAssertEqual(after.map(\.id), [.session(draft.id)])
    }

    func testOneQueryFindsNotesLegacyDictationsAndMeetingContentOnceEach() async throws {
        let note = Muesli.RecordingSession(kind: .quickDictation, phase: .completed, scratchpadText: "café draft")
        let result = Muesli.DictationResult(requestID: UUID(), sessionID: note.id, text: "Final words", engineIdentifier: "local")
        let legacy = Muesli.DictationResult(requestID: UUID(), text: "Mac CAFÉ", engineIdentifier: "icloud")
        let meeting = Muesli.RecordingSession(kind: .meeting, title: "Planning", phase: .completed)
        let transcript = Muesli.Transcript(sessionID: meeting.id, text: "Discussion",
                                         engineIdentifier: "local", summaryText: String(repeating: "background ", count: 80) + "Café next month")
        let input = HistorySearchInput(query: " cafe ", history: [result, legacy], sessions: [note, meeting],
                                       transcripts: [meeting.id: transcript])
        let hits = try await input.matches()
        XCTAssertEqual(hits.count, 3)
        XCTAssertEqual(hits.first(where: { $0.id == .result(result.id) })?.kind, "Voice Note")
        XCTAssertEqual(hits.first(where: { $0.id == .result(legacy.id) })?.kind, "Dictation")
        let hit = try XCTUnwrap(hits.first(where: { $0.id == .session(meeting.id) }))
        XCTAssertTrue(hit.excerpt.contains("Café next month"))
        XCTAssertTrue(hit.excerpt.hasPrefix("…"))
    }
}
