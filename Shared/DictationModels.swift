import Foundation

enum DictationPhase: String, Codable, Sendable, Equatable {
    case idle
    case requested
    case recording
    case transcribing
    case finished
    case failed
}

enum DictationCommandAction: String, Codable, Sendable, Equatable {
    case stop
    case cancel
}

enum RecordingSessionKind: String, Codable, Sendable, Equatable, CaseIterable {
    case quickDictation
    case keyboardDictation
    case meeting

    var title: String {
        switch self {
        case .quickDictation:
            "Quick Dictation"
        case .keyboardDictation:
            "Keyboard Dictation"
        case .meeting:
            "Meeting"
        }
    }
}

enum RecordingSessionPhase: String, Codable, Sendable, Equatable {
    case recording
    case transcriptionQueued
    case transcribing
    case completed
    case failed
    case cancelled
}

struct DictationRequest: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let createdAt: Date
    let sourceBundleIdentifier: String?

    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        sourceBundleIdentifier: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.sourceBundleIdentifier = sourceBundleIdentifier
    }
}

struct DictationCommand: Codable, Sendable, Equatable {
    let requestID: UUID
    let action: DictationCommandAction
    let createdAt: Date

    init(
        requestID: UUID,
        action: DictationCommandAction,
        createdAt: Date = .now
    ) {
        self.requestID = requestID
        self.action = action
        self.createdAt = createdAt
    }
}

struct DictationResult: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let requestID: UUID
    let sessionID: UUID?
    let text: String
    let createdAt: Date
    let engineIdentifier: String

    init(
        id: UUID = UUID(),
        requestID: UUID,
        sessionID: UUID? = nil,
        text: String,
        createdAt: Date = .now,
        engineIdentifier: String
    ) {
        self.id = id
        self.requestID = requestID
        self.sessionID = sessionID
        self.text = text
        self.createdAt = createdAt
        self.engineIdentifier = engineIdentifier
    }
}

struct RecordingSession: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let requestID: UUID?
    let kind: RecordingSessionKind
    var title: String?
    let createdAt: Date
    var startedAt: Date?
    var endedAt: Date?
    var phase: RecordingSessionPhase
    var audioFileName: String?
    var transcriptID: UUID?
    var engineIdentifier: String?
    var errorMessage: String?

    init(
        id: UUID = UUID(),
        requestID: UUID? = nil,
        kind: RecordingSessionKind,
        title: String? = nil,
        createdAt: Date = .now,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        phase: RecordingSessionPhase = .recording,
        audioFileName: String? = nil,
        transcriptID: UUID? = nil,
        engineIdentifier: String? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.requestID = requestID
        self.kind = kind
        self.title = title ?? kind.title
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.phase = phase
        self.audioFileName = audioFileName
        self.transcriptID = transcriptID
        self.engineIdentifier = engineIdentifier
        self.errorMessage = errorMessage
    }

    var duration: TimeInterval? {
        guard let startedAt else { return nil }
        return (endedAt ?? .now).timeIntervalSince(startedAt)
    }
}

struct Transcript: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let sessionID: UUID
    let text: String
    let createdAt: Date
    let engineIdentifier: String

    init(
        id: UUID = UUID(),
        sessionID: UUID,
        text: String,
        createdAt: Date = .now,
        engineIdentifier: String
    ) {
        self.id = id
        self.sessionID = sessionID
        self.text = text
        self.createdAt = createdAt
        self.engineIdentifier = engineIdentifier
    }
}

struct DictationStatus: Codable, Sendable, Equatable {
    let requestID: UUID?
    let phase: DictationPhase
    let message: String?
    let updatedAt: Date

    init(
        requestID: UUID?,
        phase: DictationPhase,
        message: String? = nil,
        updatedAt: Date = .now
    ) {
        self.requestID = requestID
        self.phase = phase
        self.message = message
        self.updatedAt = updatedAt
    }

    static let idle = DictationStatus(requestID: nil, phase: .idle)
}

struct KeyboardExtensionStatus: Codable, Sendable, Equatable {
    let lastSeenAt: Date
    let hasOpenAccess: Bool
}
