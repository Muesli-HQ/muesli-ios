import Foundation

struct ModelDownloadProgressSnapshot: Equatable, Sendable {
    let completedBytes: Int64
    let totalBytes: Int64
    let bytesPerSecond: Double
    let estimatedSecondsRemaining: Double?
    let updatedAt: Date
}

/// Same whole-model accounting as macOS ModelDownloadCoordinator. Resumed bytes
/// do not count toward transfer speed; retries and source changes reset the baseline.
struct ModelDownloadRateTracker {
    private var transactionID: UUID?
    private var startedAt: Date?
    private var initialBytes: Int64 = 0
    private var lastBytes: Int64 = 0
    private var lastUpdate: Date?

    mutating func snapshot(id: UUID, bytes: Int64, total: Int64, now: Date = .now) -> ModelDownloadProgressSnapshot {
        let completed = min(max(0, bytes), max(0, total))
        if transactionID != id || completed < lastBytes || (lastUpdate.map { now.timeIntervalSince($0) > 10 } ?? false) {
            transactionID = id
            startedAt = now
            initialBytes = completed
        }
        let elapsed = now.timeIntervalSince(startedAt ?? now)
        let speed = elapsed >= 1 ? Double(max(0, completed - initialBytes)) / elapsed : 0
        lastBytes = completed
        lastUpdate = now
        return .init(completedBytes: completed, totalBytes: total, bytesPerSecond: speed,
            estimatedSecondsRemaining: speed > 0 ? Double(max(0, total - completed)) / speed : nil,
            updatedAt: now)
    }
}

/// Ported from macOS ModelDownloadDisplayFormatting. ETA is transfer-only.
enum ModelDownloadDisplayFormatting {
    static func bytes(_ bytes: Int64) -> String {
        let value = Double(max(0, bytes))
        if value >= 1_000_000_000 { return String(format: "%.1f GB", value / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1f MB", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1f KB", value / 1_000) }
        return "\(max(0, bytes)) B"
    }

    static func eta(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds >= 0, seconds.rounded() <= Double(365 * 24 * 60 * 60) else { return nil }
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(String(format: "%02d", total % 60))s" }
        return "\(total / 3600)h \(String(format: "%02d", total / 60 % 60))m"
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return "" }
        if bytesPerSecond >= 1_000_000_000 { return String(format: "%.1f GB/s", bytesPerSecond / 1_000_000_000) }
        if bytesPerSecond < 1_000_000 { return String(format: "%.0f KB/s", bytesPerSecond / 1_000) }
        return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
    }
}
