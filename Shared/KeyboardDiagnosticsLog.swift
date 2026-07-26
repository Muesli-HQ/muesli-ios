import Foundation
import os

/// A durable, bounded record of keyboard dictation state transitions.
///
/// The keyboard extension had no logging of any kind, so a stranded session
/// left no trace: the only diagnostic available was a screenshot, and the cause
/// had to be inferred from source. This records what actually happened, in
/// order, and survives the extension being killed -- which iOS does often.
///
/// Two sinks:
/// - `os_log`, for a tethered device (Console.app, `log stream`). Free, nothing
///   stored.
/// - a capped file in the app group, so a failure on a TestFlight build can be
///   read after the fact rather than reproduced live.
///
/// **Never record transcript text.** Phases, identifiers, and timings only. A
/// diagnostics buffer full of what people dictated is a liability the moment a
/// tester pastes it into a chat.
enum KeyboardDiagnosticsLog {
    /// Roughly a few dictation sessions' worth of history -- enough to see how a
    /// session got into a bad state, small enough to stay cheap to rewrite.
    static let entryLimit = 200

    private static let logger = Logger(
        subsystem: MuesliAppConstants.appGroupIdentifier,
        category: "keyboard-lifecycle"
    )

    private static let fileName = "keyboard-diagnostics.log"
    private static let queue = DispatchQueue(label: "com.phequals7.muesli.keyboard-diagnostics")

    /// Records one transition. `detail` values are truncated and must never
    /// carry user content.
    static func record(
        _ event: String,
        _ detail: [String: String] = [:],
        process: String = ProcessInfo.processInfo.processName,
        at date: Date = .now
    ) {
        let rendered = detail
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(sanitize($0.value))" }
            .joined(separator: " ")

        logger.debug("\(event, privacy: .public) \(rendered, privacy: .public)")

        let fields = [process, event, rendered].filter { !$0.isEmpty }
        queue.async { append(fields: fields, at: date) }
    }

    /// The buffer as text, oldest first, for export or a debug screen.
    static func exportText() -> String {
        queue.sync {
            guard let url = fileURL() else { return "" }
            var contents = ""
            var coordinationError: NSError?
            NSFileCoordinator().coordinate(
                readingItemAt: url,
                options: .withoutChanges,
                error: &coordinationError
            ) { claimedURL in
                contents = (try? String(contentsOf: claimedURL, encoding: .utf8)) ?? ""
            }
            return contents
        }
    }

    static func clear() {
        queue.sync {
            guard let url = fileURL() else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Storage

    private static func fileURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: MuesliAppConstants.appGroupIdentifier)?
            .appendingPathComponent(fileName)
    }

    /// Appends, then trims to the newest `entryLimit` lines. Rewriting a
    /// 200-line file is cheaper than the bookkeeping needed to avoid it, and
    /// this runs off the main thread.
    ///
    /// The read-modify-write is wrapped in an `NSFileCoordinator` write claim.
    /// Without it, the app and the extension can read the same contents and
    /// replace each other's line, dropping events precisely around the
    /// cross-process handoffs this log exists to explain.
    private static func append(fields: [String], at date: Date) {
        guard let url = fileURL() else { return }

        // Built here rather than held as shared state: ISO8601DateFormatter is
        // not Sendable, and this is the only context that touches it.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let line = ([formatter.string(from: date)] + fields).joined(separator: "\t")

        // Created per access: NSFileCoordinator is not Sendable, and the queue
        // above only orders writes within one process. The app and the keyboard
        // extension both record here, and the interesting events are exactly
        // the cross-process handoffs, so their writes must be ordered against
        // each other too.
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(
            writingItemAt: url,
            options: .forMerging,
            error: &coordinationError
        ) { claimedURL in
            var lines = (try? String(contentsOf: claimedURL, encoding: .utf8))?
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init) ?? []

            lines.append(line)
            if lines.count > entryLimit {
                lines.removeFirst(lines.count - entryLimit)
            }

            // Written without file protection so the extension can still record
            // while the device is locked -- the exact window where dictation
            // failures have been hardest to explain. Safe because the contents
            // are phases and identifiers, never user content.
            try? (lines.joined(separator: "\n") + "\n").write(
                to: claimedURL,
                atomically: true,
                encoding: .utf8
            )
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.none],
                ofItemAtPath: claimedURL.path
            )
        }
    }

    private static func sanitize(_ value: String) -> String {
        let collapsed = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        return collapsed.count <= 64 ? collapsed : String(collapsed.prefix(64)) + "..."
    }
}
