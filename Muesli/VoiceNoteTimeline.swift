import Foundation
import SwiftUI

enum DictationSourceFilter: String, CaseIterable, Identifiable, Equatable {
    case all
    case thisIPhone
    case fromMac

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            "All"
        case .thisIPhone:
            "This iPhone"
        case .fromMac:
            "From Mac"
        }
    }

    func includes(_ origin: SyncOrigin) -> Bool {
        switch self {
        case .all:
            true
        case .thisIPhone:
            origin == .thisIPhone
        case .fromMac:
            origin == .fromMac
        }
    }

    func statTint(default tint: Color) -> Color {
        switch self {
        case .all:
            tint
        case .thisIPhone:
            MuesliTheme.accent
        case .fromMac:
            MuesliTheme.success
        }
    }
}

enum VoiceNoteTimelineItem: Identifiable, Equatable {
    case completed(DictationResult, RecordingSession?)
    case recoverable(RecordingSession)

    var id: String {
        switch self {
        case .completed(let result, _): "result-\(result.id.uuidString)"
        case .recoverable(let session): "session-\(session.id.uuidString)"
        }
    }

    var createdAt: Date {
        switch self {
        case .completed(let result, _): result.createdAt
        case .recoverable(let session): session.createdAt
        }
    }
}

struct VoiceNoteTimelineInput: Equatable {
    let history: [DictationResult]
    let sessions: [RecordingSession]
    let sourceFilter: DictationSourceFilter
}

enum VoiceNoteTimelineBuilder {
    static func build(from input: VoiceNoteTimelineInput) -> [VoiceNoteTimelineItem] {
        let sessionsByID = Dictionary(
            uniqueKeysWithValues: input.sessions.map { ($0.id, $0) }
        )
        let completed = input.history.compactMap { result -> VoiceNoteTimelineItem? in
            guard input.sourceFilter.includes(result.syncOrigin) else { return nil }
            return .completed(
                result,
                result.sessionID.flatMap { sessionsByID[$0] }
            )
        }
        let recoverable = input.sessions.compactMap { session -> VoiceNoteTimelineItem? in
            guard input.sourceFilter.includes(session.syncOrigin),
                  session.kind != .meeting,
                  session.isLongForm,
                  [.recording, .transcriptionQueued, .transcribing, .failed].contains(session.phase)
            else { return nil }
            return .recoverable(session)
        }
        return mergeNewestFirst(completed, recoverable)
    }

    private static func mergeNewestFirst(
        _ completed: [VoiceNoteTimelineItem],
        _ recoverable: [VoiceNoteTimelineItem]
    ) -> [VoiceNoteTimelineItem] {
        var completedIndex = 0
        var recoverableIndex = 0
        var merged: [VoiceNoteTimelineItem] = []
        merged.reserveCapacity(completed.count + recoverable.count)

        while completedIndex < completed.count || recoverableIndex < recoverable.count {
            if completedIndex == completed.count {
                merged.append(recoverable[recoverableIndex])
                recoverableIndex += 1
            } else if recoverableIndex == recoverable.count
                        || completed[completedIndex].createdAt >= recoverable[recoverableIndex].createdAt {
                merged.append(completed[completedIndex])
                completedIndex += 1
            } else {
                merged.append(recoverable[recoverableIndex])
                recoverableIndex += 1
            }
        }
        return merged
    }
}

/// A view-owned memoizer. Array values are copy-on-write, so retaining the last
/// exact input is cheap and avoids rebuilding a large timeline for unrelated UI
/// changes such as sync or clipboard status updates.
@MainActor
final class VoiceNoteTimelineCache {
    private var cachedInput: VoiceNoteTimelineInput?
    private var cachedItems: [VoiceNoteTimelineItem] = []
    private(set) var rebuildCount = 0

    func items(for input: VoiceNoteTimelineInput) -> [VoiceNoteTimelineItem] {
        guard cachedInput != input else { return cachedItems }
        cachedInput = input
        cachedItems = VoiceNoteTimelineBuilder.build(from: input)
        rebuildCount += 1
        return cachedItems
    }
}
