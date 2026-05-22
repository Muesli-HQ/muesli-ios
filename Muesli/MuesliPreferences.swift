import Foundation

enum MuesliPreferences {
    static let liveActivitiesForDictationsKey = "muesli.liveActivities.dictations"
    static let liveActivitiesForMeetingsKey = "muesli.liveActivities.meetings"
    static let keyboardSessionModeKey = "muesli.keyboardSession.enabled"
    static let keyboardSessionTimeoutMinutesKey = "muesli.keyboardSession.timeoutMinutes"
    static let fillerWordRemovalKey = "muesli.transcription.fillerWordRemoval"
    static let customDictionaryKey = "muesli.transcription.customDictionary"
    static let keepMeetingAudioRecordingsKey = "muesli.meetings.keepAudioRecordings"
    static let meetingSummariesEnabledKey = "muesli.meetings.summaries.enabled"
    static let meetingSummaryBackendKey = "muesli.meetings.summary.backend"
    static let openRouterModelKey = "muesli.meetings.summary.openRouter.model"
    static let chatGPTModelKey = "muesli.meetings.summary.chatGPT.model"
    static let iCloudSyncEnabledKey = "muesli.sync.icloud.enabled"

    static var liveActivitiesForDictationsEnabled: Bool {
        bool(for: liveActivitiesForDictationsKey, defaultValue: true)
    }

    static var liveActivitiesForMeetingsEnabled: Bool {
        bool(for: liveActivitiesForMeetingsKey, defaultValue: true)
    }

    static var keyboardSessionModeEnabled: Bool {
        bool(for: keyboardSessionModeKey, defaultValue: false)
    }

    static var keyboardSessionTimeoutMinutes: Int {
        let value = UserDefaults.standard.integer(forKey: keyboardSessionTimeoutMinutesKey)
        return value == 0 ? 10 : min(max(value, 1), 30)
    }

    static var fillerWordRemovalEnabled: Bool {
        bool(for: fillerWordRemovalKey, defaultValue: true)
    }

    static var customDictionaryEnabled: Bool {
        bool(for: customDictionaryKey, defaultValue: true)
    }

    static var keepMeetingAudioRecordingsEnabled: Bool {
        bool(for: keepMeetingAudioRecordingsKey, defaultValue: false)
    }

    static var meetingSummariesEnabled: Bool {
        bool(for: meetingSummariesEnabledKey, defaultValue: false)
    }

    static var iCloudSyncEnabled: Bool {
        bool(for: iCloudSyncEnabledKey, defaultValue: false)
    }

    static var meetingSummaryBackend: MeetingSummaryBackend {
        MeetingSummaryBackend(
            rawValue: UserDefaults.standard.string(forKey: meetingSummaryBackendKey) ?? ""
        ) ?? .openRouter
    }

    static var openRouterModel: String {
        let value = UserDefaults.standard.string(forKey: openRouterModelKey) ?? ""
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? MeetingSummaryBackend.defaultOpenRouterModel
            : value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var chatGPTModel: String {
        let value = UserDefaults.standard.string(forKey: chatGPTModelKey) ?? ""
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else { return MeetingSummaryBackend.defaultChatGPTModel }
        guard SummaryModelPreset.chatGPTModels.contains(where: { $0.id == trimmedValue }) else {
            return MeetingSummaryBackend.defaultChatGPTModel
        }
        return trimmedValue
    }

    static func liveActivitiesEnabled(for kind: RecordingSessionKind) -> Bool {
        switch kind {
        case .quickDictation, .keyboardDictation:
            liveActivitiesForDictationsEnabled
        case .meeting:
            liveActivitiesForMeetingsEnabled
        }
    }

    private static func bool(for key: String, defaultValue: Bool) -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }
}

enum MeetingSummaryBackend: String, CaseIterable, Identifiable {
    case openRouter = "openrouter"
    case chatGPT = "chatgpt"

    static let defaultOpenRouterModel = "stepfun/step-3.5-flash:free"
    static let defaultChatGPTModel = "gpt-5.5"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .openRouter:
            "OpenRouter"
        case .chatGPT:
            "ChatGPT"
        }
    }

    var defaultModel: String {
        switch self {
        case .openRouter:
            Self.defaultOpenRouterModel
        case .chatGPT:
            Self.defaultChatGPTModel
        }
    }
}

struct SummaryModelPreset: Identifiable, Hashable {
    let id: String
    let label: String

    static let chatGPTModels: [SummaryModelPreset] = [
        SummaryModelPreset(id: "gpt-5.5", label: "GPT-5.5 (default)"),
        SummaryModelPreset(id: "gpt-5.4-mini", label: "GPT-5.4 Mini"),
    ]

    static let openRouterModels: [SummaryModelPreset] = [
        SummaryModelPreset(id: "stepfun/step-3.5-flash:free", label: "Step 3.5 Flash (256k ctx)"),
        SummaryModelPreset(id: "nvidia/nemotron-3-super-120b-a12b:free", label: "Nemotron 3 Super 120B (262k ctx)"),
        SummaryModelPreset(id: "nvidia/nemotron-3-nano-30b-a3b:free", label: "Nemotron 3 Nano 30B (256k ctx)"),
        SummaryModelPreset(id: "arcee-ai/trinity-large-preview:free", label: "Trinity Large (131k ctx)"),
    ]

    static func menuPresets(
        _ presets: [SummaryModelPreset],
        currentModel: String,
        preserveCustomValue: Bool = true
    ) -> [SummaryModelPreset] {
        let trimmedModel = currentModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else { return presets }
        guard !presets.contains(where: { $0.id == trimmedModel }) else { return presets }
        guard preserveCustomValue else { return presets }
        return presets + [SummaryModelPreset(id: trimmedModel, label: "Custom: \(trimmedModel)")]
    }
}
