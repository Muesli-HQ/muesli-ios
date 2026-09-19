@preconcurrency import ActivityKit
import Foundation

@MainActor
final class KeyboardMicActivityController {
    private var activity: Activity<KeyboardMicActivityAttributes>?
    private var lastState: KeyboardMicActivityAttributes.ContentState?
    private var updateTask: Task<Void, Never>?
    private var completionTask: Task<Void, Never>?

    func hasActivity(sessionID: UUID?) -> Bool {
        guard let sessionID else { return false }
        return activity?.attributes.sessionID == sessionID.uuidString
            && (activity?.activityState == .active || activity?.activityState == .stale)
    }

    func start(sessionID: UUID, isRecording: Bool) {
        guard activity == nil, ActivityAuthorizationInfo().areActivitiesEnabled,
              MuesliPreferences.liveActivitiesForDictationsEnabled else { return }
        do {
            let state = KeyboardMicActivityAttributes.ContentState(isRecording: isRecording, isReady: true)
            activity = try Activity.request(
                attributes: KeyboardMicActivityAttributes(sessionID: sessionID.uuidString),
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
            lastState = state
        } catch {
            KeyboardDiagnosticsLog.record("keyboardMic.activityFailed", ["error": String(describing: error)])
        }
    }

    func update(sessionID: UUID, isRecording: Bool, isReady: Bool) {
        guard let activity, activity.attributes.sessionID == sessionID.uuidString else { return }
        let state = KeyboardMicActivityAttributes.ContentState(
            isRecording: isRecording, isReady: isReady,
            waveform: isRecording ? lastState?.waveform : nil,
            completionExpiresAt: !isRecording && isReady ? lastState?.completionExpiresAt : nil
        )
        if isRecording || !isReady {
            completionTask?.cancel()
            completionTask = nil
        }
        enqueue(state, activity: activity)
    }

    func showCompletion(sessionID: UUID?) {
        guard let sessionID, let activity,
              activity.attributes.sessionID == sessionID.uuidString,
              var state = lastState, !state.isRecording, state.isReady else { return }
        completionTask?.cancel()
        let expiry = Date.now.addingTimeInterval(5)
        state.completionExpiresAt = expiry
        enqueue(state, activity: activity)
        completionTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) }
            catch { return }
            guard let self, self.activity?.id == activity.id,
                  var current = self.lastState, current.completionExpiresAt == expiry else { return }
            current.completionExpiresAt = nil
            self.enqueue(current, activity: activity)
            self.completionTask = nil
        }
    }

    private func enqueue(_ state: KeyboardMicActivityAttributes.ContentState,
                         activity: Activity<KeyboardMicActivityAttributes>) {
        guard lastState != state else { return }
        lastState = state
        let previous = updateTask
        updateTask = Task {
            await previous?.value
            guard !Task.isCancelled, self.activity?.id == activity.id,
                  self.lastState == state else { return }
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
    }

    func updateWaveform(_ samples: [Double], sessionID: UUID) async {
        guard let activity, activity.attributes.sessionID == sessionID.uuidString,
              var state = lastState, state.isRecording else { return }
        state.waveform = MuesliLiveActivityWaveform.bars(samples)
        enqueue(state, activity: activity)
        await updateTask?.value
    }

    func end(sessionID: UUID) async {
        if activity?.attributes.sessionID == sessionID.uuidString {
            completionTask?.cancel()
            completionTask = nil
            activity = nil
            lastState = nil
            let pendingUpdate = updateTask
            updateTask = nil
            pendingUpdate?.cancel()
            await pendingUpdate?.value
        }
        for item in Activity<KeyboardMicActivityAttributes>.activities
            where item.attributes.sessionID == sessionID.uuidString {
            await item.end(nil, dismissalPolicy: .immediate)
        }
    }

    func removeOrphanedActivities() async {
        for item in Activity<KeyboardMicActivityAttributes>.activities where item.id != activity?.id {
            await item.end(nil, dismissalPolicy: .immediate)
        }
    }
}
