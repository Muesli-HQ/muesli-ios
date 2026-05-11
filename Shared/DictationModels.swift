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
    let text: String
    let createdAt: Date
    let engineIdentifier: String

    init(
        id: UUID = UUID(),
        requestID: UUID,
        text: String,
        createdAt: Date = .now,
        engineIdentifier: String
    ) {
        self.id = id
        self.requestID = requestID
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
