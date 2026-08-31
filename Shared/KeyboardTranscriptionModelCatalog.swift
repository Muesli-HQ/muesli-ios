import Foundation

struct KeyboardTranscriptionModelOption: Codable, Identifiable, Sendable, Equatable {
    let rawValue: String
    let displayName: String
    let shortName: String
    let capabilityLabel: String
    let isReady: Bool

    var id: String { rawValue }
}

struct KeyboardTranscriptionModelCatalog: Codable, Sendable, Equatable {
    let selectedRawValue: String
    let models: [KeyboardTranscriptionModelOption]
    let canSelectModels: Bool
    let updatedAt: Date

    init(
        selectedRawValue: String,
        models: [KeyboardTranscriptionModelOption],
        canSelectModels: Bool,
        updatedAt: Date = .now
    ) {
        self.selectedRawValue = selectedRawValue
        self.models = models
        self.canSelectModels = canSelectModels
        self.updatedAt = updatedAt
    }

    var selectedModel: KeyboardTranscriptionModelOption? {
        models.first(where: { $0.rawValue == selectedRawValue })
    }

    var readyModels: [KeyboardTranscriptionModelOption] {
        models.filter(\.isReady)
    }
}

struct KeyboardTranscriptionModelSelectionRequest: Codable, Sendable, Equatable {
    let id: UUID
    let modelRawValue: String
    let createdAt: Date

    init(
        id: UUID = UUID(),
        modelRawValue: String,
        createdAt: Date = .now
    ) {
        self.id = id
        self.modelRawValue = modelRawValue
        self.createdAt = createdAt
    }
}
