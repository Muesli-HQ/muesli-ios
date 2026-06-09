@preconcurrency import ActivityKit
import Foundation

actor MuesliLiveActivityController {
    private var activity: Activity<MuesliLiveActivityAttributes>?

    func start(session: RecordingSession, requestID: UUID?, phase: String, detail: String) async {
        guard MuesliPreferences.liveActivitiesEnabled(for: session.kind) else {
            await endActivities(for: session.kind, phase: "Off", detail: "Live Activities disabled")
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        await endInactiveActivities()
        activity = activity ?? existingActivity(for: session)
        if activity != nil {
            await update(phase: phase, detail: detail, session: session)
            return
        }

        let attributes = MuesliLiveActivityAttributes(
            sessionID: session.id.uuidString,
            requestID: requestID?.uuidString,
            kind: session.kind.title
        )
        let content = ActivityContent(
            state: contentState(phase: phase, detail: detail, session: session),
            staleDate: nil
        )

        do {
            activity = try Activity.request(attributes: attributes, content: content, pushType: nil)
        } catch {
            await AppTelemetry.signal(
                "live_activity_failed",
                parameters: ["stage": "request", "error": String(describing: type(of: error))]
            )
        }
    }

    func update(phase: String, detail: String, session: RecordingSession) async {
        guard MuesliPreferences.liveActivitiesEnabled(for: session.kind) else {
            await endActivities(for: session.kind, phase: "Off", detail: "Live Activities disabled")
            return
        }
        activity = activity ?? existingActivity(for: session)
        guard let activity else { return }
        await activity.update(ActivityContent(
            state: contentState(phase: phase, detail: detail, session: session),
            staleDate: nil
        ))
    }

    func end(phase: String, detail: String, session: RecordingSession, dismissal: ActivityUIDismissalPolicy = .default) async {
        activity = activity ?? existingActivity(for: session)
        guard let activity else { return }
        await activity.end(
            ActivityContent(
                state: contentState(phase: phase, detail: detail, session: session),
                staleDate: nil
            ),
            dismissalPolicy: dismissal
        )
        self.activity = nil
    }

    func endInactiveActivities() async {
        for visibleActivity in Activity<MuesliLiveActivityAttributes>.activities
            where !isActiveSessionPhase(visibleActivity.content.state.phase) {
            await visibleActivity.end(
                ActivityContent(
                    state: MuesliLiveActivityAttributes.ContentState(
                        title: visibleActivity.content.state.title,
                        phase: "Ended",
                        detail: "Session ended",
                        startedAt: visibleActivity.content.state.startedAt,
                        accent: "blue"
                    ),
                    staleDate: nil
                ),
                dismissalPolicy: .immediate
            )

            if visibleActivity.id == activity?.id {
                activity = nil
            }
        }
    }

    func endAllActivities(phase: String = "Ended", detail: String = "Session ended") async {
        for visibleActivity in Activity<MuesliLiveActivityAttributes>.activities {
            await visibleActivity.end(
                ActivityContent(
                    state: MuesliLiveActivityAttributes.ContentState(
                        title: visibleActivity.content.state.title,
                        phase: phase,
                        detail: detail,
                        startedAt: visibleActivity.content.state.startedAt,
                        accent: "blue"
                    ),
                    staleDate: nil
                ),
                dismissalPolicy: .immediate
            )

            if visibleActivity.id == activity?.id {
                activity = nil
            }
        }
    }

    func endDisabledActivities() async {
        if !MuesliPreferences.liveActivitiesForDictationsEnabled {
            await endActivities(forKinds: [.quickDictation, .keyboardDictation])
        }
        if !MuesliPreferences.liveActivitiesForMeetingsEnabled {
            await endActivities(forKinds: [.meeting])
        }
    }

    private func endActivities(for kind: RecordingSessionKind, phase: String, detail: String) async {
        await endActivities(forKinds: [kind], phase: phase, detail: detail)
    }

    private func endActivities(
        forKinds kinds: [RecordingSessionKind],
        phase: String = "Off",
        detail: String = "Live Activities disabled"
    ) async {
        let enabledKindTitles = Set(kinds.map(\.title))
        for visibleActivity in Activity<MuesliLiveActivityAttributes>.activities
            where enabledKindTitles.contains(visibleActivity.attributes.kind) {
            await visibleActivity.end(
                ActivityContent(
                    state: MuesliLiveActivityAttributes.ContentState(
                        title: visibleActivity.attributes.kind,
                        phase: phase,
                        detail: detail,
                        startedAt: .now,
                        accent: "blue"
                    ),
                    staleDate: nil
                ),
                dismissalPolicy: .immediate
            )

            if visibleActivity.id == activity?.id {
                activity = nil
            }
        }
    }

    private func contentState(phase: String, detail: String, session: RecordingSession) -> MuesliLiveActivityAttributes.ContentState {
        MuesliLiveActivityAttributes.ContentState(
            title: session.title ?? session.kind.title,
            phase: phase,
            detail: detail,
            startedAt: session.startedAt ?? session.createdAt,
            accent: accent(for: phase)
        )
    }

    private func existingActivity(for session: RecordingSession) -> Activity<MuesliLiveActivityAttributes>? {
        Activity<MuesliLiveActivityAttributes>.activities.first {
            $0.attributes.sessionID == session.id.uuidString
        }
    }

    private func isActiveSessionPhase(_ phase: String) -> Bool {
        switch phase.lowercased() {
        case "ready", "listening", "recording", "transcribing":
            true
        default:
            false
        }
    }

    private func accent(for phase: String) -> String {
        switch phase.lowercased() {
        case "listening", "recording":
            "red"
        case "transcribing":
            "orange"
        default:
            "blue"
        }
    }
}
