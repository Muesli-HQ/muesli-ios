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
    case start
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

enum MeetingProcessingState: String, Codable, Sendable, Equatable {
    case notStarted
    case processing
    case completed
    case failed
    case unavailable
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
    var keepsAudioRecording: Bool
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
        keepsAudioRecording: Bool = false,
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
        self.keepsAudioRecording = keepsAudioRecording
        self.transcriptID = transcriptID
        self.engineIdentifier = engineIdentifier
        self.errorMessage = errorMessage
    }

    var duration: TimeInterval? {
        guard let startedAt else { return nil }
        return (endedAt ?? .now).timeIntervalSince(startedAt)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case requestID
        case kind
        case title
        case createdAt
        case startedAt
        case endedAt
        case phase
        case audioFileName
        case keepsAudioRecording
        case transcriptID
        case engineIdentifier
        case errorMessage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        requestID = try container.decodeIfPresent(UUID.self, forKey: .requestID)
        kind = try container.decode(RecordingSessionKind.self, forKey: .kind)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? kind.title
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        phase = try container.decodeIfPresent(RecordingSessionPhase.self, forKey: .phase) ?? .recording
        audioFileName = try container.decodeIfPresent(String.self, forKey: .audioFileName)
        keepsAudioRecording = try container.decodeIfPresent(Bool.self, forKey: .keepsAudioRecording) ?? false
        transcriptID = try container.decodeIfPresent(UUID.self, forKey: .transcriptID)
        engineIdentifier = try container.decodeIfPresent(String.self, forKey: .engineIdentifier)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
    }
}

struct Transcript: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let sessionID: UUID
    let text: String
    let createdAt: Date
    let engineIdentifier: String
    let speakerTranscript: String?
    let summaryText: String?
    let diarizationState: MeetingProcessingState
    let diarizationErrorMessage: String?
    let summaryState: MeetingProcessingState
    let summaryBackend: String?
    let summaryModel: String?
    let summaryErrorMessage: String?

    init(
        id: UUID = UUID(),
        sessionID: UUID,
        text: String,
        createdAt: Date = .now,
        engineIdentifier: String,
        speakerTranscript: String? = nil,
        summaryText: String? = nil,
        diarizationState: MeetingProcessingState = .notStarted,
        diarizationErrorMessage: String? = nil,
        summaryState: MeetingProcessingState = .notStarted,
        summaryBackend: String? = nil,
        summaryModel: String? = nil,
        summaryErrorMessage: String? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.text = text
        self.createdAt = createdAt
        self.engineIdentifier = engineIdentifier
        self.speakerTranscript = speakerTranscript
        self.summaryText = summaryText
        self.diarizationState = diarizationState
        self.diarizationErrorMessage = diarizationErrorMessage
        self.summaryState = summaryState
        self.summaryBackend = summaryBackend
        self.summaryModel = summaryModel
        self.summaryErrorMessage = summaryErrorMessage
    }

    enum CodingKeys: String, CodingKey {
        case id
        case sessionID
        case text
        case createdAt
        case engineIdentifier
        case speakerTranscript
        case summaryText
        case diarizationState
        case diarizationErrorMessage
        case summaryState
        case summaryBackend
        case summaryModel
        case summaryErrorMessage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        sessionID = try container.decode(UUID.self, forKey: .sessionID)
        text = try container.decode(String.self, forKey: .text)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        engineIdentifier = try container.decode(String.self, forKey: .engineIdentifier)
        speakerTranscript = try container.decodeIfPresent(String.self, forKey: .speakerTranscript)
        summaryText = try container.decodeIfPresent(String.self, forKey: .summaryText)
        diarizationState = try container.decodeIfPresent(MeetingProcessingState.self, forKey: .diarizationState) ?? .notStarted
        diarizationErrorMessage = try container.decodeIfPresent(String.self, forKey: .diarizationErrorMessage)
        summaryState = try container.decodeIfPresent(MeetingProcessingState.self, forKey: .summaryState) ?? .notStarted
        summaryBackend = try container.decodeIfPresent(String.self, forKey: .summaryBackend)
        summaryModel = try container.decodeIfPresent(String.self, forKey: .summaryModel)
        summaryErrorMessage = try container.decodeIfPresent(String.self, forKey: .summaryErrorMessage)
    }
}

struct CustomWord: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var word: String
    var replacement: String?
    var matchingThreshold: Double
    var createdAt: Date
    var isEnabled: Bool

    var targetWord: String {
        let trimmedReplacement = replacement?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedReplacement.isEmpty ? word : trimmedReplacement
    }

    init(
        id: UUID = UUID(),
        word: String,
        replacement: String? = nil,
        matchingThreshold: Double = 0.85,
        createdAt: Date = .now,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.word = word
        self.replacement = replacement
        self.matchingThreshold = Self.clampedThreshold(matchingThreshold)
        self.createdAt = createdAt
        self.isEnabled = isEnabled
    }

    enum CodingKeys: String, CodingKey {
        case id
        case word
        case replacement
        case matchingThreshold = "matching_threshold"
        case createdAt = "created_at"
        case isEnabled = "is_enabled"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
        word = try container.decode(String.self, forKey: .word)
        replacement = try container.decodeIfPresent(String.self, forKey: .replacement)
        matchingThreshold = Self.clampedThreshold(
            (try? container.decode(Double.self, forKey: .matchingThreshold)) ?? 0.85
        )
        createdAt = (try? container.decode(Date.self, forKey: .createdAt)) ?? .now
        isEnabled = (try? container.decode(Bool.self, forKey: .isEnabled)) ?? true
    }

    private static func clampedThreshold(_ value: Double) -> Double {
        min(max(value, 0.70), 0.95)
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

struct KeyboardRuntimeStatus: Codable, Sendable, Equatable {
    let isActive: Bool
    let activeRequestID: UUID?
    let phase: DictationPhase
    let message: String?
    let supportsBackgroundStart: Bool
    let updatedAt: Date

    init(
        isActive: Bool,
        activeRequestID: UUID? = nil,
        phase: DictationPhase = .idle,
        message: String? = nil,
        supportsBackgroundStart: Bool = false,
        updatedAt: Date = .now
    ) {
        self.isActive = isActive
        self.activeRequestID = activeRequestID
        self.phase = phase
        self.message = message
        self.supportsBackgroundStart = supportsBackgroundStart
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case isActive
        case activeRequestID
        case phase
        case message
        case supportsBackgroundStart
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isActive = try container.decode(Bool.self, forKey: .isActive)
        activeRequestID = try container.decodeIfPresent(UUID.self, forKey: .activeRequestID)
        phase = try container.decode(DictationPhase.self, forKey: .phase)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        supportsBackgroundStart = try container.decodeIfPresent(Bool.self, forKey: .supportsBackgroundStart) ?? false
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}
