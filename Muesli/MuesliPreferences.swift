import Foundation

enum MuesliPreferences {
    static let appearanceModeKey = "muesli.appearance.mode"
    static let accentThemeKey = "muesli.appearance.accent"
    static let liveActivitiesForDictationsKey = "muesli.liveActivities.dictations"
    static let liveActivitiesForMeetingsKey = "muesli.liveActivities.meetings"
    static let keyboardSessionModeKey = "muesli.keyboardSession.enabled"
    static let keyboardSessionTimeoutMinutesKey = "muesli.keyboardSession.timeoutMinutes"
    static let fillerWordRemovalKey = "muesli.transcription.fillerWordRemoval"
    static let customDictionaryKey = "muesli.transcription.customDictionary"
    static let transcriptionModelKey = "muesli.transcription.localModel"
    static let keepDictationAudioRecordingsKey = "muesli.dictations.keepAudioRecordings"
    static let keepMeetingAudioRecordingsKey = "muesli.meetings.keepAudioRecordings"
    static let recordingMicrophonePreferenceKey = "muesli.recording.microphonePreference"
    static let meetingSummariesEnabledKey = "muesli.meetings.summaries.enabled"
    static let meetingSummaryBackendKey = "muesli.meetings.summary.backend"
    static let openRouterModelKey = "muesli.meetings.summary.openRouter.model"
    static let chatGPTModelKey = "muesli.meetings.summary.chatGPT.model"
    static let meetingTemplateKey = "muesli.meetings.template"
    static let iCloudSyncEnabledKey = "muesli.sync.icloud.enabled"
    static let pinnedSectionsKey = "muesli.navigation.pinnedSections"

    static var appearanceMode: MuesliAppearanceMode {
        MuesliAppearanceMode(
            rawValue: UserDefaults.standard.string(forKey: appearanceModeKey) ?? ""
        ) ?? .system
    }

    static var accentTheme: MuesliAccentTheme {
        MuesliAccentTheme.resolved(
            rawValue: UserDefaults.standard.string(forKey: accentThemeKey) ?? ""
        )
    }

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

    static var transcriptionModel: LocalTranscriptionModel {
        LocalTranscriptionModel(
            rawValue: UserDefaults.standard.string(forKey: transcriptionModelKey) ?? ""
        ) ?? .defaultModel
    }

    static var keepDictationAudioRecordingsEnabled: Bool {
        bool(for: keepDictationAudioRecordingsKey, defaultValue: false)
    }

    static var keepMeetingAudioRecordingsEnabled: Bool {
        bool(for: keepMeetingAudioRecordingsKey, defaultValue: false)
    }

    static var recordingMicrophonePreference: RecordingMicrophonePreference {
        RecordingMicrophonePreference(
            rawValue: UserDefaults.standard.string(forKey: recordingMicrophonePreferenceKey) ?? ""
        ) ?? .automatic
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

    static var meetingTemplate: MeetingTemplatePreset {
        MeetingTemplatePreset(
            rawValue: UserDefaults.standard.string(forKey: meetingTemplateKey) ?? ""
        ) ?? .general
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

enum MeetingTemplatePreset: String, CaseIterable, Identifiable {
    case general
    case oneOnOne
    case standup
    case interview
    case lecture
    case customerCall
    case planning

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general:
            "General Meeting"
        case .oneOnOne:
            "1:1"
        case .standup:
            "Standup"
        case .interview:
            "Interview"
        case .lecture:
            "Lecture"
        case .customerCall:
            "Customer Call"
        case .planning:
            "Planning"
        }
    }

    var detail: String {
        switch self {
        case .general:
            "Balanced notes, decisions, and action items."
        case .oneOnOne:
            "Feedback, blockers, follow-ups, and commitments."
        case .standup:
            "Progress, next work, blockers, and owners."
        case .interview:
            "Signals, strengths, concerns, and follow-up questions."
        case .lecture:
            "Concepts, examples, questions, and study follow-ups."
        case .customerCall:
            "Pain points, requirements, objections, and next steps."
        case .planning:
            "Goals, scope, risks, milestones, and open questions."
        }
    }

    var instructions: String {
        switch self {
        case .general:
            """
            Follow this note template exactly:

            ## Meeting Summary
            A 2-3 sentence overview of what was discussed.

            ## Key Discussion Points
            - Bullet points of the main topics discussed

            ## Decisions Made
            - Bullet points of any decisions reached

            ## Action Items
            - [ ] Bullet points of tasks assigned or agreed upon, with owners if mentioned

            ## Notable Quotes
            - Any important or notable statements, if applicable
            """
        case .oneOnOne:
            """
            Follow this note template exactly:

            ## 1:1 Summary
            A concise overview of the conversation and current context.

            ## Wins and Progress
            - Bullet points of progress, positive signals, and completed work

            ## Blockers and Concerns
            - Bullet points of blockers, risks, or concerns discussed

            ## Feedback
            - Bullet points of feedback given or requested

            ## Action Items
            - [ ] Follow-up tasks, owners, and timing if mentioned
            """
        case .standup:
            """
            Follow this note template exactly:

            ## Standup Summary
            A concise overview of team status.

            ## Progress
            - What was completed or moved forward

            ## Next Up
            - What people plan to work on next

            ## Blockers
            - Blockers, dependencies, or risks

            ## Action Items
            - [ ] Follow-up tasks with owners if mentioned
            """
        case .interview:
            """
            Follow this note template exactly:

            ## Interview Summary
            A concise overview of the interview discussion.

            ## Key Signals
            - Evidence, examples, and signals observed

            ## Strengths
            - Strengths or positive indicators

            ## Concerns
            - Concerns, gaps, or unclear areas

            ## Follow-up Questions
            - Questions or topics to revisit
            """
        case .lecture:
            """
            Follow this note template exactly:

            ## Lecture Summary
            A concise overview of the session.

            ## Core Concepts
            - Main concepts and definitions

            ## Examples and Evidence
            - Examples, cases, formulas, or references mentioned

            ## Questions
            - Questions raised or unclear points

            ## Follow-ups
            - [ ] Study tasks, readings, or practice items
            """
        case .customerCall:
            """
            Follow this note template exactly:

            ## Customer Call Summary
            A concise overview of the customer conversation.

            ## Customer Goals
            - Desired outcomes, priorities, and success criteria

            ## Pain Points
            - Problems, blockers, or frustrations mentioned

            ## Requirements
            - Feature, workflow, technical, or commercial requirements

            ## Objections and Risks
            - Concerns, objections, or adoption risks

            ## Next Steps
            - [ ] Follow-up tasks, owners, and timing if mentioned
            """
        case .planning:
            """
            Follow this note template exactly:

            ## Planning Summary
            A concise overview of the plan discussed.

            ## Goals
            - Outcomes and priorities

            ## Scope
            - In-scope work, out-of-scope work, and dependencies

            ## Risks and Open Questions
            - Risks, unknowns, and decisions still needed

            ## Milestones
            - Dates, phases, or checkpoints if mentioned

            ## Action Items
            - [ ] Follow-up tasks with owners if mentioned
            """
        }
    }
}
