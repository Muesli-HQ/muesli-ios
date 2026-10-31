import Foundation

// Adapted from macOS InsightsRange and InsightsSnapshot, using the iOS history model.
enum InsightsRange: String, CaseIterable, Identifiable {
    case thirtyDays = "30 days", ninetyDays = "90 days", twelveMonths = "12 months", allTime = "All time"
    var id: Self { self }
    func start(now: Date, calendar: Calendar) -> Date? {
        let today = calendar.startOfDay(for: now)
        switch self {
        case .thirtyDays: return calendar.date(byAdding: .day, value: -29, to: today)
        case .ninetyDays: return calendar.date(byAdding: .day, value: -89, to: today)
        case .twelveMonths: return calendar.date(byAdding: .year, value: -1, to: today)
        case .allTime: return nil
        }
    }
}

struct InsightsSnapshot {
    struct Day: Identifiable {
        var id: Date { date }
        let date: Date
        var words = 0
        var meetings = 0
    }
    let words: Int
    let notes: Int
    let meetings: Int
    let averageWPM: Double?
    let timedNotes: Int
    let activeDays: Int
    let currentStreak: Int
    let longestStreak: Int
    let daily: [Day]
    let iphoneWords: Int
    let macWords: Int

    init(history: [DictationResult], sessions: [RecordingSession], range: InsightsRange,
         now: Date = .now, calendar: Calendar = .current) {
        let start = range.start(now: now, calendar: calendar) ?? .distantPast
        // Use stable record IDs so a refreshed/synced record is never counted twice.
        let uniqueHistory = Dictionary(history.map { ($0.id, $0) }, uniquingKeysWith: { _, rhs in rhs }).values
        let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { _, rhs in rhs })
        let results = uniqueHistory.filter { result in
            guard result.createdAt <= now, !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            if let id = result.sessionID, let session = byID[id] {
                return session.kind != .meeting && session.phase != .cancelled && session.phase != .failed
            }
            return true
        }
        let completedMeetings = byID.values.filter { $0.kind == .meeting && $0.phase == .completed && $0.createdAt <= now }
        var days: [Date: Day] = [:]
        var words = 0, notes = 0, timedWords = 0, timedNotes = 0, iphoneWords = 0, macWords = 0
        var seconds = 0.0
        var activity = Set<Date>()
        for result in results {
            let day = calendar.startOfDay(for: result.createdAt)
            activity.insert(day)
            guard result.createdAt >= start else { continue }
            let count = result.text.split(whereSeparator: { $0.isWhitespace }).count
            words += count
            notes += 1
            if result.syncOrigin == .fromMac { macWords += count } else { iphoneWords += count }
            days[day, default: Day(date: day)].words += count
            if let id = result.sessionID, let session = byID[id], session.phase == .completed,
               let started = session.startedAt, let ended = session.endedAt {
                let duration = ended.timeIntervalSince(started)
                if duration.isFinite && duration > 0 {
                    seconds += duration
                    timedWords += count
                    timedNotes += 1
                }
            }
        }
        for meeting in completedMeetings {
            let day = calendar.startOfDay(for: meeting.createdAt)
            activity.insert(day)
            if meeting.createdAt >= start { days[day, default: Day(date: day)].meetings += 1 }
        }
        let today = calendar.startOfDay(for: now)
        var cursor = activity.contains(today) ? today : calendar.date(byAdding: .day, value: -1, to: today)!
        var current = 0
        while activity.contains(cursor) {
            current += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        var longest = 0, run = 0
        var previous: Date?
        for day in activity.sorted() {
            run = previous.flatMap { calendar.dateComponents([.day], from: $0, to: day).day } == 1 ? run + 1 : 1
            longest = max(longest, run)
            previous = day
        }
        self.words = words
        self.notes = notes
        self.meetings = days.values.reduce(0) { $0 + $1.meetings }
        self.averageWPM = seconds > 0 ? Double(timedWords) * 60 / seconds : nil
        self.timedNotes = timedNotes
        self.activeDays = days.count
        self.currentStreak = current
        self.longestStreak = longest
        self.daily = days.values.sorted { $0.date < $1.date }
        self.iphoneWords = iphoneWords
        self.macWords = macWords
    }
}
