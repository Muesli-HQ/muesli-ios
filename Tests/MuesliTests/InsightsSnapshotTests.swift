import XCTest
import UIKit
@testable import Muesli

final class InsightsSnapshotTests: XCTestCase {
    @MainActor
    func testShareCardExportsPNGWithMacOSCardDimensions() throws {
        let snapshot = InsightsSnapshot(history: [result(at: now, text: "one two three four")],
                                        sessions: [], range: .thirtyDays, now: now, calendar: calendar)
        let image = try XCTUnwrap(InsightsShareRenderer.render(snapshot: snapshot, rangeLabel: "30 days · This iPhone"))
        let png = try XCTUnwrap(image.pngData())
        let decoded = try XCTUnwrap(UIImage(data: png))
        XCTAssertEqual(decoded.size.width, 1200)
        XCTAssertEqual(decoded.size.height, 630)
        XCTAssertEqual(Array(png.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "Muesli activity share card"
        attachment.lifetime = .keepAlways
        add(attachment)
        #if targetEnvironment(simulator)
        let preview = FileManager.default.temporaryDirectory.appendingPathComponent("muesli-share-card-preview.png")
        try png.write(to: preview)
        print("SHARE_CARD_PREVIEW: \(preview.path)")
        #endif
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    private var now: Date { Date(timeIntervalSince1970: 1_800_000_000) }
    private func result(at date: Date, session: Muesli.RecordingSession? = nil, text: String = "one two", source: String? = nil) -> Muesli.DictationResult {
        Muesli.DictationResult(requestID: UUID(), sessionID: session?.id, text: text, createdAt: date, engineIdentifier: "test", source: source)
    }

    func testWeightedPaceExcludesMissingAndInvalidDurationsAndDeduplicatesRecords() {
        let short = Muesli.RecordingSession(kind: .quickDictation, createdAt: now, startedAt: now.addingTimeInterval(-10), endedAt: now, phase: .completed)
        let long = Muesli.RecordingSession(kind: .quickDictation, createdAt: now, startedAt: now.addingTimeInterval(-50), endedAt: now, phase: .completed)
        let first = result(at: now, session: short)
        let data = InsightsSnapshot(history: [first, first, result(at: now, session: long, text: "one two three four"), result(at: now)], sessions: [short, long], range: .allTime, now: now, calendar: calendar)
        XCTAssertEqual(data.words, 8)
        XCTAssertEqual(data.notes, 3)
        XCTAssertEqual(data.timedNotes, 2)
        XCTAssertEqual(data.averageWPM, 6)
    }

    func testRangeBoundaryAndFutureRecords() {
        let start = InsightsRange.thirtyDays.start(now: now, calendar: calendar)!
        let data = InsightsSnapshot(history: [result(at: start), result(at: start.addingTimeInterval(-1)), result(at: now.addingTimeInterval(1))], sessions: [], range: .thirtyDays, now: now, calendar: calendar)
        XCTAssertEqual(data.notes, 1)
        XCTAssertEqual(data.words, 2)
        XCTAssertNil(data.averageWPM)
    }

    func testCompletedMeetingsCountButFailedAndInProgressDoNot() {
        let completed = Muesli.RecordingSession(kind: .meeting, createdAt: now, phase: .completed)
        let failed = Muesli.RecordingSession(kind: .meeting, createdAt: now, phase: .failed)
        let live = Muesli.RecordingSession(kind: .meeting, createdAt: now, phase: .recording)
        let data = InsightsSnapshot(history: [result(at: now, session: completed)], sessions: [completed, completed, failed, live], range: .allTime, now: now, calendar: calendar)
        XCTAssertEqual(data.meetings, 1)
        XCTAssertEqual(data.words, 0)
        XCTAssertEqual(data.activeDays, 1)
    }

    func testStreakUsesCalendarDaysAndYesterdayGraceAcrossRange() {
        let days = [1, 2, 3, 6].map { calendar.date(byAdding: .day, value: -$0, to: now)! }
        let data = InsightsSnapshot(history: days.map { result(at: $0) }, sessions: [], range: .thirtyDays, now: now, calendar: calendar)
        XCTAssertEqual(data.currentStreak, 3)
        XCTAssertEqual(data.longestStreak, 3)
        XCTAssertEqual(data.activeDays, 4)
    }

    func testInvalidDurationsAndOriginBreakdown() {
        let invalid = Muesli.RecordingSession(kind: .quickDictation, createdAt: now, startedAt: now,
                                       endedAt: now.addingTimeInterval(-1), phase: .completed)
        let data = InsightsSnapshot(history: [result(at: now, session: invalid), result(at: now, source: "mac")],
                                    sessions: [invalid], range: .allTime, now: now, calendar: calendar)
        XCTAssertNil(data.averageWPM)
        XCTAssertEqual(data.iphoneWords, 2)
        XCTAssertEqual(data.macWords, 2)
    }

    func testStreakCrossesDaylightSavingBoundary() {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let today = local.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 12))!
        let days = (0...2).map { local.date(byAdding: .day, value: -$0, to: today)! }
        let data = InsightsSnapshot(history: days.map { result(at: $0) }, sessions: [], range: .allTime,
                                    now: today, calendar: local)
        XCTAssertEqual(data.currentStreak, 3)
        XCTAssertEqual(data.longestStreak, 3)
    }

    func testEmptyHistoryHasNoInventedPaceOrActivity() {
        let data = InsightsSnapshot(history: [], sessions: [], range: .allTime, now: now, calendar: calendar)
        XCTAssertEqual(data.currentStreak, 0)
        XCTAssertEqual(data.longestStreak, 0)
        XCTAssertTrue(data.daily.isEmpty)
        XCTAssertNil(data.averageWPM)
    }
}
