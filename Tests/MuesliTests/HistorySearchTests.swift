import XCTest
@testable import Muesli

final class HistorySearchTests: XCTestCase {
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
