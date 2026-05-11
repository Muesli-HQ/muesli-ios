@preconcurrency import ActivityKit
import Foundation

actor MuesliLiveActivityController {
    private var activity: Activity<MuesliLiveActivityAttributes>?

    func start(session: RecordingSession, requestID: UUID?, phase: String, detail: String) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

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
        guard let activity else { return }
        await activity.update(ActivityContent(
            state: contentState(phase: phase, detail: detail, session: session),
            staleDate: nil
        ))
    }

    func end(phase: String, detail: String, session: RecordingSession, dismissal: ActivityUIDismissalPolicy = .default) async {
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

    private func contentState(phase: String, detail: String, session: RecordingSession) -> MuesliLiveActivityAttributes.ContentState {
        MuesliLiveActivityAttributes.ContentState(
            title: session.title ?? session.kind.title,
            phase: phase,
            detail: detail,
            startedAt: session.startedAt ?? session.createdAt,
            accent: accent(for: phase)
        )
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
