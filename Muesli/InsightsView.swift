import SwiftUI
import Charts

struct InsightsView: View {
    let history: [DictationResult]
    let sessions: [RecordingSession]
    @State var source: DictationSourceFilter = .all
    @State private var range: InsightsRange = .ninetyDays
    @State private var metric = "Words"
    @Environment(\.dismiss) private var dismiss

    private var snapshot: InsightsSnapshot {
        InsightsSnapshot(history: history.filter { source.includes($0.syncOrigin) },
                         sessions: sessions.filter { source.includes($0.syncOrigin) }, range: range)
    }

    var body: some View {
        let data = snapshot
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack {
                        Text("Your time with Muesli").font(MuesliTheme.title3())
                        Spacer()
                        Picker("Time range", selection: $range) {
                            ForEach(InsightsRange.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .accessibilityIdentifier("insights.range")
                    }
                    Picker("Source", selection: $source) {
                        ForEach(DictationSourceFilter.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(data.words.formatted())
                            .font(MuesliTheme.font(size: 44, weight: .bold, relativeTo: .largeTitle))
                            .monospacedDigit()
                        Text("Words dictated · \(range.rawValue.lowercased())")
                            .foregroundStyle(MuesliTheme.textSecondary)
                    }
                    .accessibilityElement(children: .combine)
                    if data.notes == 0 && data.meetings == 0 {
                        ContentUnavailableView("No activity in this range", systemImage: "chart.bar",
                                               description: Text("Try another range or record your first note."))
                    } else {
                        activity(data)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)], spacing: 12) {
                        stat("Voice notes", value: data.notes.formatted())
                        stat("Meetings", value: data.meetings.formatted())
                        stat("Active days", value: data.activeDays.formatted())
                        stat("Speaking pace", value: data.averageWPM.map { "\(Int($0.rounded())) WPM" } ?? "—")
                    }
                    if data.timedNotes > 0 {
                        Text("Pace is based on \(data.timedNotes.formatted()) \(data.timedNotes == 1 ? "note" : "notes") with recording duration.")
                            .font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textSecondary)
                    } else {
                        Text("Speaking pace appears when recording duration is available.")
                            .font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textSecondary)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Keep the momentum").font(MuesliTheme.title3())
                        HStack(alignment: .top, spacing: 12) {
                            stat("Current streak", value: "\(data.currentStreak) \(data.currentStreak == 1 ? "day" : "days")")
                            stat("Longest streak", value: "\(data.longestStreak) \(data.longestStreak == 1 ? "day" : "days")")
                        }
                        Text("Streaks use all-time activity from the selected devices. A note or completed meeting keeps your streak going.")
                            .font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textSecondary)
                    }
                    if source == .all && data.words > 0 {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Where you dictate").font(MuesliTheme.title3())
                            LabeledContent("This iPhone", value: data.iphoneWords.formatted() + " words")
                            LabeledContent("From Mac", value: data.macWords.formatted() + " words")
                        }
                    }
                    Text("Calculated on this iPhone from available history, including synced records.")
                        .font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textSecondary)
                }
                .padding(20)
            }
            .font(MuesliTheme.body())
            .background(MuesliTheme.backgroundBase)
            .navigationTitle("Insights")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    ShareLink(item: "My Muesli activity (\(range.rawValue), \(source.title)): \(data.words) words dictated, \(data.notes) voice notes, \(data.meetings) meetings, \(data.activeDays) active days.") {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share activity summary")
                }
            }
        }
    }

    private func stat(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value).font(MuesliTheme.title3()).monospacedDigit()
            Text(title).font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(MuesliTheme.backgroundRaised, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }

    private func activity(_ data: InsightsSnapshot) -> some View {
        let calendar = Calendar.current
        let monthly = range == .twelveMonths || range == .allTime
        let grouped = Dictionary(grouping: data.daily) {
            calendar.dateInterval(of: monthly ? .month : .day, for: $0.date)!.start
        }
        let buckets = grouped.keys.sorted().map { day in
            InsightsSnapshot.Day(date: day, words: grouped[day]!.reduce(0) { $0 + $1.words },
                                 meetings: grouped[day]!.reduce(0) { $0 + $1.meetings })
        }
        let now = Date.now
        let firstDay = range.start(now: now, calendar: calendar) ?? data.daily.first?.date ?? now
        let lowerBound = calendar.dateInterval(of: monthly ? .month : .day, for: firstDay)!.start
        let upperBound = calendar.dateInterval(of: monthly ? .month : .day, for: now)!.end
        return VStack(alignment: .leading, spacing: 12) {
            Text("Activity").font(MuesliTheme.title3())
            Picker("Activity metric", selection: $metric) {
                Text("Words").tag("Words")
                Text("Meetings").tag("Meetings")
            }.pickerStyle(.segmented)
            Chart(buckets) { day in
                BarMark(x: .value("Date", day.date, unit: monthly ? .month : .day),
                        y: .value(metric, metric == "Words" ? day.words : day.meetings))
                    .foregroundStyle(MuesliTheme.accent)
                    .cornerRadius(3)
                    .accessibilityLabel(day.date.formatted(.dateTime.month().day()))
                    .accessibilityValue("\(metric == "Words" ? day.words : day.meetings) \(metric.lowercased())")
            }
            .chartXScale(domain: lowerBound...upperBound)
            .frame(height: 180)
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
            Text(monthly ? "Monthly totals" : "Daily totals")
                .font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textSecondary)
        }
    }
}
