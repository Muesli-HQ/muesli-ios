import AVFoundation
import Foundation
@preconcurrency import FluidAudio
import Observation
import UIKit

private struct KeyboardSessionState: Equatable {
    enum Phase: Equatable {
        case off
        case arming
        case ready
        case handoff(UUID)
        case recording(UUID)
        case transcribing(UUID)
        case retrying(String)
        case failed(String)
    }

    var phase: Phase = .off
    var sessionAvailable = false

    var isArmed: Bool {
        switch phase {
        case .ready, .handoff, .recording, .transcribing, .arming:
            sessionAvailable
        case .off, .retrying, .failed:
            false
        }
    }

    var isKeyboardHandoffActive: Bool {
        switch phase {
        case .handoff, .recording, .transcribing:
            true
        case .off, .arming, .ready, .retrying, .failed:
            false
        }
    }

    var isWorkflowActive: Bool {
        switch phase {
        case .handoff, .recording, .transcribing, .arming:
            true
        case .off, .ready, .retrying, .failed:
            false
        }
    }

    var statusText: String {
        switch phase {
        case .off:
            "Off"
        case .arming:
            "Starting"
        case .ready:
            "Ready"
        case .handoff:
            "Starting"
        case .recording:
            "Recording"
        case .transcribing:
            "Transcribing"
        case .retrying(let message):
            message
        case .failed(let message):
            message
        }
    }
}

private enum KeyboardSessionEvent {
    case startRequested
    case startSucceeded
    case startFailed(message: String, recoverable: Bool)
    case retryScheduled(message: String)
    case resumeRequested
    case handoffStarted(UUID)
    case recordingStarted(UUID)
    case transcribing(UUID)
    case requestFinished
    case stop(KeyboardSessionStopReason)
}

private enum KeyboardSessionStopReason: Equatable {
    case off
    case turnedOff
    case stopped

    var message: String {
        switch self {
        case .off:
            "Off"
        case .turnedOff:
            "Turned off"
        case .stopped:
            "Stopped"
        }
    }
}

private enum KeyboardSessionReducer {
    static func reduce(_ state: KeyboardSessionState, event: KeyboardSessionEvent) -> KeyboardSessionState {
        switch event {
        case .startRequested:
            return KeyboardSessionState(phase: .arming)
        case .startSucceeded:
            return KeyboardSessionState(phase: .ready, sessionAvailable: true)
        case .startFailed(let message, let recoverable):
            return KeyboardSessionState(phase: recoverable ? .retrying(message) : .failed(message))
        case .retryScheduled(let message):
            return KeyboardSessionState(phase: .retrying(message))
        case .resumeRequested:
            guard state.isArmed else { return state }
            return KeyboardSessionState(phase: .arming, sessionAvailable: true)
        case .handoffStarted(let requestID):
            return KeyboardSessionState(phase: .handoff(requestID), sessionAvailable: state.sessionAvailable)
        case .recordingStarted(let requestID):
            return KeyboardSessionState(phase: .recording(requestID), sessionAvailable: state.sessionAvailable)
        case .transcribing(let requestID):
            return KeyboardSessionState(phase: .transcribing(requestID), sessionAvailable: state.sessionAvailable)
        case .requestFinished:
            return KeyboardSessionState(
                phase: state.sessionAvailable ? .ready : .off,
                sessionAvailable: state.sessionAvailable
            )
        case .stop:
            return KeyboardSessionState(phase: .off)
        }
    }
}

struct MeetingLifecycleState: Equatable {
    enum Phase: Equatable {
        case idle
        case starting(UUID)
        case recording(UUID)
        case stopping(UUID)
        case transcribing(UUID)
        case cancelling(UUID)
    }

    var phase: Phase = .idle

    var activeSessionID: UUID? {
        switch phase {
        case .idle:
            nil
        case .starting(let id), .recording(let id), .stopping(let id), .transcribing(let id), .cancelling(let id):
            id
        }
    }

    var isCancelling: Bool {
        if case .cancelling = phase { true } else { false }
    }

    func isStarting(sessionID: UUID) -> Bool {
        if case .starting(let id) = phase {
            return id == sessionID
        }
        return false
    }

    var isRecordingVisible: Bool {
        switch phase {
        case .starting, .recording, .stopping:
            true
        case .idle, .transcribing, .cancelling:
            false
        }
    }
}

enum MeetingLifecycleEvent {
    case startRequested(UUID)
    case recordingStarted(UUID)
    case stopRequested(UUID)
    case transcriptionStarted(UUID)
    case cancelRequested(UUID)
    case finished(UUID)
}

enum MeetingLifecycleReducer {
    static func reduce(_ state: MeetingLifecycleState, event: MeetingLifecycleEvent) -> MeetingLifecycleState {
        switch event {
        case .startRequested(let id):
            return MeetingLifecycleState(phase: .starting(id))
        case .recordingStarted(let id):
            guard state.activeSessionID == id else { return state }
            return MeetingLifecycleState(phase: .recording(id))
        case .stopRequested(let id):
            guard state.activeSessionID == id else { return state }
            return MeetingLifecycleState(phase: .stopping(id))
        case .transcriptionStarted(let id):
            return MeetingLifecycleState(phase: .transcribing(id))
        case .cancelRequested(let id):
            guard state.activeSessionID == nil || state.activeSessionID == id else { return state }
            return MeetingLifecycleState(phase: .cancelling(id))
        case .finished(let id):
            guard state.activeSessionID == id else { return state }
            return MeetingLifecycleState()
        }
    }
}

struct MeetingLifecycleRunner {
    let sessionID: UUID
    var startupTask: Task<Void, Never>?
    var finalizationTask: Task<Void, Never>?

    mutating func cancelAll() {
        startupTask?.cancel()
        finalizationTask?.cancel()
        startupTask = nil
        finalizationTask = nil
    }
}

@MainActor
@Observable
final class DictationCoordinator {
    private static let onboardingCompletedKey = "muesli.onboarding.completed"
    private static let userNameKey = "muesli.onboarding.userName"
    private static let useCaseKey = "muesli.onboarding.useCase"
    private static let offlineTranscriptionNoProgressTimeout: TimeInterval = 90

    private let store: SharedStore
    private let voiceNoteCheckpointStore: VoiceNoteCheckpointStore
    private let engine = FluidAudioTranscriptionEngine()
    private let recorder = AudioRecorder()
    private var meetingRecorder: StreamingMeetingRecorder?
    private var realtimeDictationRecorder: StreamingMeetingRecorder?
    private var realtimeDictationBufferPipe: RealtimeAudioBufferPipe?
    private var realtimeDictationProcessingTask: Task<Void, Never>?
    private var realtimeDictationChunksDirectory: URL?
    private var isRealtimeDictationSessionActive = false
    private var realtimeDictationCommittedText = ""
    private var meetingVadController: StreamingVadController?
    private let keyboardSessionKeeper = KeyboardSessionKeeper()
    private let liveActivityController = MuesliLiveActivityController()
    private var modelPreparationTask: Task<Void, Never>?
    private var modelPrewarmTask: Task<Void, Never>?
    private var meteringTask: Task<Void, Never>?
    private var recordingTimerTask: Task<Void, Never>?
    private var commandPollingTask: Task<Void, Never>?
    private var keyboardRuntimePollingTask: Task<Void, Never>?
    private var keyboardRuntimeTickInProgress = false
    private var keyboardSessionRetryTask: Task<Void, Never>?
    private var keyboardSessionRetryAttempt = 0
    private var keyboardSessionLiveActivityRequestIDs = Set<UUID>()
    private var iCloudSyncTask: Task<Void, Never>?
    private var iCloudSyncDebounceTask: Task<Void, Never>?
    private var lastKeyboardRuntimeLevelWriteAt = Date.distantPast
    private var pendingICloudSyncReason: String?
    private var onboardingModelReadyCueModel: LocalTranscriptionModel?
    private var meetingChunkTasks: [Task<MeetingChunkTranscription?, Never>] = []
    private var meetingChunkTranscriptions: [MeetingChunkTranscription] = []
    private var meetingChunksDirectory: URL?
    private var meetingLifecycleState = MeetingLifecycleState()
    private var meetingLifecycleRunner: MeetingLifecycleRunner?
    private var voiceNoteLifecycleState = VoiceNoteLifecycleState()
    private var voiceNoteLifecycleRunner: VoiceNoteLifecycleRunner?
    private let meetingVadQueue = DispatchQueue(label: "com.phequals7.muesli.meeting-vad")
    private var transcriptionBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    nonisolated(unsafe) private var audioRouteObserver: NSObjectProtocol?
    nonisolated(unsafe) private var audioInterruptionObserver: NSObjectProtocol?
    nonisolated(unsafe) private var mediaServicesResetObserver: NSObjectProtocol?

    private var activeRequest: DictationRequest?
    private var activeSession: RecordingSession?
    private var keyboardSessionActivitySession: RecordingSession?
    private var keyboardSessionState = KeyboardSessionState()
    private var stopKeyboardSessionAfterCurrentRequest = false
    var isKeyboardHandoffActive: Bool { keyboardSessionState.isKeyboardHandoffActive }
    var isKeyboardSessionArmed: Bool { keyboardSessionState.isArmed }
    var isModelPrewarmInProgress: Bool { modelPrewarmTask != nil }
    var shouldShowLaunchWarmup: Bool {
        #if DEBUG
        guard !Self.shouldSkipModelPrewarmForTesting() else { return false }
        #endif
        return hasCompletedOnboarding
    }
    private var isKeyboardHotMicEngineReady: Bool {
        isKeyboardSessionArmed && keyboardSessionKeeper.canAcceptStartCommand
    }
    private var canStartKeyboardRequestsInBackground: Bool {
        isKeyboardHotMicEngineReady
            && !isRecording
            && !hasMeetingRecordingInProgress
            && activeRequest == nil
            && statusText != "Transcribing"
    }
    var keyboardSessionStatusText: String { keyboardSessionState.statusText }
    var iCloudSyncStatusText: String?
    var isICloudSyncInProgress = false
    var settingsNavigationRequestID: UUID?
    var inputSettingsNavigationRequestID: UUID?
    var syncSetupRequestID: UUID? {
        didSet {
            if syncSetupRequestID == nil {
                syncSetupSource = nil
            }
        }
    }

    private static let keyboardSessionRetryMessage = "Retrying session standby"
    private static let keyboardSessionUnavailableMessage = "Session standby unavailable. Tap Start to record normally."
    private static let keyboardSessionMaxRetryAttempts = 3
    private static let keyboardSessionRetryBaseDelaySeconds: TimeInterval = 15
    var syncSetupSource: String?
    var hasCompletedOnboarding = UserDefaults.standard.bool(forKey: onboardingCompletedKey)
    var userName = UserDefaults.standard.string(forKey: userNameKey) ?? ""
    var selectedUseCase = OnboardingUseCase(
        rawValue: UserDefaults.standard.string(forKey: useCaseKey) ?? ""
    ) ?? .keyboardDictation
    var selectedTranscriptionModel = MuesliPreferences.transcriptionModel {
        didSet {
            guard oldValue != selectedTranscriptionModel else { return }
            UserDefaults.standard.set(
                selectedTranscriptionModel.rawValue,
                forKey: MuesliPreferences.transcriptionModelKey
            )
            modelPreparationTask?.cancel()
            modelPrewarmTask?.cancel()
            modelPrewarmTask = nil
            modelPreparation = ModelPreparationState(
                status: "\(selectedTranscriptionModel.shortName) is not downloaded",
                detail: selectedTranscriptionModel.detail
            )
            Task { [engine, selectedTranscriptionModel] in
                await engine.selectModel(selectedTranscriptionModel)
            }
            AppTelemetry.signal(
                "transcription_model_selected",
                parameters: ["engine": selectedTranscriptionModel.engineIdentifier]
            )
        }
    }
    var modelPreparation = ModelPreparationState()
    var isOnboardingTestRecording = false
    var isOnboardingTestTranscribing = false
    var onboardingTestInputLevel = 0.0
    var onboardingTestTranscript = ""
    var onboardingTestError: String?
    var isRecording = false
    var inputLevel = 0.0
    var recordingElapsedTime: TimeInterval = 0
    var statusText = "Ready"
    var audioInputRouteText = AudioInputRouteManager.currentSnapshot().displayText
    var meetingStatusText = "Ready"
    var lastTranscript = ""
    var liveDictationTranscript = ""
    var dictationHistory: [DictationResult] = []
    var recordingSessions: [RecordingSession] = []
    private var transcriptCache: [UUID: Transcript] = [:]
    var isMeetingRecording = false
    var isMeetingTranscribing = false
    var activeMeetingTitle = "Untitled Meeting"
    var clipboardStatusText: String?
    var longVoiceNoteCheckpointCount = 0
    var longVoiceNoteAudioIsSecured = false
    var longVoiceNoteDurabilityError: String?
    var presentedLongVoiceNoteSessionID: UUID?

    var activeLongVoiceNoteSession: RecordingSession? {
        guard voiceNoteLifecycleState.isLongFormVisible,
              let session = activeSession,
              session.kind != .meeting,
              session.isLongForm
        else { return nil }
        return session
    }

    var presentedLongVoiceNoteSession: RecordingSession? {
        guard let sessionID = presentedLongVoiceNoteSessionID else { return nil }
        if activeSession?.id == sessionID {
            return activeSession
        }
        return recordingSessions.first(where: { $0.id == sessionID })
            ?? (try? store.activeRecordingSession(id: sessionID))
    }

    var recoverableVoiceNoteSessions: [RecordingSession] {
        recordingSessions.filter { session in
            session.kind != .meeting
                && session.isLongForm
                && [.recording, .transcriptionQueued, .transcribing, .failed].contains(session.phase)
        }
    }

    var hasMeetingRecordingInProgress: Bool {
        meetingLifecycleState.isRecordingVisible
            || isMeetingRecording
            || isMeetingTranscribing
            || activeSession?.kind == .meeting
            || persistedRecordingMeetingSession != nil
    }

    var activeMeetingSessionID: UUID? {
        if activeSession?.kind == .meeting {
            return activeSession?.id
        }
        return persistedRecordingMeetingSession?.id
    }

    var effectiveMeetingStatusText: String {
        if isMeetingRecording || persistedRecordingMeetingSession != nil {
            "Recording"
        } else {
            meetingStatusText
        }
    }

    private var persistedRecordingMeetingSession: RecordingSession? {
        recordingSessions.first { session in
            session.kind == .meeting && session.phase == .recording
        }
    }

    init() {
        let store = SharedStore()
        self.store = store
        voiceNoteCheckpointStore = VoiceNoteCheckpointStore(store: store)
        ModelBackgroundDownloadService.shared.delegate = self

        #if DEBUG
        if Self.shouldConfigureForUITestingFromLaunchArguments() {
            configureForUITesting()
        } else if Self.shouldResetOnboardingFromLaunchArguments() {
            resetOnboardingForTesting()
        }
        #endif

        audioRouteObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAudioInputRoute()
            }
        }
        audioInterruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let didBegin = rawType.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began
            guard didBegin else { return }
            Task { @MainActor in
                self?.handleAudioSessionInterruption()
            }
        }
        mediaServicesResetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleVoiceNoteRecordingInterruption(
                    message: "Audio services restarted",
                    cause: .interrupted
                )
            }
        }
        keyboardSessionKeeper.onRecordingFailure = { [weak self] failure in
            Task { @MainActor in
                self?.handleVoiceNoteWriterFailure(failure)
            }
        }
        keyboardSessionKeeper.setInputActivityHandler { [weak self] powerDB, isCapturing in
            Task { @MainActor in
                await self?.handleKeyboardSessionInputActivity(powerDB: powerDB, isCapturing: isCapturing)
            }
        }

        refreshAudioInputRoute()
        refreshHistory()
        Task { @MainActor in
            await recoverLongVoiceNotesOnLaunch()
        }
        Task {
            await liveActivityController.endAllActivities(
                detail: "Recovered from interrupted session"
            )
        }
        prewarmModelIfNeeded(reason: "launch")
        if MuesliPreferences.keyboardSessionModeEnabled {
            Task { @MainActor in
                await startKeyboardSessionMode()
            }
        }
    }

    deinit {
        if let audioRouteObserver {
            NotificationCenter.default.removeObserver(audioRouteObserver)
        }
        if let audioInterruptionObserver {
            NotificationCenter.default.removeObserver(audioInterruptionObserver)
        }
        if let mediaServicesResetObserver {
            NotificationCenter.default.removeObserver(mediaServicesResetObserver)
        }
    }

    func refreshAudioInputRoute() {
        audioInputRouteText = AudioInputRouteManager.currentSnapshot().displayText
    }

    private func transitionKeyboardSession(_ event: KeyboardSessionEvent) {
        keyboardSessionState = KeyboardSessionReducer.reduce(keyboardSessionState, event: event)
    }

    private func transitionMeetingLifecycle(_ event: MeetingLifecycleEvent) {
        meetingLifecycleState = MeetingLifecycleReducer.reduce(meetingLifecycleState, event: event)
    }

    private func transitionVoiceNoteLifecycle(_ event: VoiceNoteLifecycleEvent) -> Bool {
        let previousState = voiceNoteLifecycleState
        let transition = VoiceNoteLifecycleReducer.transition(previousState, event: event)
        voiceNoteLifecycleState = transition.state
        if !transition.accepted {
            AppTelemetry.failure(
                "voice_note_lifecycle_transition_rejected",
                domain: .stateMachine,
                stage: "voice_note_lifecycle",
                reason: "invalid_transition",
                parameters: [
                    "from_phase": previousState.phase.telemetryName,
                    "event": event.telemetryName,
                ]
            )
        }
        return transition.accepted
    }

    private func beginVoiceNoteLifecycle(
        sessionID: UUID,
        requestID: UUID,
        threshold: Int?
    ) -> Bool {
        voiceNoteLifecycleRunner?.cancelAll()
        voiceNoteLifecycleRunner = VoiceNoteLifecycleRunner(sessionID: sessionID, requestID: requestID)
        guard transitionVoiceNoteLifecycle(.recordingStarted(sessionID)) else {
            voiceNoteLifecycleRunner = nil
            return false
        }
        longVoiceNoteCheckpointCount = 0
        longVoiceNoteAudioIsSecured = false
        longVoiceNoteDurabilityError = nil

        guard let threshold else { return true }
        let recordingScheduleTask = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            let startedAt = clock.now
            var schedule = VoiceNoteRecordingSchedule(thresholdSeconds: threshold)
            while !Task.isCancelled {
                let deadline = startedAt.advanced(by: .seconds(schedule.nextDeadlineSeconds))
                do {
                    try await clock.sleep(until: deadline)
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                for event in schedule.consumeNextDeadline() {
                    guard !Task.isCancelled,
                          self.voiceNoteLifecycleRunner?.sessionID == sessionID,
                          self.isRecording
                    else { return }
                    switch event {
                    case .checkpoint:
                        await self.rotateActiveVoiceNoteCheckpoint(sessionID: sessionID)
                    case .activateLongForm:
                        await self.activateLongVoiceNote(sessionID: sessionID)
                    }
                }
            }
        }
        voiceNoteLifecycleRunner?.recordingScheduleTask = recordingScheduleTask
        return true
    }

    private func stopVoiceNoteRecordingTasks(sessionID: UUID) {
        guard voiceNoteLifecycleRunner?.sessionID == sessionID else { return }
        voiceNoteLifecycleRunner?.recordingScheduleTask?.cancel()
        voiceNoteLifecycleRunner?.recordingScheduleTask = nil
    }

    private func finishVoiceNoteLifecycle(sessionID: UUID) {
        guard voiceNoteLifecycleRunner?.sessionID == sessionID else { return }
        if voiceNoteLifecycleState.activeSessionID == sessionID {
            guard transitionVoiceNoteLifecycle(.finished(sessionID)) else { return }
        } else if voiceNoteLifecycleState.activeSessionID != nil {
            return
        }
        voiceNoteLifecycleRunner?.cancelAll()
        voiceNoteLifecycleRunner = nil
        longVoiceNoteCheckpointCount = 0
        longVoiceNoteAudioIsSecured = false
        longVoiceNoteDurabilityError = nil
    }

    private var voiceNoteRequestOwnership: VoiceNoteRequestOwnership {
        VoiceNoteRequestOwnership(
            requestID: voiceNoteLifecycleRunner?.requestID
                ?? activeSession?.requestID
                ?? activeRequest?.id,
            isWorkActive: voiceNoteLifecycleState.isWorkActive
                || isRecording
                || activeRequest != nil
        )
    }

    private func isCurrentVoiceNoteLifecycle(
        sessionID: UUID,
        requestID: UUID,
        runnerID: UUID
    ) -> Bool {
        voiceNoteLifecycleRunner?.id == runnerID
            && voiceNoteLifecycleRunner?.sessionID == sessionID
            && voiceNoteLifecycleRunner?.requestID == requestID
            && voiceNoteLifecycleState.activeSessionID == sessionID
    }

    @discardableResult
    private func rejectConflictingKeyboardCommand(
        requestID: UUID,
        action: DictationCommandAction
    ) -> Bool {
        let hasMeetingConflict = hasMeetingRecordingInProgress
        let hasVoiceNoteConflict = !voiceNoteRequestOwnership.accepts(requestID: requestID)
        guard hasMeetingConflict || hasVoiceNoteConflict else { return false }

        let message = hasMeetingConflict
            ? "Finish the active meeting first"
            : "Finish the active voice note first"
        saveKeyboardHandoff(requestID: requestID, phase: .failed, message: message)
        if let pendingRequest = try? store.pendingRequest(), pendingRequest.id == requestID {
            try? store.clearPendingRequest()
        }
        saveKeyboardRuntimeStatus(
            isActive: false,
            activeRequestID: nil,
            phase: .failed,
            message: message
        )
        AppTelemetry.failure(
            "keyboard_dictation_rejected",
            domain: .keyboardSession,
            stage: "voice_note_ownership",
            reason: hasMeetingConflict ? "active_meeting" : "active_voice_note",
            parameters: ["action": action.rawValue]
        )
        return true
    }

    private func voiceNoteFailureReason(for error: Error) -> VoiceNoteTranscriptionFailureReason {
        if let captureFailure = error as? VoiceNoteCaptureFailure {
            return captureFailure.failureReason
        }
        if error is VoiceNoteCheckpointStore.StoreError {
            return .checkpointFailure
        }
        if error is VoiceNoteRetryError {
            return .timeout
        }
        return .engineFailure
    }

    private func hasRecoverableAudio(for session: RecordingSession) async -> Bool {
        if session.hasDurableAudioCheckpoint {
            return true
        }
        guard let audioFileName = session.audioFileName,
              let audioURL = try? store.audioFileURL(fileName: audioFileName)
        else { return false }
        return await voiceNoteCheckpointStore.isReadableAudio(at: audioURL)
    }

    private func persistVoiceNoteFailure(
        _ session: RecordingSession,
        reason: VoiceNoteTranscriptionFailureReason,
        message: String,
        unavailableAudioMessage: String? = nil
    ) async -> RecordingSession {
        let audioIsRecoverable = session.isLongForm
            ? await hasRecoverableAudio(for: session)
            : false
        let resolvedMessage = session.isLongForm && !audioIsRecoverable
            ? unavailableAudioMessage ?? message
            : message
        var failedSession = VoiceNoteFailureSessionPolicy.prepare(
            session,
            reason: reason,
            message: resolvedMessage,
            hasRecoverableAudio: audioIsRecoverable
        )
        cleanupNonRetainedAudio(for: &failedSession)
        try? store.saveSession(failedSession)
        settleVoiceNoteLifecycleAfterFailure(failedSession)
        return failedSession
    }

    private func settleVoiceNoteLifecycleAfterFailure(_ session: RecordingSession) {
        if VoiceNoteCheckpointRetentionPolicy.shouldDeleteCheckpoints(for: session) {
            let checkpointStore = voiceNoteCheckpointStore
            Task {
                try? await checkpointStore.delete(sessionID: session.id)
            }
        }
        switch VoiceNoteFailureLifecycleDisposition.resolve(for: session) {
        case .retryable:
            if case .failedRetryable(let activeID) = voiceNoteLifecycleState.phase,
               activeID == session.id {
                return
            }
            guard transitionVoiceNoteLifecycle(.transcriptionFailed(session.id)) else { return }
        case .finished:
            finishVoiceNoteLifecycle(sessionID: session.id)
        }
    }

    private func rotateActiveVoiceNoteCheckpoint(sessionID: UUID) async {
        guard let runner = voiceNoteLifecycleRunner,
              runner.sessionID == sessionID,
              activeSession?.id == sessionID,
              activeSession?.longFormThresholdSeconds != nil,
              isRecording
        else { return }

        let checkpoint = keyboardSessionKeeper.rotateSegmentCheckpoint()
            ?? realtimeDictationRecorder?.rotateChunk()
        guard let checkpoint else { return }

        do {
            let manifest = try await voiceNoteCheckpointStore.record(checkpoint, sessionID: sessionID)
            guard isCurrentVoiceNoteLifecycle(
                sessionID: sessionID,
                requestID: runner.requestID,
                runnerID: runner.id
            ),
            voiceNoteLifecycleState.isRecording,
            isRecording,
            var securedSession = activeSession,
            securedSession.id == sessionID
            else { return }
            longVoiceNoteCheckpointCount = manifest.entries.count
            longVoiceNoteAudioIsSecured = !manifest.entries.isEmpty
            if longVoiceNoteAudioIsSecured {
                securedSession.hasDurableAudioCheckpoint = true
                activeSession = securedSession
                try? store.saveSession(securedSession)
            }
        } catch {
            handleVoiceNoteWriterFailure(.checkpointWrite)
        }
    }

    private func activateLongVoiceNote(sessionID: UUID) async {
        guard let runner = voiceNoteLifecycleRunner,
              runner.sessionID == sessionID,
              case .recordingShort(let initialStateSessionID) = voiceNoteLifecycleState.phase,
              initialStateSessionID == sessionID,
              isRecording
        else { return }

        guard isCurrentVoiceNoteLifecycle(
            sessionID: sessionID,
            requestID: runner.requestID,
            runnerID: runner.id
        ),
        case .recordingShort(let currentStateSessionID) = voiceNoteLifecycleState.phase,
        currentStateSessionID == sessionID,
        isRecording,
        var session = activeSession,
        session.id == sessionID
        else { return }

        guard longVoiceNoteAudioIsSecured,
              session.hasDurableAudioCheckpoint
        else {
            handleVoiceNoteWriterFailure(.checkpointRotation)
            return
        }
        guard transitionVoiceNoteLifecycle(.longFormActivated(sessionID)) else { return }

        session.isLongForm = true
        session.longFormActivatedAt = .now
        session.protectedAudioUntilTranscriptCompletes = true
        session.lastTranscriptionFailureReason = nil
        activeSession = session
        if session.kind == .quickDictation {
            presentedLongVoiceNoteSessionID = session.id
        }
        try? store.saveSession(session)
        statusText = "Audio saved locally"

        if longVoiceNoteAudioIsSecured {
            var parameters = voiceNoteTelemetryParameters(
                session: session,
                checkpointCount: longVoiceNoteCheckpointCount
            )
            parameters["checkpoint_kind"] = "first_protected"
            AppTelemetry.contextualSignal(
                "long_voice_note_audio_checkpoint_saved",
                parameters: parameters
            )
        }

        AppTelemetry.contextualSignal(
            "long_voice_note_activated",
            parameters: voiceNoteTelemetryParameters(
                session: session,
                checkpointCount: longVoiceNoteCheckpointCount
            )
        )
        if session.kind == .keyboardDictation {
            refreshKeyboardSessionLiveActivity(
                phase: "Long voice note",
                detail: longVoiceNoteAudioIsSecured ? "Audio protected locally" : "Securing audio"
            )
        } else {
            Task {
                await liveActivityController.update(
                    phase: "Long voice note",
                    detail: longVoiceNoteAudioIsSecured ? "Audio protected locally" : "Securing audio",
                    session: session
                )
            }
        }
    }

    private func handleVoiceNoteWriterFailure(_ failure: CheckpointingAudioWriterFailure) {
        guard isRecording, var session = activeSession, session.kind != .meeting else { return }
        if failure == .continuousWrite {
            longVoiceNoteAudioIsSecured = session.hasDurableAudioCheckpoint
        } else {
            longVoiceNoteAudioIsSecured = false
            session.hasDurableAudioCheckpoint = false
        }
        longVoiceNoteDurabilityError = "Audio could not be saved reliably. The recording was stopped."
        activeSession = session
        AppTelemetry.failure(
            "long_voice_note_checkpoint_failed",
            domain: .audio,
            stage: "checkpoint_write",
            reason: String(describing: failure),
            parameters: voiceNoteTelemetryParameters(
                session: session,
                checkpointCount: longVoiceNoteCheckpointCount
            )
        )
        handleVoiceNoteRecordingInterruption(
            message: longVoiceNoteDurabilityError ?? "Audio save failed",
            cause: .checkpointFailure
        )
    }

    private func handleAudioSessionInterruption() {
        handleVoiceNoteRecordingInterruption(
            message: "Recording was interrupted by the system",
            cause: .interrupted
        )
    }

    private func handleVoiceNoteRecordingInterruption(
        message: String,
        cause: VoiceNoteRecordingTerminationCause
    ) {
        guard isRecording,
              var session = activeSession,
              session.kind != .meeting,
              let requestID = session.requestID
        else { return }

        if let threshold = session.longFormThresholdSeconds,
           recordingElapsedTime >= Double(threshold) {
            session.isLongForm = true
            session.longFormActivatedAt = session.longFormActivatedAt ?? .now
            session.protectedAudioUntilTranscriptCompletes = session.hasDurableAudioCheckpoint
        }
        session.lastTranscriptionFailureReason = cause.failureReason
        session.errorMessage = message
        activeSession = session
        try? store.saveSession(session)
        stopRecording(requestID: requestID)
    }

    func recoverLongVoiceNotesIfNeeded() {
        Task { @MainActor in
            await recoverLongVoiceNotesOnLaunch()
        }
    }

    func dismissLongVoiceNote() {
        guard !isRecording || activeSession?.id != presentedLongVoiceNoteSessionID else { return }
        presentedLongVoiceNoteSessionID = nil
    }

    func openLongVoiceNote(_ session: RecordingSession) {
        guard session.kind != .meeting, session.isLongForm else { return }
        presentedLongVoiceNoteSessionID = session.id
    }

    func openLongVoiceNoteSettings() {
        inputSettingsNavigationRequestID = UUID()
        settingsNavigationRequestID = UUID()
    }

    private func recoverLongVoiceNotesOnLaunch() async {
        let sessions = (try? store.recordingSessions()) ?? []
        let sessionsByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        let validIDs = Set(sessions.map(\.id))
        if let checkpointIDs = try? await voiceNoteCheckpointStore.checkpointSessionIDs() {
            for sessionID in checkpointIDs {
                let session = sessionsByID[sessionID]
                if !validIDs.contains(sessionID)
                    || VoiceNoteCheckpointRetentionPolicy.shouldDeleteCheckpoints(for: session) {
                    try? await voiceNoteCheckpointStore.delete(sessionID: sessionID)
                }
            }
        }

        var didChange = false
        for original in sessions where original.kind != .meeting {
            if original.audioFileName == nil,
               !original.protectedAudioUntilTranscriptCompletes {
                continue
            }
            let isCheckpointArmedRecording = original.phase == .recording
                && original.longFormThresholdSeconds != nil
            guard original.isLongForm || isCheckpointArmedRecording else { continue }
            guard [.recording, .transcriptionQueued, .transcribing, .failed].contains(original.phase),
                  voiceNoteLifecycleRunner?.sessionID != original.id
            else { continue }

            var session = original
            if isCheckpointArmedRecording {
                session.isLongForm = true
                session.longFormActivatedAt = session.longFormActivatedAt ?? .now
            }
            let recoveredManifest = try? await voiceNoteCheckpointStore.salvageTrailingCheckpoint(
                sessionID: session.id
            )
            session.hasDurableAudioCheckpoint = !(recoveredManifest?.entries.isEmpty ?? true)
            if session.phase == .recording || session.phase == .transcribing {
                session.phase = .failed
                session.lastTranscriptionFailureReason = .interrupted
                session.errorMessage = "Your audio is safe. Transcription needs to be retried."
            }

            var hasAudio = false
            if let fileName = session.audioFileName,
               let audioURL = try? store.audioFileURL(fileName: fileName) {
                hasAudio = await voiceNoteCheckpointStore.isReadableAudio(at: audioURL)
                if !hasAudio,
                   (try? await voiceNoteCheckpointStore.reconstructAudio(
                       sessionID: session.id,
                       destinationURL: audioURL
                   )) != nil {
                    hasAudio = true
                }
            }

            if hasAudio {
                session.phase = .failed
                session.protectedAudioUntilTranscriptCompletes = true
                session.errorMessage = "Your audio is safe. We couldn't finish transcribing this note."
                AppTelemetry.contextualSignal(
                    "long_voice_note_recovered_on_launch",
                    parameters: voiceNoteTelemetryParameters(session: session)
                )
            } else {
                session.phase = .failed
                session.protectedAudioUntilTranscriptCompletes = false
                session.hasDurableAudioCheckpoint = false
                session.lastTranscriptionFailureReason = .audioUnavailable
                session.errorMessage = "The saved audio is unavailable."
                session.audioFileName = nil
            }
            try? store.saveSession(session)
            didChange = true
        }
        if didChange {
            refreshHistory()
        }
    }

    private func voiceNoteTelemetryParameters(
        session: RecordingSession?,
        checkpointCount: Int? = nil
    ) -> [String: String] {
        guard let session else { return [:] }
        let duration = max(0, session.duration ?? recordingElapsedTime)
        let durationBucket: String
        switch duration {
        case ..<60: durationBucket = "under_60"
        case ..<120: durationBucket = "60_119"
        case ..<300: durationBucket = "120_299"
        case ..<600: durationBucket = "300_599"
        default: durationBucket = "600_plus"
        }
        var parameters = [
            "source": session.kind == .keyboardDictation ? "keyboard" : "in_app",
            "duration_bucket": durationBucket,
            "threshold_seconds": "\(session.longFormThresholdSeconds ?? 0)",
            "threshold_bucket": thresholdTelemetryBucket(session.longFormThresholdSeconds),
            "engine": session.engineIdentifier ?? selectedTranscriptionModel.engineIdentifier,
            "retry_count": "\(session.transcriptionRetryCount)",
            "timeout": session.lastTranscriptionFailureReason == .timeout ? "true" : "false",
        ]
        if let checkpointCount {
            parameters["checkpoint_count"] = "\(checkpointCount)"
        }
        return parameters
    }

    private func thresholdTelemetryBucket(_ threshold: Int?) -> String {
        switch threshold ?? 0 {
        case ...30: "30"
        case ...60: "31_60"
        case ...120: "61_120"
        case ...300: "121_300"
        default: "301_600"
        }
    }

    private func configuredLongVoiceNoteThreshold() -> Int? {
        guard MuesliPreferences.longVoiceNoteModeEnabled else { return nil }
        #if DEBUG
        let prefix = "--muesli-long-note-threshold-seconds="
        if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) }),
           let injected = Int(argument.dropFirst(prefix.count)),
           (1...600).contains(injected) {
            return injected
        }
        #endif
        return MuesliPreferences.longVoiceNoteThresholdSeconds
    }

    private func beginMeetingLifecycle(sessionID: UUID, event: MeetingLifecycleEvent) {
        meetingLifecycleRunner?.cancelAll()
        meetingLifecycleRunner = MeetingLifecycleRunner(sessionID: sessionID)
        transitionMeetingLifecycle(event)
    }

    private func setMeetingStartupTask(_ task: Task<Void, Never>, sessionID: UUID) {
        guard meetingLifecycleRunner?.sessionID == sessionID else {
            task.cancel()
            return
        }
        meetingLifecycleRunner?.startupTask = task
    }

    private func setMeetingFinalizationTask(_ task: Task<Void, Never>, sessionID: UUID) {
        guard meetingLifecycleRunner?.sessionID == sessionID else {
            task.cancel()
            return
        }
        meetingLifecycleRunner?.finalizationTask = task
    }

    private func cancelMeetingLifecycle(sessionID: UUID) {
        guard meetingLifecycleRunner?.sessionID == sessionID || meetingLifecycleState.activeSessionID == sessionID else {
            return
        }
        meetingLifecycleRunner?.cancelAll()
        transitionMeetingLifecycle(.cancelRequested(sessionID))
    }

    private func finishMeetingLifecycle(sessionID: UUID) {
        guard meetingLifecycleRunner?.sessionID == sessionID || meetingLifecycleState.activeSessionID == sessionID else {
            return
        }
        meetingLifecycleRunner = nil
        transitionMeetingLifecycle(.finished(sessionID))
    }

    private func isCurrentMeetingLifecycle(sessionID: UUID) -> Bool {
        meetingLifecycleState.activeSessionID == sessionID
            && !meetingLifecycleState.isCancelling
            && meetingLifecycleRunner?.sessionID == sessionID
    }

    private func ensureMeetingLifecycleActive(sessionID: UUID) throws {
        try Task.checkCancellation()
        guard isCurrentMeetingLifecycle(sessionID: sessionID) else {
            throw CancellationError()
        }
    }

    func handleOpenURL(_ url: URL) {
        #if DEBUG
        if handleDebugURL(url) {
            return
        }
        #endif

        if handleSyncBridgeURL(url) {
            return
        }

        if handleSettingsURL(url) {
            return
        }

        guard url.scheme == MuesliAppConstants.urlScheme,
              url.host == MuesliAppConstants.dictateHost,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let value = components.queryItems?.first(where: { $0.name == MuesliAppConstants.requestQueryItem })?.value,
              let requestID = UUID(uuidString: value)
        else { return }

        let action = components.queryItems?.first(where: { $0.name == MuesliAppConstants.actionQueryItem })?.value
            ?? MuesliAppConstants.startAction
        if action == MuesliAppConstants.stopAction {
            guard !rejectConflictingKeyboardCommand(requestID: requestID, action: .stop) else { return }
            saveKeyboardHandoff(
                requestID: requestID,
                phase: .stopAcknowledged,
                message: "Stopping"
            )
            stopRecording(requestID: requestID)
            return
        }

        guard !rejectConflictingKeyboardCommand(requestID: requestID, action: .start) else { return }

        let pendingRequest = try? store.pendingRequest()
        let request = pendingRequest?.id == requestID
            ? pendingRequest!
            : DictationRequest(id: requestID)
        if refreshActiveKeyboardRequestIfNeeded(request) {
            return
        }
        if recoverKeyboardRequestIfNeeded(request) {
            return
        }
        transitionKeyboardSession(.handoffStarted(request.id))
        startKeyboardRuntimePolling()
        startRecording(for: request, source: "keyboard")
    }

    func requestSyncSetup(source: String) {
        syncSetupSource = source
        syncSetupRequestID = UUID()
    }

    func consumeSyncSetupRequest() -> (id: UUID, source: String)? {
        guard let requestID = syncSetupRequestID else { return nil }
        let source = syncSetupSource ?? "unknown"
        syncSetupRequestID = nil
        syncSetupSource = nil
        return (requestID, source)
    }

    private func refreshActiveKeyboardRequestIfNeeded(_ request: DictationRequest) -> Bool {
        guard activeRequest?.id == request.id else { return false }

        transitionKeyboardSession(.handoffStarted(request.id))
        startKeyboardRuntimePolling()

        if isRecording {
            transitionKeyboardSession(.recordingStarted(request.id))
            saveKeyboardHandoff(
                requestID: request.id,
                phase: .recordingStarted,
                message: "Listening"
            )
            saveKeyboardRuntimeStatus(
                isActive: true,
                activeRequestID: request.id,
                phase: .recording,
                message: "Listening",
                supportsBackgroundStart: canStartKeyboardRequestsInBackground
            )
            return true
        }

        if statusText == "Transcribing" || activeSession?.requestID == request.id {
            transitionKeyboardSession(.transcribing(request.id))
            try? store.saveStatus(.init(
                requestID: request.id,
                phase: .transcribing,
                message: "Transcribing"
            ))
            saveKeyboardHandoff(
                requestID: request.id,
                phase: .transcribingStarted,
                message: "Transcribing"
            )
            saveKeyboardRuntimeStatus(
                isActive: true,
                activeRequestID: request.id,
                phase: .transcribing,
                message: "Transcribing",
                supportsBackgroundStart: canStartKeyboardRequestsInBackground
            )
            return true
        }

        saveKeyboardHandoff(
            requestID: request.id,
            phase: .startAcknowledged,
            message: "Starting"
        )
        saveKeyboardRuntimeStatus(
            isActive: true,
            activeRequestID: request.id,
            phase: .requested,
            message: "Starting",
            supportsBackgroundStart: canStartKeyboardRequestsInBackground
        )
        return true
    }

    private func recoverKeyboardRequestIfNeeded(_ request: DictationRequest) -> Bool {
        guard let status = try? store.status(),
              status.requestID == request.id,
              [.recording, .transcribing].contains(status.phase),
              activeRequest == nil,
              !isRecording
        else {
            return false
        }

        guard let session = try? store.recordingSession(requestID: request.id),
              let audioFileName = session.audioFileName,
              let audioURL = try? store.audioFileURL(fileName: audioFileName),
              FileManager.default.fileExists(atPath: audioURL.path)
        else {
            let message = "Recording was interrupted. Start a new voice note."
            try? store.saveStatus(.init(requestID: request.id, phase: .failed, message: message))
            saveKeyboardHandoff(requestID: request.id, phase: .failed, message: message)
            statusText = message
            return true
        }

        transitionKeyboardSession(.transcribing(request.id))
        activeRequest = request
        activeSession = session
        voiceNoteLifecycleRunner?.cancelAll()
        voiceNoteLifecycleState = VoiceNoteLifecycleState()
        voiceNoteLifecycleRunner = VoiceNoteLifecycleRunner(
            sessionID: session.id,
            requestID: request.id
        )
        guard let lifecycleRunnerID = voiceNoteLifecycleRunner?.id,
              transitionVoiceNoteLifecycle(.retryRequested(session.id)),
              transitionVoiceNoteLifecycle(.transcriptionStarted(session.id))
        else {
            voiceNoteLifecycleRunner?.cancelAll()
            voiceNoteLifecycleRunner = nil
            voiceNoteLifecycleState = VoiceNoteLifecycleState()
            activeRequest = nil
            activeSession = nil
            return true
        }
        statusText = "Transcribing"
        try? store.saveStatus(.init(requestID: request.id, phase: .transcribing, message: "Recovering transcription"))
        saveKeyboardHandoff(
            requestID: request.id,
            phase: .transcribingStarted,
            message: "Recovering transcription"
        )
        saveKeyboardRuntimeStatus(
            isActive: true,
            activeRequestID: request.id,
            phase: .transcribing,
            message: "Recovering transcription",
            supportsBackgroundStart: canStartKeyboardRequestsInBackground
        )
        recoverKeyboardTranscription(
            request: request,
            session: session,
            audioURL: audioURL,
            lifecycleRunnerID: lifecycleRunnerID
        )
        return true
    }

    #if DEBUG
    private func handleDebugURL(_ url: URL) -> Bool {
        guard url.scheme == MuesliAppConstants.urlScheme,
              url.host == MuesliAppConstants.debugHost,
              url.path == MuesliAppConstants.resetOnboardingPath
        else { return false }

        resetOnboardingForTesting()
        return true
    }

    func resetOnboardingForTesting() {
        OnboardingPreferenceKeys.clear()
        hasCompletedOnboarding = false
        onboardingTestTranscript = ""
        onboardingTestError = nil
        isOnboardingTestRecording = false
        isOnboardingTestTranscribing = false
        UserDefaults.standard.set(false, forKey: Self.onboardingCompletedKey)
        AppTelemetry.signal("debug_onboarding_reset")
    }

    private static func shouldResetOnboardingFromLaunchArguments() -> Bool {
        ProcessInfo.processInfo.arguments.contains(MuesliAppConstants.resetOnboardingLaunchArgument)
    }

    private static func shouldConfigureForUITestingFromLaunchArguments() -> Bool {
        ProcessInfo.processInfo.arguments.contains(MuesliAppConstants.uiTestingLaunchArgument)
    }

    private static func shouldSkipModelPrewarmForTesting() -> Bool {
        shouldConfigureForUITestingFromLaunchArguments()
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private func configureForUITesting() {
        OnboardingPreferenceKeys.clear()
        hasCompletedOnboarding = true
        userName = "UI Tests"
        selectedUseCase = .everything
        selectedTranscriptionModel = .defaultModel
        transitionKeyboardSession(.stop(.off))
        UserDefaults.standard.set(true, forKey: Self.onboardingCompletedKey)
        UserDefaults.standard.set(userName, forKey: Self.userNameKey)
        UserDefaults.standard.set(selectedUseCase.rawValue, forKey: Self.useCaseKey)
        UserDefaults.standard.set(AppSection.defaultPinnedStorage, forKey: MuesliPreferences.pinnedSectionsKey)
        UserDefaults.standard.set(true, forKey: MuesliPreferences.longVoiceNoteModeEnabledKey)
        UserDefaults.standard.set(60, forKey: MuesliPreferences.longVoiceNoteThresholdSecondsKey)
        modelPreparation = ModelPreparationState(
            phase: .ready,
            progress: 1,
            status: "\(selectedTranscriptionModel.shortName) ready",
            detail: "UI testing"
        )

        if ProcessInfo.processInfo.arguments.contains(MuesliAppConstants.completedLongVoiceNoteUITestLaunchArgument) {
            configureCompletedLongVoiceNoteUITestFixture()
        } else if ProcessInfo.processInfo.arguments.contains(MuesliAppConstants.longVoiceNoteUITestLaunchArgument) {
            configureLongVoiceNoteUITestFixture()
        }
    }

    private func configureLongVoiceNoteUITestFixture() {
        let request = DictationRequest()
        let session = RecordingSession(
            requestID: request.id,
            kind: .quickDictation,
            startedAt: Date.now.addingTimeInterval(-61),
            phase: .recording,
            source: "app",
            isLongForm: true,
            longFormActivatedAt: .now,
            longFormThresholdSeconds: 60,
            protectedAudioUntilTranscriptCompletes: true
        )

        activeRequest = request
        activeSession = session
        recordingSessions = [session]
        isRecording = true
        recordingElapsedTime = 61
        longVoiceNoteCheckpointCount = 2
        longVoiceNoteAudioIsSecured = true
        voiceNoteLifecycleRunner = VoiceNoteLifecycleRunner(
            sessionID: session.id,
            requestID: request.id
        )
        voiceNoteLifecycleState = VoiceNoteLifecycleReducer.reduce(
            voiceNoteLifecycleState,
            event: .recordingStarted(session.id)
        )
        voiceNoteLifecycleState = VoiceNoteLifecycleReducer.reduce(
            voiceNoteLifecycleState,
            event: .longFormActivated(session.id)
        )
        presentedLongVoiceNoteSessionID = session.id
        statusText = "Audio saved locally"
    }

    private func configureCompletedLongVoiceNoteUITestFixture() {
        let request = DictationRequest()
        let session = RecordingSession(
            requestID: request.id,
            kind: .quickDictation,
            startedAt: Date.now.addingTimeInterval(-62),
            endedAt: .now,
            phase: .completed,
            source: "app",
            isLongForm: true,
            longFormActivatedAt: Date.now.addingTimeInterval(-32),
            longFormThresholdSeconds: 30
        )
        let transcript = Transcript(
            sessionID: session.id,
            text: "Completed long voice note transcript.",
            engineIdentifier: selectedTranscriptionModel.engineIdentifier
        )

        recordingSessions = [session]
        cacheTranscript(transcript)
        presentedLongVoiceNoteSessionID = session.id
        statusText = "Ready"
    }
    #endif

    private func handleSyncBridgeURL(_ url: URL) -> Bool {
        guard url.scheme == MuesliAppConstants.urlScheme,
              url.host == MuesliAppConstants.syncHost
        else { return false }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let source = components?.queryItems?.first(where: { $0.name == MuesliAppConstants.sourceQueryItem })?.value
            ?? "deeplink"

        if MuesliPreferences.iCloudSyncEnabled {
            syncSetupSource = source
            iCloudSyncStatusText = "Already syncing with your Mac through private iCloud."
            AppTelemetry.signal("bridge_enable_completed", parameters: ["platform": "ios", "source": source, "already_enabled": "true"])
            syncICloudTextIfEnabled(reason: "bridge_qr_existing")
            return true
        }

        syncSetupSource = source
        syncSetupRequestID = UUID()
        iCloudSyncStatusText = "Continue setup with private iCloud sync."
        AppTelemetry.signal("ios_bridge_deeplink_opened", parameters: ["source": source])
        return true
    }

    private func handleSettingsURL(_ url: URL) -> Bool {
        guard url.scheme == MuesliAppConstants.urlScheme,
              url.host == MuesliAppConstants.settingsHost
        else { return false }

        settingsNavigationRequestID = UUID()
        return true
    }

    func toggleRecording() {
        if isRecording {
            MuesliHaptics.dictationStop()
            stopRecording()
        } else if statusText != "Transcribing" {
            MuesliHaptics.dictationStart()
            startRecording(for: DictationRequest(), source: "app")
        }
    }

    func cancelActiveRecording() {
        guard let request = activeRequest else { return }
        let source = isKeyboardHandoffActive ? "keyboard" : "app"
        MuesliHaptics.dictationStop()
        cancelRecording(requestID: request.id)
        AppTelemetry.signal("dictation_cancelled", parameters: ["source": source])
    }

    func refreshHistory() {
        do {
            dictationHistory = try store.resultsHistory()
            recordingSessions = try store.recordingSessions()
            transcriptCache = transcriptsBySessionID(try store.transcripts())
            lastTranscript = dictationHistory.first?.text ?? lastTranscript
        } catch {
            statusText = error.localizedDescription
        }
    }

    private func transcriptsBySessionID(_ transcripts: [Transcript]) -> [UUID: Transcript] {
        transcripts.reduce(into: [:]) { cache, transcript in
            cache[transcript.sessionID] = transcript
        }
    }

    private func cacheTranscript(_ transcript: Transcript) {
        transcriptCache[transcript.sessionID] = transcript
    }

    private func removeCachedTranscript(for sessionID: UUID) {
        transcriptCache.removeValue(forKey: sessionID)
    }

    private func postProcessTranscript(_ text: String) -> String {
        TranscriptPostProcessor(store: store).process(text)
    }

    func copyToClipboard(_ result: DictationResult) {
        UIPasteboard.general.string = result.text
        clipboardStatusText = "Copied"
        AppTelemetry.signal("dictation_copied")

        clearClipboardStatusSoon()
    }

    func deleteDictation(_ result: DictationResult) {
        do {
            if let session = recordingSession(for: result) {
                if let audioFileName = session.audioFileName {
                    try? store.deleteAudioFile(fileName: audioFileName)
                }
                try? store.deleteTranscript(for: session.id)
                removeCachedTranscript(for: session.id)
                try? store.deleteRecordingSession(id: session.id)
                recordingSessions.removeAll { $0.id == session.id }
                if session.longFormThresholdSeconds != nil {
                    Task {
                        try? await voiceNoteCheckpointStore.delete(sessionID: session.id)
                    }
                }
            }
            try store.deleteResult(result)
            dictationHistory.removeAll { $0.id == result.id || $0.requestID == result.requestID }
            if lastTranscript == result.text {
                lastTranscript = dictationHistory.first?.text ?? ""
            }
            clipboardStatusText = "Deleted"
            AppTelemetry.signal("dictation_deleted")
            clearClipboardStatusSoon()
            scheduleICloudSyncAfterLocalChange(reason: "dictation_deleted")
        } catch {
            clipboardStatusText = "Delete failed"
            clearClipboardStatusSoon()
        }
    }

    @discardableResult
    func deleteDictationAudio(for result: DictationResult) -> Bool {
        do {
            guard let sessionID = result.sessionID,
                  var session = try store.activeRecordingSession(id: sessionID),
                  let audioFileName = session.audioFileName
            else {
                clipboardStatusText = "Audio already removed"
                clearClipboardStatusSoon()
                return true
            }

            try store.deleteAudioFile(fileName: audioFileName)
            session.audioFileName = nil
            session.keepsAudioRecording = false
            session.protectedAudioUntilTranscriptCompletes = false
            session.hasDurableAudioCheckpoint = false
            session.lastTranscriptionFailureReason = .audioUnavailable
            try store.saveSession(session)
            if session.longFormThresholdSeconds != nil {
                Task {
                    try? await voiceNoteCheckpointStore.delete(sessionID: session.id)
                }
            }

            if let index = recordingSessions.firstIndex(where: { $0.id == session.id }) {
                recordingSessions[index] = session
            }

            clipboardStatusText = "Audio deleted"
            AppTelemetry.signal("dictation_audio_deleted")
            clearClipboardStatusSoon()
            return true
        } catch {
            clipboardStatusText = "Audio delete failed"
            clearClipboardStatusSoon()
            return false
        }
    }

    func updateVoiceNoteScratchpad(sessionID: UUID, text: String) {
        do {
            guard var session = try store.activeRecordingSession(id: sessionID),
                  session.kind != .meeting
            else { return }
            session.scratchpadText = text
            try store.saveSession(session)
            if activeSession?.id == sessionID {
                activeSession = session
            }
            if let index = recordingSessions.firstIndex(where: { $0.id == sessionID }) {
                recordingSessions[index] = session
            }
        } catch {
            clipboardStatusText = "Notes save failed"
            clearClipboardStatusSoon()
        }
    }

    func keepVoiceNoteAudio(sessionID: UUID) {
        guard var session = try? store.activeRecordingSession(id: sessionID),
              session.kind != .meeting,
              session.audioFileName != nil
        else { return }
        session.keepsAudioRecording = true
        try? store.saveSession(session)
        if let index = recordingSessions.firstIndex(where: { $0.id == sessionID }) {
            recordingSessions[index] = session
        }
        clipboardStatusText = "Audio kept"
        clearClipboardStatusSoon()
    }

    func deleteVoiceNoteAudio(sessionID: UUID) {
        var primaryDeletionSucceeded = false
        do {
            if var session = try store.activeRecordingSession(id: sessionID),
               session.kind != .meeting {
                if let audioFileName = session.audioFileName {
                    try store.deleteAudioFile(fileName: audioFileName)
                }
                session.audioFileName = nil
                session.keepsAudioRecording = false
                session.protectedAudioUntilTranscriptCompletes = false
                session.hasDurableAudioCheckpoint = false
                session.lastTranscriptionFailureReason = .audioUnavailable
                session.errorMessage = "The saved audio was deleted."
                try store.saveSession(session)
                if let index = recordingSessions.firstIndex(where: { $0.id == sessionID }) {
                    recordingSessions[index] = session
                }
                primaryDeletionSucceeded = true
            }
        } catch {
            AppTelemetry.failure(
                "long_voice_note_audio_delete_failed",
                domain: .audio,
                stage: "continuous_audio_delete",
                error: error
            )
        }

        clipboardStatusText = primaryDeletionSucceeded ? "Deleting audio" : "Audio delete incomplete"
        let didDeletePrimaryAudio = primaryDeletionSucceeded
        let checkpointStore = voiceNoteCheckpointStore
        Task { @MainActor [weak self] in
            do {
                try await checkpointStore.delete(sessionID: sessionID)
                self?.clipboardStatusText = didDeletePrimaryAudio
                    ? "Audio deleted"
                    : "Audio delete incomplete"
            } catch {
                self?.clipboardStatusText = didDeletePrimaryAudio
                    ? "Audio deletion pending"
                    : "Audio delete incomplete"
                AppTelemetry.failure(
                    "long_voice_note_audio_delete_deferred",
                    domain: .audio,
                    stage: "checkpoint_delete",
                    error: error
                )
            }
            self?.clearClipboardStatusSoon()
        }
    }

    func retryVoiceNoteTranscription(sessionID: UUID) {
        guard !isRecording,
              !hasMeetingRecordingInProgress,
              !voiceNoteLifecycleState.isWorkActive,
              statusText != "Transcribing",
              var session = try? store.activeRecordingSession(id: sessionID),
              session.canRetryVoiceNoteTranscription,
              let requestID = session.requestID,
              let audioFileName = session.audioFileName,
              let audioURL = try? store.audioFileURL(fileName: audioFileName)
        else { return }

        voiceNoteLifecycleRunner?.cancelAll()
        voiceNoteLifecycleState = VoiceNoteLifecycleState()
        voiceNoteLifecycleRunner = VoiceNoteLifecycleRunner(
            sessionID: sessionID,
            requestID: requestID
        )
        guard let runnerID = voiceNoteLifecycleRunner?.id else { return }
        guard transitionVoiceNoteLifecycle(.retryRequested(sessionID)) else {
            voiceNoteLifecycleRunner?.cancelAll()
            voiceNoteLifecycleRunner = nil
            return
        }
        session.phase = .transcriptionQueued
        session.transcriptionRetryCount += 1
        session.lastTranscriptionAttemptAt = .now
        session.errorMessage = nil
        try? store.saveSession(session)
        activeSession = session
        statusText = "Preparing audio"
        AppTelemetry.contextualSignal(
            "long_voice_note_transcription_retried",
            parameters: voiceNoteTelemetryParameters(session: session)
        )

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            beginTranscriptionBackgroundTask()
            defer { endTranscriptionBackgroundTask() }
            var session = session
            do {
                var usableURL = audioURL
                if !(await voiceNoteCheckpointStore.isReadableAudio(at: usableURL)) {
                    usableURL = try await voiceNoteCheckpointStore.reconstructAudio(
                        sessionID: sessionID,
                        destinationURL: audioURL
                    )
                }
                guard isCurrentVoiceNoteLifecycle(
                    sessionID: sessionID,
                    requestID: requestID,
                    runnerID: runnerID
                ) else {
                    return
                }

                guard transitionVoiceNoteLifecycle(.transcriptionStarted(sessionID)) else {
                    return
                }
                session.phase = .transcribing
                try store.saveSession(session)
                activeSession = session
                statusText = "Transcribing"
                await engine.selectModel(selectedTranscriptionModel)
                let transcriptionURL = usableURL
                let outcome = try await runOfflineTranscriptionJob(
                    audioURL: transcriptionURL,
                    onProgress: { [weak self] update in
                        guard let self,
                              self.isCurrentVoiceNoteLifecycle(
                                  sessionID: sessionID,
                                  requestID: requestID,
                                  runnerID: runnerID
                              )
                        else { return }
                        self.statusText = self.transcriptionStatusMessage(for: update)
                    },
                    onTimeout: {}
                ) { [engine] progress in
                    try await engine.transcribe(audioURL: transcriptionURL, progress: progress)
                }
                guard case .completed(let rawText) = outcome else {
                    throw VoiceNoteRetryError.timeout
                }
                guard isCurrentVoiceNoteLifecycle(
                    sessionID: sessionID,
                    requestID: requestID,
                    runnerID: runnerID
                ) else {
                    return
                }
                let text = postProcessTranscript(rawText)
                let existingTranscript = try? store.transcript(for: sessionID)
                let transcript = Transcript(
                    id: existingTranscript?.id ?? UUID(),
                    sessionID: sessionID,
                    text: text,
                    createdAt: existingTranscript?.createdAt ?? .now,
                    engineIdentifier: engine.identifier
                )
                try store.saveTranscript(transcript)
                cacheTranscript(transcript)

                session.phase = .completed
                session.endedAt = session.endedAt ?? .now
                session.transcriptID = transcript.id
                session.engineIdentifier = engine.identifier
                session.errorMessage = nil
                session.protectedAudioUntilTranscriptCompletes = false
                session.hasDurableAudioCheckpoint = false
                session.lastTranscriptionFailureReason = nil
                cleanupNonRetainedAudio(for: &session)
                try store.saveSession(session)
                try? await voiceNoteCheckpointStore.delete(sessionID: sessionID)

                let existingResult = try? store.result(for: requestID)
                let result = DictationResult(
                    id: existingResult?.id ?? UUID(),
                    requestID: requestID,
                    sessionID: sessionID,
                    text: text,
                    createdAt: session.createdAt,
                    engineIdentifier: engine.identifier,
                    source: session.source
                )
                try store.saveResult(result)
                scheduleICloudSyncAfterLocalChange(reason: "long_voice_note_recovered")
                activeSession = nil
                statusText = "Ready"
                finishVoiceNoteLifecycle(sessionID: sessionID)
                refreshHistory()
            } catch is CancellationError {
                guard isCurrentVoiceNoteLifecycle(
                    sessionID: sessionID,
                    requestID: requestID,
                    runnerID: runnerID
                ) else {
                    return
                }
                session = await persistVoiceNoteFailure(
                    session,
                    reason: .interrupted,
                    message: "Your audio is safe. Transcription was interrupted.",
                    unavailableAudioMessage: "Transcription was interrupted and the audio could not be recovered."
                )
                activeSession = nil
                statusText = session.errorMessage ?? "Transcription interrupted"
                refreshHistory()
            } catch {
                guard isCurrentVoiceNoteLifecycle(
                    sessionID: sessionID,
                    requestID: requestID,
                    runnerID: runnerID
                ) else {
                    return
                }
                let failureReason = voiceNoteFailureReason(for: error)
                session = await persistVoiceNoteFailure(
                    session,
                    reason: failureReason,
                    message: "Your audio is safe. We couldn't finish transcribing this note.",
                    unavailableAudioMessage: "We couldn't finish transcribing this note or recover its audio."
                )
                activeSession = nil
                statusText = session.errorMessage ?? "Transcription failed"
                refreshHistory()
                AppTelemetry.failure(
                    "long_voice_note_transcription_failed",
                    domain: .transcription,
                    stage: "retry",
                    error: error,
                    reason: failureReason.rawValue,
                    isTimeout: failureReason == .timeout,
                    parameters: voiceNoteTelemetryParameters(session: session)
                )
            }
        }
        voiceNoteLifecycleRunner?.transcriptionTask = task
    }

    @discardableResult
    func deleteMeeting(_ session: RecordingSession) -> Bool {
        do {
            if let audioFileName = session.audioFileName {
                try? store.deleteAudioFile(fileName: audioFileName)
            }
            try store.deleteTranscript(for: session.id)
            removeCachedTranscript(for: session.id)
            try store.deleteRecordingSession(id: session.id)
            recordingSessions.removeAll { $0.id == session.id }
            clipboardStatusText = "Deleted"
            AppTelemetry.signal("meeting_deleted")
            clearClipboardStatusSoon()
            scheduleICloudSyncAfterLocalChange(reason: "meeting_deleted")
            return true
        } catch {
            clipboardStatusText = "Delete failed"
            clearClipboardStatusSoon()
            return false
        }
    }

    @discardableResult
    func deleteMeetingAudio(for session: RecordingSession) -> Bool {
        do {
            guard var storedSession = try store.activeRecordingSession(id: session.id),
                  storedSession.kind == .meeting,
                  let audioFileName = storedSession.audioFileName
            else {
                clipboardStatusText = "Audio already removed"
                clearClipboardStatusSoon()
                return true
            }

            try store.deleteAudioFile(fileName: audioFileName)
            storedSession.audioFileName = nil
            storedSession.keepsAudioRecording = false
            try store.saveSession(storedSession)

            if activeSession?.id == storedSession.id {
                activeSession = storedSession
            }
            if let index = recordingSessions.firstIndex(where: { $0.id == storedSession.id }) {
                recordingSessions[index] = storedSession
            } else {
                refreshHistory()
            }

            clipboardStatusText = "Audio deleted"
            AppTelemetry.signal("meeting_audio_deleted")
            clearClipboardStatusSoon()
            scheduleICloudSyncAfterLocalChange(reason: "meeting_audio_deleted")
            return true
        } catch {
            clipboardStatusText = "Audio delete failed"
            clearClipboardStatusSoon()
            return false
        }
    }

    func updateMeetingTitle(sessionID: UUID, title: String) {
        do {
            guard var session = try store.activeRecordingSession(id: sessionID),
                  session.kind == .meeting
            else { return }

            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            session.title = trimmedTitle.isEmpty ? session.kind.title : trimmedTitle
            try store.saveSession(session)
            if let index = recordingSessions.firstIndex(where: { $0.id == session.id }) {
                recordingSessions[index] = session
            } else {
                refreshHistory()
            }
            clipboardStatusText = "Title updated"
            clearClipboardStatusSoon()
            scheduleICloudSyncAfterLocalChange(reason: "meeting_title_updated")
            AppTelemetry.signal("meeting_title_updated")
        } catch {
            clipboardStatusText = "Title update failed"
            clearClipboardStatusSoon()
        }
    }

    func updateMeetingManualNotes(sessionID: UUID, notes: String) {
        do {
            guard try store.updateMeetingManualNotes(sessionID: sessionID, manualNotes: notes) else {
                clipboardStatusText = "Notes save failed"
                clearClipboardStatusSoon()
                refreshHistory()
                return
            }

            if activeSession?.id == sessionID {
                activeSession?.manualNotes = notes
            }
            if let index = recordingSessions.firstIndex(where: { $0.id == sessionID }) {
                recordingSessions[index].manualNotes = notes
            } else {
                refreshHistory()
            }
            scheduleICloudSyncAfterLocalChange(reason: "meeting_manual_notes_updated")
            AppTelemetry.signal("meeting_manual_notes_updated")
        } catch {
            clipboardStatusText = "Notes save failed"
            clearClipboardStatusSoon()
        }
    }

    func copyTranscript(_ transcript: Transcript) {
        UIPasteboard.general.string = transcript.text
        clipboardStatusText = "Copied"
        AppTelemetry.signal("transcript_copied")

        clearClipboardStatusSoon()
    }

    func copyText(_ text: String, telemetryName: String) {
        UIPasteboard.general.string = text
        clipboardStatusText = "Copied"
        AppTelemetry.signal(telemetryName)

        clearClipboardStatusSoon()
    }

    func audioFileURL(for session: RecordingSession) -> URL? {
        guard let audioFileName = session.audioFileName else { return nil }
        return try? store.audioFileURL(fileName: audioFileName)
    }

    func recordingSession(for result: DictationResult) -> RecordingSession? {
        if let sessionID = result.sessionID {
            if let cachedSession = recordingSessions.first(where: { $0.id == sessionID }) {
                return cachedSession
            }
            if let storedSession = try? store.activeRecordingSession(id: sessionID) {
                return storedSession
            }
        }
        return nil
    }

    func audioFileURL(for result: DictationResult) -> URL? {
        guard let session = recordingSession(for: result),
              session.keepsAudioRecording,
              let audioFileName = session.audioFileName
        else { return nil }
        return try? store.audioFileURL(fileName: audioFileName)
    }

    private func clearClipboardStatusSoon() {
        let statusToClear = clipboardStatusText
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            if self?.clipboardStatusText == statusToClear {
                self?.clipboardStatusText = nil
            }
        }
    }

    func applyLiveActivityPreferences() {
        Task {
            await liveActivityController.endDisabledActivities()
        }
    }

    func syncICloudTextIfEnabled(reason: String = "manual") {
        guard MuesliPreferences.iCloudSyncEnabled else {
            iCloudSyncStatusText = "iCloud sync is off."
            isICloudSyncInProgress = false
            return
        }
        guard iCloudSyncTask == nil else {
            isICloudSyncInProgress = true
            pendingICloudSyncReason = reason
            return
        }
        isICloudSyncInProgress = true
        iCloudSyncStatusText = "Syncing through private iCloud..."
        iCloudSyncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await ICloudTextSyncEngine().sync(
                    store: self.store,
                    forceBridgeDeviceRefresh: self.shouldForceBridgeDeviceRefresh(for: reason)
                )
                self.iCloudSyncTask = nil
                self.isICloudSyncInProgress = false
                let remoteDeviceName = MuesliBridgeDeviceIdentity.remoteDeviceDisplayName
                if result.downloaded > 0 {
                    self.iCloudSyncStatusText = "Synced with \(remoteDeviceName ?? "your Mac")."
                    AppTelemetry.signal(
                        "bridge_remote_records_seen",
                        parameters: ["platform": "ios", "count": "\(result.downloaded)"]
                    )
                } else if result.uploaded > 0 {
                    self.iCloudSyncStatusText = remoteDeviceName.map { "Synced with \($0)." }
                        ?? "Synced with private iCloud."
                } else {
                    self.iCloudSyncStatusText = remoteDeviceName.map { "All text is up to date with \($0)." }
                        ?? "All text is up to date."
                }
                self.refreshHistory()
                AppTelemetry.signal(
                    "icloud_text_sync_completed",
                    parameters: ["reason": reason]
                )
                if reason == "onboarding_bridge" || reason == "settings_toggle" {
                    AppTelemetry.signal(
                        "bridge_enable_completed",
                        parameters: ["platform": "ios", "source": reason]
                    )
                }
                self.runPendingICloudSyncIfNeeded()
            } catch {
                self.iCloudSyncTask = nil
                self.isICloudSyncInProgress = false
                self.iCloudSyncStatusText = "Sync failed: \(error.localizedDescription)"
                AppTelemetry.failure(
                    "icloud_text_sync_failed",
                    domain: .cloudSync,
                    stage: "sync",
                    error: error,
                    reason: reason
                )
                if reason == "onboarding_bridge" || reason == "settings_toggle" {
                    AppTelemetry.failure(
                        "bridge_enable_failed",
                        domain: .cloudSync,
                        stage: "bridge_enable",
                        error: error,
                        reason: reason,
                        parameters: ["platform": "ios", "source": reason]
                    )
                }
                self.runPendingICloudSyncIfNeeded()
            }
        }
    }

    private func scheduleICloudSyncAfterLocalChange(reason: String) {
        guard MuesliPreferences.iCloudSyncEnabled else { return }
        iCloudSyncDebounceTask?.cancel()
        iCloudSyncDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.0))
            guard !Task.isCancelled else { return }
            self?.iCloudSyncDebounceTask = nil
            self?.syncICloudTextIfEnabled(reason: reason)
        }
    }

    private func runPendingICloudSyncIfNeeded() {
        guard let reason = pendingICloudSyncReason else { return }
        pendingICloudSyncReason = nil
        scheduleICloudSyncAfterLocalChange(reason: reason)
    }

    private func shouldForceBridgeDeviceRefresh(for reason: String) -> Bool {
        switch reason {
        case "bridge_qr_existing",
             "home_manual",
             "onboarding_bridge",
             "settings_manual",
             "settings_qr",
             "settings_toggle":
            return true
        default:
            return false
        }
    }

    func setKeyboardSessionModeEnabled(_ enabled: Bool) {
        if enabled {
            stopKeyboardSessionAfterCurrentRequest = false
            UserDefaults.standard.set(true, forKey: MuesliPreferences.keyboardSessionModeKey)
            Task { await startKeyboardSessionMode() }
        } else {
            UserDefaults.standard.set(false, forKey: MuesliPreferences.keyboardSessionModeKey)
            if shouldDeferKeyboardSessionStop {
                stopKeyboardSessionAfterCurrentRequest = true
                keyboardSessionRetryTask?.cancel()
                keyboardSessionRetryTask = nil
                keyboardSessionRetryAttempt = 0
                saveKeyboardRuntimeStatus(
                    isActive: true,
                    activeRequestID: activeRequest?.id,
                    phase: isRecording ? .recording : .transcribing,
                    message: "Turns off after this keyboard voice note",
                    supportsBackgroundStart: false,
                    inputLevel: inputLevel
                )
                return
            }
            guard isKeyboardSessionArmed || keyboardSessionActivitySession != nil || keyboardSessionKeeper.isRunning else {
                keyboardSessionRetryTask?.cancel()
                keyboardSessionRetryTask = nil
                keyboardSessionRetryAttempt = 0
                transitionKeyboardSession(.stop(.turnedOff))
                saveKeyboardRuntimeStatus(
                    isActive: false,
                    activeRequestID: activeRequest?.id,
                    phase: activeRequest == nil ? .idle : .recording,
                    message: KeyboardSessionStopReason.turnedOff.message
                )
                return
            }
            stopKeyboardSessionMode(reason: .turnedOff)
        }
    }

    func startKeyboardSessionMode() async {
        guard !isKeyboardSessionArmed else {
            prewarmModelIfNeeded(reason: "keyboard_session")
            if !isRecording, !hasMeetingRecordingInProgress, activeRequest == nil {
                _ = await ensureKeyboardSessionKeeperRunning(publishReady: true)
            }
            let isReady = canStartKeyboardRequestsInBackground
            saveKeyboardRuntimeStatus(
                isActive: isKeyboardHotMicEngineReady || isRecording || activeRequest != nil,
                activeRequestID: activeRequest?.id,
                phase: isRecording ? .recording : .idle,
                message: isRecording ? "Listening" : (isReady ? "Keyboard session ready" : "Mic session warming up"),
                supportsBackgroundStart: isReady
            )
            return
        }

        transitionKeyboardSession(.startRequested)
        do {
            try await keyboardSessionKeeper.start()
            guard !abortKeyboardSessionStartIfModeDisabled() else { return }
            guard await keyboardSessionKeeper.waitUntilCanAcceptStartCommand() else {
                throw AudioRecorder.RecordingError.startFailed(stage: "keyboard session input")
            }
            guard !abortKeyboardSessionStartIfModeDisabled() else { return }
            keyboardSessionRetryTask?.cancel()
            keyboardSessionRetryTask = nil
            keyboardSessionRetryAttempt = 0
            prewarmModelIfNeeded(reason: "keyboard_session")
            transitionKeyboardSession(.startSucceeded)
            startKeyboardRuntimePolling()

            let session = RecordingSession(
                kind: .keyboardDictation,
                title: "Keyboard Session",
                startedAt: .now,
                phase: .recording
            )
            keyboardSessionActivitySession = session
            await liveActivityController.start(
                session: session,
                requestID: nil,
                phase: "Ready",
                detail: "Keyboard voice note session active"
            )
            saveKeyboardRuntimeStatus(
                isActive: true,
                activeRequestID: nil,
                phase: .idle,
                message: "Keyboard session ready",
                supportsBackgroundStart: true
            )
            AppTelemetry.signal("keyboard_session_started")
        } catch {
            let isRecoverable = isRecoverableKeyboardSessionError(error)
            if isRecoverable {
                transitionKeyboardSession(.retryScheduled(message: Self.keyboardSessionRetryMessage))
                scheduleKeyboardSessionRetry()
            } else {
                keyboardSessionRetryAttempt = 0
                transitionKeyboardSession(.startFailed(message: error.localizedDescription, recoverable: false))
            }
            saveKeyboardRuntimeStatus(
                isActive: false,
                activeRequestID: nil,
                phase: .failed,
                message: isRecoverable ? Self.keyboardSessionRetryMessage : error.localizedDescription
            )
            AppTelemetry.failure(
                "keyboard_session_failed",
                domain: .keyboardSession,
                stage: "start",
                error: error,
                parameters: ["recoverable": isRecoverable ? "true" : "false"]
            )
        }
    }

    private var shouldDeferKeyboardSessionStop: Bool {
        if isRecording, let requestID = activeRequest?.id, usesKeyboardSessionLiveActivity(for: requestID) {
            return true
        }
        return isKeyboardHandoffActive && activeRequest != nil
    }

    @discardableResult
    private func abortKeyboardSessionStartIfModeDisabled() -> Bool {
        guard !MuesliPreferences.keyboardSessionModeEnabled else { return false }

        keyboardSessionRetryTask?.cancel()
        keyboardSessionRetryTask = nil
        keyboardSessionRetryAttempt = 0
        keyboardSessionKeeper.stop(deactivateSession: !isRecording)
        transitionKeyboardSession(.stop(.turnedOff))
        saveKeyboardRuntimeStatus(
            isActive: false,
            activeRequestID: activeRequest?.id,
            phase: activeRequest == nil ? .idle : .recording,
            message: KeyboardSessionStopReason.turnedOff.message
        )
        return true
    }

    private func stopKeyboardSessionMode(reason: KeyboardSessionStopReason = .stopped) {
        stopKeyboardSessionAfterCurrentRequest = false
        keyboardSessionRetryTask?.cancel()
        keyboardSessionRetryTask = nil
        keyboardSessionRetryAttempt = 0
        transitionKeyboardSession(.stop(reason))
        keyboardSessionKeeper.stop(deactivateSession: !isRecording)
        saveKeyboardRuntimeStatus(
            isActive: false,
            activeRequestID: activeRequest?.id,
            phase: activeRequest == nil ? .idle : .recording,
            message: reason.message
        )

        if let session = keyboardSessionActivitySession {
            Task {
                await liveActivityController.end(
                    phase: "Ended",
                    detail: reason.message,
                    session: session,
                    dismissal: .immediate
                )
            }
        }
        keyboardSessionActivitySession = nil
        AppTelemetry.signal("keyboard_session_stopped", parameters: ["reason": reason.message])
    }

    private func isRecoverableKeyboardSessionError(_ error: Error) -> Bool {
        if case AudioRecorder.RecordingError.microphonePermissionDenied = error {
            return false
        }
        return true
    }

    private func refreshKeyboardSessionLiveActivity(phase: String, detail: String) {
        guard isKeyboardSessionArmed || keyboardSessionActivitySession != nil else { return }

        if keyboardSessionActivitySession == nil {
            keyboardSessionActivitySession = RecordingSession(
                kind: .keyboardDictation,
                title: "Keyboard Session",
                startedAt: .now,
                phase: .recording
            )
        }

        guard let session = keyboardSessionActivitySession else { return }
        Task {
            await liveActivityController.start(
                session: session,
                requestID: nil,
                phase: phase,
                detail: detail
            )
        }
    }

    private func setUsesKeyboardSessionLiveActivity(_ usesKeyboardSession: Bool, for requestID: UUID) {
        if usesKeyboardSession {
            keyboardSessionLiveActivityRequestIDs.insert(requestID)
        } else {
            keyboardSessionLiveActivityRequestIDs.remove(requestID)
        }
    }

    private func usesKeyboardSessionLiveActivity(for requestID: UUID) -> Bool {
        keyboardSessionLiveActivityRequestIDs.contains(requestID)
    }

    private func clearKeyboardSessionLiveActivityRoute(for requestID: UUID) {
        keyboardSessionLiveActivityRequestIDs.remove(requestID)
    }

    func transcript(for session: RecordingSession) -> Transcript? {
        transcriptCache[session.id]
    }

    func saveOnboardingProfile(name: String, useCase: OnboardingUseCase) {
        userName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        selectedUseCase = useCase
        UserDefaults.standard.set(userName, forKey: Self.userNameKey)
        UserDefaults.standard.set(useCase.rawValue, forKey: Self.useCaseKey)
        AppTelemetry.signal(
            "onboarding_profile_saved",
            parameters: [
                "has_name": userName.isEmpty ? "false" : "true",
                "use_case": useCase.rawValue
            ]
        )
    }

    func prepareModelForOnboarding() {
        guard !modelPreparation.isPreparing, !modelPreparation.isReady else { return }

        let model = selectedTranscriptionModel
        modelPreparationTask?.cancel()
        modelPreparation = ModelPreparationState(
            phase: .downloading,
            progress: 0,
            status: "Checking model files...",
            detail: model.shortName
        )
        AppTelemetry.signal("model_prepare_started", parameters: ["engine": model.engineIdentifier])

        let coordinator = self
        modelPreparationTask = Task { [engine, model] in
            do {
                await engine.selectModel(model)
                let didStartBackgroundDownload = try await ModelBackgroundDownloadService.shared.startDownload(for: model)
                if didStartBackgroundDownload {
                    await MainActor.run {
                        coordinator.modelPreparationTask = nil
                    }
                    return
                }
                try await engine.prepare { progress, status in
                    Task { @MainActor in
                        coordinator.applyModelPreparationProgress(progress, status: status)
                    }
                }

                await MainActor.run {
                    coordinator.modelPreparationTask = nil
                    coordinator.modelPreparation = ModelPreparationState(
                        phase: .ready,
                        progress: 1,
                        status: "\(model.shortName) ready",
                        detail: model.detail
                    )
                    coordinator.playOnboardingModelReadyCueIfNeeded(for: model)
                    AppTelemetry.signal("model_prepare_completed", parameters: ["engine": model.engineIdentifier])
                }
            } catch is CancellationError {
                await MainActor.run {
                    coordinator.modelPreparationTask = nil
                }
            } catch {
                await MainActor.run {
                    coordinator.modelPreparationTask = nil
                    coordinator.modelPreparation = ModelPreparationState(
                        phase: .failed,
                        progress: nil,
                        status: "Model setup paused",
                        detail: "Check your connection and try again"
                    )
                    AppTelemetry.failure(
                        "model_prepare_failed",
                        domain: .model,
                        stage: "prepare",
                        error: error,
                        parameters: ["engine": model.engineIdentifier]
                    )
                }
            }
        }
    }

    func prepareModel() {
        prepareModelForOnboarding()
    }

    func prewarmModelIfNeeded(reason: String) {
        #if DEBUG
        guard !Self.shouldSkipModelPrewarmForTesting() else { return }
        #endif
        guard hasCompletedOnboarding else { return }
        guard modelPrewarmTask == nil else { return }
        guard modelPreparationTask == nil, !modelPreparation.isPreparing else { return }
        guard !isRecording, !hasMeetingRecordingInProgress else { return }

        let model = selectedTranscriptionModel
        modelPreparation = ModelPreparationState(
            phase: .preparing,
            progress: nil,
            status: "Warming up the transcription engine...",
            detail: model.shortName
        )
        let coordinator = self
        modelPrewarmTask = Task { [engine, model] in
            do {
                await engine.selectModel(model)
                guard await !engine.isLoaded(for: model) else {
                    await MainActor.run {
                        coordinator.modelPrewarmTask = nil
                        coordinator.modelPreparation = ModelPreparationState(
                            phase: .ready,
                            progress: 1,
                            status: "\(model.shortName) ready",
                            detail: "Loaded in memory"
                        )
                    }
                    return
                }

                AppTelemetry.signal(
                    "model_prewarm_started",
                    parameters: ["engine": model.engineIdentifier, "reason": reason]
                )
                try await engine.prepare { progress, status in
                    Task { @MainActor in
                        coordinator.applyModelPreparationProgress(progress, status: status)
                    }
                }

                await MainActor.run {
                    coordinator.modelPrewarmTask = nil
                    coordinator.modelPreparation = ModelPreparationState(
                        phase: .ready,
                        progress: 1,
                        status: "\(model.shortName) ready",
                        detail: "Loaded in memory"
                    )
                    AppTelemetry.signal(
                        "model_prewarm_completed",
                        parameters: ["engine": model.engineIdentifier, "reason": reason]
                    )
                }
            } catch is CancellationError {
                await MainActor.run {
                    coordinator.modelPrewarmTask = nil
                }
            } catch {
                await MainActor.run {
                    coordinator.modelPrewarmTask = nil
                    coordinator.modelPreparation = ModelPreparationState(
                        phase: .failed,
                        progress: nil,
                        status: "Warmup paused",
                        detail: "Muesli will try again when you record"
                    )
                    AppTelemetry.failure(
                        "model_prewarm_failed",
                        domain: .model,
                        stage: "prewarm",
                        error: error,
                        reason: reason,
                        parameters: ["engine": model.engineIdentifier]
                    )
                }
            }
        }
    }

    func startOnboardingTestDictation() {
        guard !isOnboardingTestRecording else { return }
        MuesliHaptics.dictationStart()
        onboardingTestTranscript = ""
        onboardingTestError = nil
        isOnboardingTestTranscribing = false

        Task {
            do {
                try await recorder.requestPermission()
                try recorder.start()
                isOnboardingTestRecording = true
                startMetering { [weak self] level in
                    self?.onboardingTestInputLevel = level
                }
                AppTelemetry.signal("onboarding_test_started")
            } catch {
                onboardingTestError = error.localizedDescription
                stopMetering()
                AppTelemetry.failure(
                    "onboarding_test_failed",
                    domain: .audio,
                    stage: "recording",
                    error: error,
                    parameters: ["surface": "onboarding"]
                )
            }
        }
    }

    func stopOnboardingTestDictation() {
        guard isOnboardingTestRecording else { return }
        MuesliHaptics.dictationStop()
        isOnboardingTestRecording = false
        isOnboardingTestTranscribing = true
        stopMetering()
        onboardingTestError = nil

        Task {
            do {
                let audioURL = try recorder.stop()
                let outcome = try await runOfflineTranscriptionJob(
                    audioURL: audioURL
                ) { [weak self] in
                    guard let self else { return }
                    self.isOnboardingTestTranscribing = false
                    self.onboardingTestError = "Transcription stalled. Try again."
                    AppTelemetry.failure(
                        "onboarding_test_failed",
                        domain: .transcription,
                        stage: "transcription_timeout",
                        reason: "timeout",
                        isTimeout: true,
                        parameters: ["surface": "onboarding"]
                    )
                } operation: { [engine] progress in
                    try await engine.transcribe(audioURL: audioURL, progress: progress)
                }
                guard case .completed(let rawText) = outcome else { return }
                let text = postProcessTranscript(rawText)
                isOnboardingTestTranscribing = false
                onboardingTestError = nil
                if text.isEmpty {
                    onboardingTestError = "No speech detected. Try again."
                    AppTelemetry.signal("onboarding_test_empty", parameters: ["engine": engine.identifier])
                    return
                }
                onboardingTestTranscript = text
                AppTelemetry.signal(
                    "onboarding_test_completed",
                    parameters: ["engine": engine.identifier]
                )
            } catch {
                isOnboardingTestTranscribing = false
                onboardingTestError = error.localizedDescription
                AppTelemetry.failure(
                    "onboarding_test_failed",
                    domain: .transcription,
                    stage: "transcription",
                    error: error,
                    parameters: [
                        "engine": engine.identifier,
                        "surface": "onboarding"
                    ]
                )
            }
        }
    }

    func cancelOnboardingTestDictation() {
        guard isOnboardingTestRecording else { return }
        MuesliHaptics.dictationStop()
        isOnboardingTestRecording = false
        isOnboardingTestTranscribing = false
        onboardingTestInputLevel = 0
        onboardingTestError = nil
        stopMetering()
        recorder.cancel()
        AppTelemetry.signal("onboarding_test_cancelled")
    }

    func completeOnboarding() {
        hasCompletedOnboarding = true
        UserDefaults.standard.set(true, forKey: Self.onboardingCompletedKey)
        AppTelemetry.signal(
            "onboarding_completed",
            parameters: [
                "model_ready": modelPreparation.isReady ? "true" : "false",
                "use_case": selectedUseCase.rawValue
            ]
        )
        prewarmModelIfNeeded(reason: "onboarding_completed")
    }

    private func applyModelPreparationProgress(_ progress: Double, status: String?) {
        let normalizedProgress = min(max(progress, 0), 1)
        let detail = status ?? "\(Int((normalizedProgress * 100).rounded()))% complete"
        let phase: ModelPreparationPhase = detail.localizedCaseInsensitiveContains("compil")
            || detail.localizedCaseInsensitiveContains("prepar")
            ? .preparing
            : .downloading

        modelPreparation = ModelPreparationState(
            phase: phase,
            progress: normalizedProgress,
            status: phase == .preparing
                ? "Optimizing for this iPhone..."
                : "Downloading \(selectedTranscriptionModel.shortName)",
            detail: detail
        )
    }

    private func prepareDownloadedModelAfterBackgroundDownload(_ model: LocalTranscriptionModel) {
        guard selectedTranscriptionModel == model else { return }
        guard modelPreparationTask == nil else { return }

        modelPreparation = ModelPreparationState(
            phase: .preparing,
            progress: nil,
            status: "Optimizing for this iPhone...",
            detail: "Download complete"
        )

        let coordinator = self
        modelPreparationTask = Task { [engine, model] in
            do {
                await engine.selectModel(model)
                try await engine.prepare { progress, status in
                    Task { @MainActor in
                        coordinator.applyModelPreparationProgress(progress, status: status)
                    }
                }

                await MainActor.run {
                    coordinator.modelPreparationTask = nil
                    coordinator.modelPreparation = ModelPreparationState(
                        phase: .ready,
                        progress: 1,
                        status: "\(model.shortName) ready",
                        detail: model.detail
                    )
                    coordinator.playOnboardingModelReadyCueIfNeeded(for: model)
                    AppTelemetry.signal("model_prepare_completed", parameters: ["engine": model.engineIdentifier])
                }
            } catch is CancellationError {
                await MainActor.run {
                    coordinator.modelPreparationTask = nil
                }
            } catch {
                await MainActor.run {
                    coordinator.modelPreparationTask = nil
                    coordinator.modelPreparation = ModelPreparationState(
                        phase: .failed,
                        progress: nil,
                        status: "Model setup paused",
                        detail: "Download finished, but optimization failed"
                    )
                    AppTelemetry.failure(
                        "model_prepare_failed",
                        domain: .model,
                        stage: "prepare_after_download",
                        error: error,
                        parameters: ["engine": model.engineIdentifier]
                    )
                }
            }
        }
    }

    private func playOnboardingModelReadyCueIfNeeded(for model: LocalTranscriptionModel) {
        guard !hasCompletedOnboarding else { return }
        guard onboardingModelReadyCueModel != model else { return }
        onboardingModelReadyCueModel = model
        MuesliAudioCues.modelReady()
    }

    private func startCheckpointingDictationRecorder(
        audioURL: URL,
        sessionID: UUID,
        enablesRealtimeTranscription: Bool,
        usesDurableCheckpoints: Bool
    ) async throws {
        realtimeDictationCommittedText = ""
        liveDictationTranscript = ""
        clearKeyboardLiveTranscript()
        if enablesRealtimeTranscription {
            await engine.selectModel(selectedTranscriptionModel)
            try await engine.startRealtimeSession(
                partialTranscript: { [weak self] partial in
                    Task { @MainActor in
                        self?.updateRealtimeDictationPartial(partial)
                    }
                },
                endOfUtterance: { [weak self] utterance in
                    Task { @MainActor in
                        self?.commitRealtimeDictationUtterance(utterance)
                    }
                }
            )
        }

        let chunksDirectory: URL
        if usesDurableCheckpoints {
            chunksDirectory = try await voiceNoteCheckpointStore.prepare(sessionID: sessionID, startedAt: .now)
        } else {
            chunksDirectory = try meetingChunkDirectory(for: sessionID)
            try? FileManager.default.removeItem(at: chunksDirectory)
            try FileManager.default.createDirectory(at: chunksDirectory, withIntermediateDirectories: true)
        }

        let streamingRecorder = StreamingMeetingRecorder()
        streamingRecorder.onRecordingFailure = { [weak self] failure in
            Task { @MainActor in
                self?.handleVoiceNoteWriterFailure(failure)
            }
        }
        if enablesRealtimeTranscription {
            let pipe = RealtimeAudioBufferPipe()
            streamingRecorder.onAudioBuffer = { [pipe] buffer in
                pipe.append(buffer)
            }
            realtimeDictationBufferPipe = pipe
            realtimeDictationProcessingTask = Task { [engine, pipe] in
                for await audioBuffer in pipe.stream {
                    do {
                        try await engine.processRealtimeAudioBuffer(audioBuffer.buffer)
                    } catch is CancellationError {
                        return
                    } catch {
                        AppTelemetry.failure(
                            "realtime_dictation_buffer_failed",
                            domain: .transcription,
                            stage: "streaming_buffer",
                            error: error,
                            parameters: ["surface": "dictation"]
                        )
                    }
                }
            }
        }

        try streamingRecorder.start(
            chunksDirectory: chunksDirectory,
            retainedAudioURL: audioURL,
            routeStage: "realtime dictation"
        )
        realtimeDictationRecorder = streamingRecorder
        realtimeDictationChunksDirectory = chunksDirectory
        isRealtimeDictationSessionActive = enablesRealtimeTranscription
    }

    private func updateRealtimeDictationPartial(_ partial: String) {
        let partial = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !partial.isEmpty else { return }

        let committed = realtimeDictationCommittedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if committed.isEmpty {
            liveDictationTranscript = partial
        } else {
            liveDictationTranscript = "\(committed) \(partial)"
        }
        saveKeyboardLiveTranscript(text: liveDictationTranscript, isFinal: false)
    }

    private func commitRealtimeDictationUtterance(_ utterance: String) {
        let utterance = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !utterance.isEmpty else { return }

        let committed = realtimeDictationCommittedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if committed.isEmpty {
            realtimeDictationCommittedText = utterance
        } else if !committed.hasSuffix(utterance) {
            realtimeDictationCommittedText = "\(committed) \(utterance)"
        }
        liveDictationTranscript = realtimeDictationCommittedText
        saveKeyboardLiveTranscript(text: liveDictationTranscript, isFinal: false)
    }

    private func startRecording(for request: DictationRequest, source: String) {
        guard !isRecording,
              !hasMeetingRecordingInProgress,
              !voiceNoteLifecycleState.isWorkActive,
              statusText != "Transcribing"
        else {
            if source == "keyboard" {
                if refreshActiveKeyboardRequestIfNeeded(request) {
                    return
                }

                let message = "Muesli is busy"
                if activeRequest?.id == request.id {
                    activeRequest = nil
                }
                try? store.saveStatus(.init(requestID: request.id, phase: .failed, message: message))
                saveKeyboardHandoff(requestID: request.id, phase: .failed, message: message)
                saveKeyboardRuntimeStatus(
                    isActive: canStartKeyboardRequestsInBackground,
                    activeRequestID: nil,
                    phase: .failed,
                    message: message,
                    supportsBackgroundStart: canStartKeyboardRequestsInBackground
                )
            }
            return
        }
        activeRequest = request
        let usesKeyboardSessionLiveActivity = source == "keyboard" && isKeyboardSessionArmed
        setUsesKeyboardSessionLiveActivity(usesKeyboardSessionLiveActivity, for: request.id)
        liveDictationTranscript = ""
        realtimeDictationCommittedText = ""
        clearKeyboardLiveTranscript()
        let kind: RecordingSessionKind = source == "keyboard" ? .keyboardDictation : .quickDictation
        let longModeThreshold = configuredLongVoiceNoteThreshold()
        var session = RecordingSession(
            requestID: request.id,
            kind: kind,
            keepsAudioRecording: MuesliPreferences.keepDictationAudioRecordingsEnabled,
            source: source,
            longFormThresholdSeconds: longModeThreshold
        )
        if source == "keyboard" {
            saveKeyboardHandoff(
                requestID: request.id,
                phase: .startAcknowledged,
                message: "Starting"
            )
        }

        Task {
            do {
                let audioURL = try store.newDictationAudioFileURL(startedAt: session.createdAt)
                session.audioFileName = audioURL.lastPathComponent
                session.startedAt = .now
                try store.saveSession(session)
                try await recorder.requestPermission()
                if !usesKeyboardSessionLiveActivity, keyboardSessionKeeper.isRunning {
                    keyboardSessionKeeper.stop(deactivateSession: true)
                    transitionKeyboardSession(.requestFinished)
                    try? store.clearKeyboardRuntimeStatus()
                    try? await Task.sleep(for: .milliseconds(150))
                }
                if usesKeyboardSessionLiveActivity {
                    if !keyboardSessionKeeper.canAcceptStartCommand {
                        if !keyboardSessionKeeper.isRunning {
                            try await keyboardSessionKeeper.start()
                        }
                        guard await keyboardSessionKeeper.waitUntilCanAcceptStartCommand() else {
                            throw AudioRecorder.RecordingError.startFailed(stage: "keyboard session input")
                        }
                        transitionKeyboardSession(.startSucceeded)
                    }
                    let checkpointDirectory: URL?
                    if longModeThreshold != nil {
                        checkpointDirectory = try await voiceNoteCheckpointStore.prepare(
                            sessionID: session.id,
                            startedAt: session.startedAt ?? session.createdAt
                        )
                    } else {
                        checkpointDirectory = nil
                    }
                    try keyboardSessionKeeper.beginSegment(
                        outputURL: audioURL,
                        checkpointDirectory: checkpointDirectory
                    )
                    transitionKeyboardSession(.recordingStarted(request.id))
                } else if selectedTranscriptionModel.supportsRealtimeStreaming || longModeThreshold != nil {
                    try await startCheckpointingDictationRecorder(
                        audioURL: audioURL,
                        sessionID: session.id,
                        enablesRealtimeTranscription: selectedTranscriptionModel.supportsRealtimeStreaming,
                        usesDurableCheckpoints: longModeThreshold != nil
                    )
                } else {
                    try recorder.start(outputURL: audioURL)
                }
                refreshAudioInputRoute()
                activeSession = session
                isRecording = true
                guard beginVoiceNoteLifecycle(
                    sessionID: session.id,
                    requestID: request.id,
                    threshold: longModeThreshold
                ) else {
                    throw VoiceNoteCaptureFailure.invalidLifecycleTransition
                }
                if source == "keyboard", !usesKeyboardSessionLiveActivity {
                    transitionKeyboardSession(.recordingStarted(request.id))
                }
                startRecordingTimer(startedAt: session.startedAt ?? .now)
                if source == "keyboard" {
                    saveKeyboardHandoff(
                        requestID: request.id,
                        phase: .recordingStarted,
                        message: "Listening"
                    )
                    startKeyboardRuntimePolling()
                    saveKeyboardRuntimeStatus(
                        isActive: true,
                        activeRequestID: request.id,
                        phase: .recording,
                        message: "Listening",
                        supportsBackgroundStart: canStartKeyboardRequestsInBackground
                    )
                }
                startMetering { [weak self] level in
                    guard let self else { return }
                    self.inputLevel = level
                    if source == "keyboard" {
                        self.publishKeyboardRuntimeLevel(level, requestID: request.id)
                    }
                }
                if source == "keyboard" {
                    startCommandPolling(for: request.id)
                }
                statusText = "Recording"
                AppTelemetry.signal("dictation_started", parameters: ["source": source])
                try store.saveRequest(request)
                try store.saveStatus(.init(requestID: request.id, phase: .recording))
                Task {
                    if usesKeyboardSessionLiveActivity {
                        refreshKeyboardSessionLiveActivity(
                            phase: "Listening",
                            detail: "Keyboard voice note active"
                        )
                    } else {
                        await liveActivityController.start(
                            session: session,
                            requestID: request.id,
                            phase: "Listening",
                            detail: "Recording voice note"
                        )
                    }
                }
            } catch {
                session.phase = .failed
                session.errorMessage = error.localizedDescription
                cleanupNonRetainedAudio(for: &session)
                try? store.saveSession(session)
                cleanupRealtimeDictationRecorder()
                if session.longFormThresholdSeconds != nil {
                    try? await voiceNoteCheckpointStore.delete(sessionID: session.id)
                }
                finishVoiceNoteLifecycle(sessionID: session.id)
                activeSession = nil
                activeRequest = nil
                stopRecordingTimer()
                statusText = error.localizedDescription
                clearKeyboardLiveTranscript()
                clearKeyboardSessionLiveActivityRoute(for: request.id)
                stopMetering()
                if usesKeyboardSessionLiveActivity {
                    keyboardSessionKeeper.cancelSegment()
                }
                let completedDeferredStop = completeDeferredKeyboardSessionStopIfNeeded()
                transitionKeyboardSession(.requestFinished)
                if !completedDeferredStop {
                    resumeKeyboardSessionKeeperIfNeeded()
                }
                AppTelemetry.failure(
                    "dictation_failed",
                    domain: .audio,
                    stage: "recording",
                    error: error,
                    parameters: ["source": source]
                )
                try? store.saveStatus(.init(requestID: request.id, phase: .failed, message: error.localizedDescription))
                if source == "keyboard" {
                    saveKeyboardHandoff(
                        requestID: request.id,
                        phase: .failed,
                        message: error.localizedDescription
                    )
                }
            }
        }
    }

    private func stopRecording() {
        guard let request = activeRequest else { return }
        stopRecording(requestID: request.id)
    }

    private func recoverKeyboardTranscription(
        request: DictationRequest,
        session: RecordingSession,
        audioURL: URL,
        lifecycleRunnerID: UUID
    ) {
        beginTranscriptionBackgroundTask()
        let task = Task {
            defer { endTranscriptionBackgroundTask() }

            do {
                await engine.selectModel(selectedTranscriptionModel)
                guard isCurrentVoiceNoteLifecycle(
                    sessionID: session.id,
                    requestID: request.id,
                    runnerID: lifecycleRunnerID
                ) else { return }
                saveKeyboardHandoff(
                    requestID: request.id,
                    phase: .transcribingStarted,
                    message: "Recovering transcription"
                )
                let outcome = try await runOfflineTranscriptionJob(
                    audioURL: audioURL,
                    onProgress: { [weak self] update in
                        guard let self,
                              self.isCurrentVoiceNoteLifecycle(
                                  sessionID: session.id,
                                  requestID: request.id,
                                  runnerID: lifecycleRunnerID
                              )
                        else { return }
                        let message = self.transcriptionStatusMessage(for: update)
                        self.statusText = message
                        try? self.store.saveStatus(.init(requestID: request.id, phase: .transcribing, message: message))
                        self.saveKeyboardHandoff(requestID: request.id, phase: .transcribingStarted, message: message)
                        self.saveKeyboardRuntimeStatus(
                            isActive: true,
                            activeRequestID: request.id,
                            phase: .transcribing,
                            message: message,
                            supportsBackgroundStart: self.canStartKeyboardRequestsInBackground
                        )
                    },
                    onTimeout: {}
                ) { [engine] progress in
                    try await engine.transcribe(audioURL: audioURL, progress: progress)
                }
                guard case .completed(let rawText) = outcome else {
                    throw VoiceNoteRetryError.timeout
                }
                guard isCurrentVoiceNoteLifecycle(
                    sessionID: session.id,
                    requestID: request.id,
                    runnerID: lifecycleRunnerID
                ) else { return }
                let text = postProcessTranscript(rawText)
                let savedTranscript = Transcript(
                    sessionID: session.id,
                    text: text,
                    engineIdentifier: engine.identifier
                )
                try store.saveTranscript(savedTranscript)
                cacheTranscript(savedTranscript)

                var completedSession = session
                completedSession.phase = .completed
                completedSession.endedAt = completedSession.endedAt ?? .now
                completedSession.transcriptID = savedTranscript.id
                completedSession.engineIdentifier = engine.identifier
                completedSession.errorMessage = nil
                completedSession.protectedAudioUntilTranscriptCompletes = false
                completedSession.hasDurableAudioCheckpoint = false
                completedSession.lastTranscriptionFailureReason = nil
                cleanupNonRetainedAudio(for: &completedSession)
                try store.saveSession(completedSession)
                if completedSession.longFormThresholdSeconds != nil {
                    try? await voiceNoteCheckpointStore.delete(sessionID: completedSession.id)
                }
                finishVoiceNoteLifecycle(sessionID: completedSession.id)
                exportRetainedAudioIfNeeded(for: completedSession)

                let existingResult = try? store.result(for: request.id)
                let result = DictationResult(
                    id: existingResult?.id ?? UUID(),
                    requestID: request.id,
                    sessionID: savedTranscript.sessionID,
                    text: text,
                    createdAt: completedSession.createdAt,
                    engineIdentifier: engine.identifier,
                    source: completedSession.source
                )
                try store.saveResult(result)
                scheduleICloudSyncAfterLocalChange(reason: "dictation_completed")
                saveKeyboardLiveTranscript(text: text, isFinal: true)
                saveKeyboardHandoff(requestID: request.id, phase: .resultReady, message: "Ready to insert")
                try store.clearPendingRequest()
                activeRequest = nil
                activeSession = nil
                let completedDeferredStop = completeDeferredKeyboardSessionStopIfNeeded()
                transitionKeyboardSession(.requestFinished)
                statusText = "Ready"
                refreshHistory()
                if !completedDeferredStop {
                    saveKeyboardRuntimeStatus(
                        isActive: canStartKeyboardRequestsInBackground,
                        activeRequestID: nil,
                        phase: .idle,
                        message: isKeyboardSessionArmed ? "Keyboard session ready" : "Ready",
                        supportsBackgroundStart: canStartKeyboardRequestsInBackground
                    )
                    resumeKeyboardSessionKeeperIfNeeded()
                }
                AppTelemetry.signal(
                    "keyboard_transcription_recovered",
                    parameters: [
                        "engine": engine.identifier,
                        "empty": text.isEmpty ? "true" : "false"
                    ]
                )
            } catch {
                guard isCurrentVoiceNoteLifecycle(
                    sessionID: session.id,
                    requestID: request.id,
                    runnerID: lifecycleRunnerID
                ) else { return }
                let failureReason = voiceNoteFailureReason(for: error)
                _ = await persistVoiceNoteFailure(
                    session,
                    reason: failureReason,
                    message: error.localizedDescription
                )
                try? store.saveStatus(.init(
                    requestID: request.id,
                    phase: .failed,
                    message: error.localizedDescription
                ))
                saveKeyboardHandoff(
                    requestID: request.id,
                    phase: .failed,
                    message: error.localizedDescription
                )
                activeRequest = nil
                activeSession = nil
                try? store.clearPendingRequest()
                try? store.clearPendingCommand()
                let completedDeferredStop = completeDeferredKeyboardSessionStopIfNeeded()
                transitionKeyboardSession(.requestFinished)
                statusText = error.localizedDescription
                if !completedDeferredStop {
                    saveKeyboardRuntimeStatus(
                        isActive: canStartKeyboardRequestsInBackground,
                        activeRequestID: nil,
                        phase: .failed,
                        message: error.localizedDescription,
                        supportsBackgroundStart: canStartKeyboardRequestsInBackground
                    )
                    resumeKeyboardSessionKeeperIfNeeded()
                }
                AppTelemetry.failure(
                    "keyboard_transcription_recovery_failed",
                    domain: .transcription,
                    stage: VoiceNoteFailureTelemetryPolicy.stage(
                        for: failureReason,
                        standard: "keyboard_recovery",
                        timeout: "keyboard_recovery_timeout"
                    ),
                    error: error,
                    reason: failureReason.rawValue,
                    isTimeout: failureReason == .timeout,
                    parameters: ["engine": engine.identifier]
                )
            }
        }
        voiceNoteLifecycleRunner?.transcriptionTask = task
    }

    private func stopRecording(requestID: UUID) {
        guard !rejectConflictingKeyboardCommand(requestID: requestID, action: .stop) else { return }

        let request: DictationRequest
        var session = activeSession
        if let activeRequest, activeRequest.id == requestID {
            request = activeRequest
        } else if let pendingRequest = try? store.pendingRequest(), pendingRequest.id == requestID {
            request = pendingRequest
            activeRequest = pendingRequest
            session = try? store.recordingSession(requestID: requestID)
        } else {
            let message = "No active recording found. Start a new voice note."
            statusText = message
            try? store.saveStatus(.init(requestID: requestID, phase: .failed, message: message))
            saveKeyboardHandoff(requestID: requestID, phase: .failed, message: message)
            return
        }

        guard isRecording else { return }

        if var thresholdSession = session,
           !thresholdSession.isLongForm,
           let threshold = thresholdSession.longFormThresholdSeconds,
           recordingElapsedTime >= Double(threshold),
           transitionVoiceNoteLifecycle(.longFormActivated(thresholdSession.id)) {
            thresholdSession.isLongForm = true
            thresholdSession.longFormActivatedAt = .now
            thresholdSession.protectedAudioUntilTranscriptCompletes =
                thresholdSession.hasDurableAudioCheckpoint
            session = thresholdSession
            activeSession = thresholdSession
            try? store.saveSession(thresholdSession)
            if thresholdSession.kind == .quickDictation {
                presentedLongVoiceNoteSessionID = thresholdSession.id
            }
            AppTelemetry.contextualSignal(
                "long_voice_note_activated",
                parameters: voiceNoteTelemetryParameters(
                    session: thresholdSession,
                    checkpointCount: longVoiceNoteCheckpointCount
                )
            )
        }

        let usesKeyboardSessionLiveActivity = usesKeyboardSessionLiveActivity(for: request.id)
        let lifecycleRunnerID: UUID?
        if let session {
            guard let runner = voiceNoteLifecycleRunner,
                  runner.sessionID == session.id,
                  runner.requestID == request.id,
                  transitionVoiceNoteLifecycle(.stopRequested(session.id))
            else { return }
            lifecycleRunnerID = runner.id
            stopVoiceNoteRecordingTasks(sessionID: session.id)
            if session.isLongForm {
                AppTelemetry.contextualSignal(
                    "long_voice_note_stop_requested",
                    parameters: voiceNoteTelemetryParameters(
                        session: session,
                        checkpointCount: longVoiceNoteCheckpointCount
                    )
                )
            }
        } else {
            lifecycleRunnerID = nil
        }
        isRecording = false
        stopMetering()
        stopRecordingTimer()
        if !usesKeyboardSessionLiveActivity {
            stopCommandPolling()
        }
        statusText = "Saving audio"
        if isKeyboardHandoffActive {
            transitionKeyboardSession(.transcribing(request.id))
        }
        try? store.saveStatus(.init(requestID: request.id, phase: .transcribing, message: "Transcribing"))
        if isKeyboardHandoffActive {
            saveKeyboardHandoff(
                requestID: request.id,
                phase: .stopAcknowledged,
                message: "Finalizing audio"
            )
            saveKeyboardRuntimeStatus(
                isActive: true,
                activeRequestID: request.id,
                phase: .transcribing,
                message: "Transcribing",
                supportsBackgroundStart: canStartKeyboardRequestsInBackground
            )
        }
        if var session {
            session.phase = .transcriptionQueued
            session.endedAt = .now
            try? store.saveSession(session)
            activeSession = session
            Task {
                if usesKeyboardSessionLiveActivity {
                    refreshKeyboardSessionLiveActivity(
                        phase: "Transcribing",
                        detail: "Preparing text for the keyboard"
                    )
                } else {
                    await liveActivityController.update(
                        phase: "Transcribing",
                        detail: "Preparing text for the keyboard",
                        session: session
                    )
                }
            }
        }

        beginTranscriptionBackgroundTask()
        let transcriptionTask = Task {
            defer {
                stopCommandPolling()
                endTranscriptionBackgroundTask()
            }
            let startedFromKeyboard = isKeyboardHandoffActive

            do {
                let usesCheckpointingRecorder = realtimeDictationRecorder != nil
                let usesRealtimeStreaming = usesCheckpointingRecorder && isRealtimeDictationSessionActive
                let audioURL: URL
                var finalCheckpoint: MeetingAudioChunk?
                var finalWriterFailure: CheckpointingAudioWriterFailure?
                var realtimeText = ""

                if usesKeyboardSessionLiveActivity {
                    let segment = try keyboardSessionKeeper.finishSegment()
                    audioURL = segment.audioURL
                    finalCheckpoint = segment.finalCheckpoint
                    finalWriterFailure = segment.writerFailure
                } else if usesCheckpointingRecorder {
                    let stoppedAudio = realtimeDictationRecorder?.stop()
                    realtimeDictationRecorder = nil
                    finalCheckpoint = stoppedAudio?.finalChunk
                    finalWriterFailure = stoppedAudio?.writerFailure
                    if usesRealtimeStreaming {
                        realtimeDictationBufferPipe?.finish()
                        await realtimeDictationProcessingTask?.value
                    }
                    realtimeDictationProcessingTask = nil
                    realtimeDictationBufferPipe = nil
                    isRealtimeDictationSessionActive = false
                    guard let retainedAudioURL = stoppedAudio?.retainedAudioURL else {
                        throw AudioRecorder.RecordingError.noRecording
                    }
                    audioURL = retainedAudioURL
                    if usesRealtimeStreaming {
                        realtimeText = postProcessTranscript(try await engine.finishRealtimeSession())
                    }
                } else {
                    audioURL = try recorder.stop()
                }

                if let currentSession = activeSession ?? session,
                   currentSession.longFormThresholdSeconds != nil {
                    let manifest = try await voiceNoteCheckpointStore.finalize(
                        sessionID: currentSession.id,
                        finalCheckpoint: finalCheckpoint
                    )
                    guard let lifecycleRunnerID,
                          isCurrentVoiceNoteLifecycle(
                              sessionID: currentSession.id,
                              requestID: request.id,
                              runnerID: lifecycleRunnerID
                          )
                    else { return }
                    longVoiceNoteCheckpointCount = manifest.entries.count
                    let checkpointFinalizationFailed = finalWriterFailure == .checkpointWrite
                        || finalWriterFailure == .checkpointRotation
                    longVoiceNoteAudioIsSecured = !manifest.entries.isEmpty
                        && !checkpointFinalizationFailed
                    var finalizedSession = activeSession ?? currentSession
                    finalizedSession.hasDurableAudioCheckpoint = longVoiceNoteAudioIsSecured
                    if finalizedSession.isLongForm {
                        finalizedSession.protectedAudioUntilTranscriptCompletes =
                            longVoiceNoteAudioIsSecured
                    }
                    activeSession = finalizedSession
                    try? store.saveSession(finalizedSession)
                    guard transitionVoiceNoteLifecycle(.audioFinalized(currentSession.id)),
                          transitionVoiceNoteLifecycle(.transcriptionQueued(currentSession.id))
                    else {
                        throw VoiceNoteCaptureFailure.invalidLifecycleTransition
                    }
                    if currentSession.isLongForm, !manifest.entries.isEmpty {
                        var checkpointParameters = voiceNoteTelemetryParameters(
                            session: currentSession,
                            checkpointCount: manifest.entries.count
                        )
                        checkpointParameters["checkpoint_kind"] = "final"
                        AppTelemetry.contextualSignal(
                            "long_voice_note_audio_checkpoint_saved",
                            parameters: checkpointParameters
                        )
                    }
                    if currentSession.isLongForm {
                        guard longVoiceNoteAudioIsSecured else {
                            throw VoiceNoteCaptureFailure.missingDurableCheckpoint
                        }
                        AppTelemetry.contextualSignal(
                            "long_voice_note_transcription_queued",
                            parameters: voiceNoteTelemetryParameters(
                                session: currentSession,
                                checkpointCount: manifest.entries.count
                            )
                        )
                    }
                }
                if let finalWriterFailure {
                    throw VoiceNoteCaptureFailure.writer(finalWriterFailure)
                }
                if var currentSession = activeSession ?? session {
                    guard let lifecycleRunnerID,
                          isCurrentVoiceNoteLifecycle(
                              sessionID: currentSession.id,
                              requestID: request.id,
                              runnerID: lifecycleRunnerID
                          )
                    else { return }
                    currentSession.phase = .transcribing
                    currentSession.lastTranscriptionAttemptAt = .now
                    activeSession = currentSession
                    try? store.saveSession(currentSession)
                    guard transitionVoiceNoteLifecycle(.transcriptionStarted(currentSession.id)) else {
                        throw VoiceNoteCaptureFailure.invalidLifecycleTransition
                    }
                }
                statusText = "Transcribing"
                if startedFromKeyboard {
                    saveKeyboardHandoff(
                        requestID: request.id,
                        phase: .transcribingStarted,
                        message: "Transcribing"
                    )
                }

                let text: String
                if realtimeText.isEmpty {
                    let outcome = try await runKeyboardTranscriptionJob(
                        audioURL: audioURL,
                        request: request,
                        startedFromKeyboard: startedFromKeyboard
                    )
                    guard case .completed(let rawText) = outcome else {
                        throw VoiceNoteRetryError.timeout
                    }
                    text = postProcessTranscript(rawText)
                } else {
                    text = realtimeText
                }
                if let currentSession = activeSession ?? session {
                    guard let lifecycleRunnerID,
                          isCurrentVoiceNoteLifecycle(
                              sessionID: currentSession.id,
                              requestID: request.id,
                              runnerID: lifecycleRunnerID
                          )
                    else { return }
                }
                liveDictationTranscript = text
                guard !isRecordingSessionCancelled(requestID: request.id) else {
                    if startedFromKeyboard {
                        saveKeyboardHandoff(requestID: request.id, phase: .cancelled, message: "Cancelled")
                        saveKeyboardRuntimeStatus(
                            isActive: canStartKeyboardRequestsInBackground,
                            activeRequestID: nil,
                            phase: .idle,
                            message: isKeyboardSessionArmed ? "Keyboard session ready" : "Ready",
                            supportsBackgroundStart: canStartKeyboardRequestsInBackground
                        )
                    }
                    clearKeyboardSessionLiveActivityRoute(for: request.id)
                    try? store.clearPendingRequest()
                    try? store.saveStatus(.idle)
                    return
                }
                if isKeyboardSessionArmed {
                    transitionKeyboardSession(.transcribing(request.id))
                }
                let completedSession = activeSession ?? session
                let transcript: Transcript?
                let resultCreatedAt: Date
                if var completedSession {
                    resultCreatedAt = completedSession.createdAt
                    let savedTranscript = Transcript(
                        sessionID: completedSession.id,
                        text: text,
                        engineIdentifier: engine.identifier
                    )
                    try store.saveTranscript(savedTranscript)
                    cacheTranscript(savedTranscript)
                    completedSession.phase = .completed
                    completedSession.audioFileName = completedSession.audioFileName ?? audioURL.lastPathComponent
                    completedSession.transcriptID = savedTranscript.id
                    completedSession.engineIdentifier = engine.identifier
                    completedSession.errorMessage = nil
                    completedSession.protectedAudioUntilTranscriptCompletes = false
                    completedSession.hasDurableAudioCheckpoint = false
                    completedSession.lastTranscriptionFailureReason = nil
                    cleanupNonRetainedAudio(for: &completedSession)
                    try store.saveSession(completedSession)
                    if completedSession.longFormThresholdSeconds != nil {
                        try? await voiceNoteCheckpointStore.delete(sessionID: completedSession.id)
                        realtimeDictationChunksDirectory = nil
                    }
                    exportRetainedAudioIfNeeded(for: completedSession)
                    transcript = savedTranscript
                } else {
                    resultCreatedAt = request.createdAt
                    transcript = nil
                }
                let result = DictationResult(
                    requestID: request.id,
                    sessionID: transcript?.sessionID,
                    text: text,
                    createdAt: resultCreatedAt,
                    engineIdentifier: engine.identifier,
                    source: completedSession?.source
                )
                try store.saveResult(result)
                scheduleICloudSyncAfterLocalChange(reason: "dictation_completed")
                if startedFromKeyboard {
                    saveKeyboardLiveTranscript(text: text, isFinal: true)
                    saveKeyboardHandoff(requestID: request.id, phase: .resultReady, message: "Ready to insert")
                }
                try store.clearPendingRequest()
                refreshHistory()
                lastTranscript = text
                activeRequest = nil
                activeSession = nil
                if let sessionID = completedSession?.id {
                    finishVoiceNoteLifecycle(sessionID: sessionID)
                }
                if usesKeyboardSessionLiveActivity {
                    keyboardSessionKeeper.cancelSegment()
                }
                let completedDeferredStop = completeDeferredKeyboardSessionStopIfNeeded()
                if startedFromKeyboard, !completedDeferredStop {
                    saveKeyboardRuntimeStatus(
                        isActive: canStartKeyboardRequestsInBackground,
                        activeRequestID: nil,
                        phase: .idle,
                        message: isKeyboardSessionArmed ? "Keyboard session ready" : "Ready",
                        supportsBackgroundStart: canStartKeyboardRequestsInBackground
                    )
                }
                transitionKeyboardSession(.requestFinished)
                if !completedDeferredStop {
                    resumeKeyboardSessionKeeperIfNeeded()
                    publishKeyboardSessionReadyIfAvailable()
                }
                statusText = "Ready"
                liveDictationTranscript = ""
                realtimeDictationCommittedText = ""
                if startedFromKeyboard, usesKeyboardSessionLiveActivity, !completedDeferredStop {
                    refreshKeyboardSessionLiveActivity(
                        phase: "Ready",
                        detail: "Keyboard voice note session active"
                    )
                } else if let completedSession = try? store.recordingSession(requestID: request.id) {
                    Task {
                        await liveActivityController.end(
                            phase: "Completed",
                            detail: "Transcript saved",
                            session: completedSession,
                            dismissal: .immediate
                        )
                    }
                }
                clearKeyboardSessionLiveActivityRoute(for: request.id)
                AppTelemetry.signal(
                    "dictation_completed",
                    parameters: [
                        "engine": engine.identifier,
                        "empty": text.isEmpty ? "true" : "false"
                    ]
                )
            } catch {
                if let currentSession = activeSession ?? session {
                    guard let lifecycleRunnerID,
                          isCurrentVoiceNoteLifecycle(
                              sessionID: currentSession.id,
                              requestID: request.id,
                              runnerID: lifecycleRunnerID
                          )
                    else { return }
                }
                var failedVoiceNoteSession: RecordingSession?
                let failureReason = voiceNoteFailureReason(for: error)
                if var session = activeSession ?? session {
                    session = await persistVoiceNoteFailure(
                        session,
                        reason: failureReason,
                        message: error.localizedDescription
                    )
                    failedVoiceNoteSession = session
                    if session.isLongForm {
                        AppTelemetry.failure(
                            "long_voice_note_transcription_failed",
                            domain: .transcription,
                            stage: VoiceNoteFailureTelemetryPolicy.stage(
                                for: failureReason,
                                standard: "offline_transcription",
                                timeout: "offline_transcription_timeout"
                            ),
                            error: error,
                            reason: failureReason.rawValue,
                            isTimeout: failureReason == .timeout,
                            parameters: voiceNoteTelemetryParameters(
                                session: session,
                                checkpointCount: longVoiceNoteCheckpointCount
                            )
                        )
                    }
                }
                activeRequest = nil
                activeSession = nil
                try? store.clearPendingRequest()
                try? store.clearPendingCommand()
                let completedDeferredStop = completeDeferredKeyboardSessionStopIfNeeded()
                if !completedDeferredStop {
                    saveKeyboardRuntimeStatus(
                        isActive: isKeyboardHandoffActive || usesKeyboardSessionLiveActivity || canStartKeyboardRequestsInBackground,
                        activeRequestID: nil,
                        phase: .failed,
                        message: error.localizedDescription,
                        supportsBackgroundStart: canStartKeyboardRequestsInBackground
                    )
                }
                if usesKeyboardSessionLiveActivity, !completedDeferredStop {
                    refreshKeyboardSessionLiveActivity(
                        phase: "Ready",
                        detail: "Keyboard voice note failed. Session active"
                    )
                }
                transitionKeyboardSession(.requestFinished)
                if !completedDeferredStop {
                    resumeKeyboardSessionKeeperIfNeeded()
                    publishKeyboardSessionReadyIfAvailable()
                }
                clearKeyboardSessionLiveActivityRoute(for: request.id)
                realtimeDictationRecorder?.cancel()
                realtimeDictationRecorder = nil
                realtimeDictationBufferPipe?.finish()
                realtimeDictationBufferPipe = nil
                realtimeDictationProcessingTask?.cancel()
                realtimeDictationProcessingTask = nil
                if failedVoiceNoteSession?.protectedAudioUntilTranscriptCompletes != true,
                   let realtimeDictationChunksDirectory {
                    try? FileManager.default.removeItem(at: realtimeDictationChunksDirectory)
                    self.realtimeDictationChunksDirectory = nil
                }
                liveDictationTranscript = ""
                realtimeDictationCommittedText = ""
                clearKeyboardLiveTranscript()
                statusText = error.localizedDescription
                refreshHistory()
                AppTelemetry.failure(
                    "dictation_failed",
                    domain: .transcription,
                    stage: VoiceNoteFailureTelemetryPolicy.stage(
                        for: failureReason,
                        standard: "transcription",
                        timeout: "transcription_timeout"
                    ),
                    error: error,
                    reason: failureReason.rawValue,
                    isTimeout: failureReason == .timeout,
                    parameters: ["engine": engine.identifier]
                )
                try? store.saveStatus(.init(requestID: request.id, phase: .failed, message: error.localizedDescription))
                if startedFromKeyboard {
                    saveKeyboardHandoff(
                        requestID: request.id,
                        phase: .failed,
                        message: error.localizedDescription
                    )
                }
            }
        }
        if let sessionID = session?.id, voiceNoteLifecycleRunner?.sessionID == sessionID {
            voiceNoteLifecycleRunner?.transcriptionTask = transcriptionTask
        }
    }

    @discardableResult
    func startMeetingRecording(title: String = "Untitled Meeting") -> UUID? {
        guard !isRecording,
              !hasMeetingRecordingInProgress,
              !isMeetingTranscribing,
              !voiceNoteLifecycleState.isWorkActive,
              activeRequest == nil,
              statusText != "Transcribing"
        else { return nil }
        MuesliHaptics.dictationStart()
        activeMeetingTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Untitled Meeting"
            : title.trimmingCharacters(in: .whitespacesAndNewlines)
        var session = RecordingSession(kind: .meeting, title: activeMeetingTitle)
        session.keepsAudioRecording = MuesliPreferences.keepMeetingAudioRecordingsEnabled
        activeSession = session
        if !recordingSessions.contains(where: { $0.id == session.id }) {
            recordingSessions.insert(session, at: 0)
        }
        meetingStatusText = "Preparing"
        beginMeetingLifecycle(sessionID: session.id, event: .startRequested(session.id))

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runMeetingStartup(session)
        }
        setMeetingStartupTask(task, sessionID: session.id)
        return session.id
    }

    private func runMeetingStartup(_ initialSession: RecordingSession) async {
        var session = initialSession

        do {
            try ensureMeetingLifecycleActive(sessionID: session.id)

            let audioURL = try store.newAudioFileURL(sessionID: session.id)
            let chunksDirectory = try meetingChunkDirectory(for: session.id)
            try? FileManager.default.removeItem(at: chunksDirectory)
            session.audioFileName = audioURL.lastPathComponent
            session.startedAt = .now
            try store.saveSession(session)
            activeSession = session
            if let index = recordingSessions.firstIndex(where: { $0.id == session.id }) {
                recordingSessions[index] = session
            }

            try ensureMeetingLifecycleActive(sessionID: session.id)

            try await recorder.requestPermission()

            try ensureMeetingLifecycleActive(sessionID: session.id)

            if keyboardSessionKeeper.isRunning {
                keyboardSessionKeeper.stop(deactivateSession: true)
                transitionKeyboardSession(.requestFinished)
                try? store.clearKeyboardRuntimeStatus()
                try? await Task.sleep(for: .milliseconds(150))
            }

            try ensureMeetingLifecycleActive(sessionID: session.id)

            let vadManager = try await VadManager()

            try ensureMeetingLifecycleActive(sessionID: session.id)

            let vadController = StreamingVadController(vadManager: vadManager)
            let streamingRecorder = StreamingMeetingRecorder()
            streamingRecorder.onRecordingFailure = { [weak self] failure in
                Task { @MainActor in
                    self?.handleMeetingRecordingWriterFailure(failure)
                }
            }
            vadController.onChunkBoundary = { [weak self] in
                Task { @MainActor [weak self] in
                    self?.rotateActiveMeetingChunk()
                }
            }
            streamingRecorder.onAudioSamples = { [vadController, meetingVadQueue] samples in
                meetingVadQueue.async {
                    vadController.processAudio(samples)
                }
            }

            try ensureMeetingLifecycleActive(sessionID: session.id)

            try streamingRecorder.start(
                chunksDirectory: chunksDirectory,
                retainedAudioURL: audioURL,
                routeStage: "meeting recording"
            )
            do {
                try ensureMeetingLifecycleActive(sessionID: session.id)
            } catch {
                vadController.stop()
                streamingRecorder.cancel()
                throw error
            }

            refreshAudioInputRoute()
            vadController.start()

            meetingRecorder = streamingRecorder
            meetingVadController = vadController
            meetingChunksDirectory = chunksDirectory
            meetingChunkTasks.removeAll(keepingCapacity: true)
            meetingChunkTranscriptions.removeAll(keepingCapacity: true)
            activeSession = session
            isMeetingRecording = true
            meetingStatusText = "Recording"
            transitionMeetingLifecycle(.recordingStarted(session.id))
            startMeetingMetering()
            prewarmModelIfNeeded(reason: "meeting_recording")
            refreshHistory()
            AppTelemetry.signal("meeting_recording_started")
            Task {
                await liveActivityController.start(
                    session: session,
                    requestID: nil,
                    phase: "Recording",
                    detail: "Meeting recording active"
                )
            }
        } catch is CancellationError {
            guard isCurrentMeetingLifecycle(sessionID: session.id) else { return }
            abortCancelledMeeting(session)
        } catch {
            guard isCurrentMeetingLifecycle(sessionID: session.id) else { return }
            session.phase = .failed
            session.errorMessage = error.localizedDescription
            cleanupNonRetainedAudio(for: &session)
            clearMissingRetainedAudioReference(for: &session)
            try? store.saveSession(session)
            activeSession = nil
            meetingStatusText = error.localizedDescription
            stopMetering()
            finishMeetingLifecycle(sessionID: session.id)
            refreshHistory()
            AppTelemetry.failure(
                "meeting_recording_failed",
                domain: .meeting,
                stage: "recording_start",
                error: error
            )
        }
    }

    func stopCurrentMeetingRecording() {
        if isMeetingRecording || meetingRecorder != nil {
            stopMeetingRecording()
            return
        }

        guard var session = activeSession ?? persistedRecordingMeetingSession,
              session.kind == .meeting
        else { return }

        if meetingLifecycleState.isStarting(sessionID: session.id) {
            stopMeetingStartup(session)
            return
        }

        guard session.audioFileName != nil else {
            stopMeetingStartup(session)
            return
        }

        session.endedAt = .now
        isMeetingRecording = false
        isMeetingTranscribing = false
        meetingRecorder = nil
        meetingVadController = nil
        activeSession = nil
        stopMetering()
        session.phase = .transcriptionQueued
        session.errorMessage = nil
        try? store.saveSession(session)
        refreshHistory()
        AppTelemetry.signal("meeting_recording_recovered_for_transcription")
        transcribeSession(session)
    }

    private func stopMeetingStartup(_ session: RecordingSession) {
        MuesliHaptics.dictationStop()
        cancelMeetingLifecycle(sessionID: session.id)
        abortCancelledMeeting(session)
        Task {
            await liveActivityController.end(
                phase: "Stopped",
                detail: "Meeting recording stopped before audio capture",
                session: session
            )
        }
        AppTelemetry.signal("meeting_recording_startup_stopped")
    }

    func cancelCurrentMeetingRecording() {
        guard isMeetingRecording || meetingRecorder != nil || activeSession?.kind == .meeting || persistedRecordingMeetingSession != nil else { return }
        guard let session = activeSession ?? persistedRecordingMeetingSession, session.kind == .meeting else { return }
        let latestSession = (try? store.recordingSession(id: session.id)) ?? session

        MuesliHaptics.dictationStop()
        isMeetingRecording = false
        isMeetingTranscribing = false
        stopMetering()
        meetingStatusText = "Ready"

        meetingVadController?.stop()
        meetingRecorder?.cancel()
        meetingRecorder = nil
        meetingVadController = nil
        activeSession = nil
        cancelMeetingLifecycle(sessionID: latestSession.id)
        cleanupMeetingChunks(cancelTasks: true)

        if let audioFileName = latestSession.audioFileName {
            try? store.deleteAudioFile(fileName: audioFileName)
        }
        try? store.deleteTranscript(for: latestSession.id)
        removeCachedTranscript(for: latestSession.id)
        try? store.deleteRecordingSession(id: latestSession.id)
        recordingSessions.removeAll { $0.id == latestSession.id }
        finishMeetingLifecycle(sessionID: latestSession.id)
        refreshHistory()
        Task {
            await liveActivityController.end(
                phase: "Discarded",
                detail: "Meeting recording discarded",
                session: latestSession
            )
        }
        AppTelemetry.signal("meeting_recording_discarded")
    }

    func stopMeetingRecording(queueForTranscription _: Bool = false) {
        guard isMeetingRecording || meetingRecorder != nil else { return }
        guard var session = activeSession ?? persistedRecordingMeetingSession, session.kind == .meeting else { return }
        MuesliHaptics.dictationStop()
        transitionMeetingLifecycle(.stopRequested(session.id))
        isMeetingRecording = false
        isMeetingTranscribing = true
        stopMetering()
        meetingStatusText = "Finishing recording"

        do {
            meetingVadController?.stop()
            let stoppedAudio = meetingRecorder?.stop()
            meetingRecorder = nil
            meetingVadController = nil
            if let writerFailure = stoppedAudio?.writerFailure {
                throw VoiceNoteCaptureFailure.writer(writerFailure)
            }
            if let finalChunk = stoppedAudio?.finalChunk {
                scheduleMeetingChunkTranscription(finalChunk, sessionID: session.id)
            }
            session.audioFileName = session.audioFileName ?? stoppedAudio?.retainedAudioURL?.lastPathComponent
            session.keepsAudioRecording = MuesliPreferences.keepMeetingAudioRecordingsEnabled
            session.endedAt = .now
            session.phase = .transcribing
            try store.saveSession(session)
            activeSession = nil
            transitionMeetingLifecycle(.transcriptionStarted(session.id))
            refreshHistory()
            Task {
                await liveActivityController.update(
                    phase: "Transcribing",
                    detail: "Processing meeting chunks",
                    session: session
                )
            }
            AppTelemetry.signal("meeting_recording_stopped", parameters: [
                "queued": "false"
            ])

            finalizeStreamingMeeting(session)
        } catch {
            session.phase = .failed
            session.errorMessage = error.localizedDescription
            try? store.saveSession(session)
            activeSession = nil
            isMeetingTranscribing = false
            meetingStatusText = error.localizedDescription
            finishMeetingLifecycle(sessionID: session.id)
            refreshHistory()
            AppTelemetry.failure(
                "meeting_recording_failed",
                domain: .meeting,
                stage: "stop",
                error: error
            )
        }
    }

    private func handleMeetingRecordingWriterFailure(_ failure: CheckpointingAudioWriterFailure) {
        guard isMeetingRecording else { return }
        meetingStatusText = "Audio could not be saved reliably. Finishing the meeting."
        AppTelemetry.failure(
            "meeting_recording_writer_failed",
            domain: .meeting,
            stage: "audio_write",
            reason: String(describing: failure)
        )
        stopMeetingRecording()
    }

    private func rotateActiveMeetingChunk() {
        guard isMeetingRecording, let session = activeSession, session.kind == .meeting else { return }
        guard let chunk = meetingRecorder?.rotateChunk() else { return }
        meetingVadController?.notifyRotation()
        scheduleMeetingChunkTranscription(chunk, sessionID: session.id)
    }

    private func scheduleMeetingChunkTranscription(_ chunk: MeetingAudioChunk, sessionID: UUID) {
        let task: Task<MeetingChunkTranscription?, Never> = Task { [engine] in
            do {
                let result = try await engine.transcribeDetailed(audioURL: chunk.url)
                try? FileManager.default.removeItem(at: chunk.url)
                return MeetingChunkTranscription(chunk: chunk, result: result)
            } catch {
                AppTelemetry.failure(
                    "meeting_chunk_transcription_failed",
                    domain: .transcription,
                    stage: "meeting_chunk",
                    error: error,
                    parameters: ["chunk_index": "\(chunk.index)"]
                )
                return nil
            }
        }
        meetingChunkTasks.append(task)

        Task { @MainActor [weak self] in
            guard let self, let transcription = await task.value else { return }
            self.meetingChunkTranscriptions.append(transcription)
            self.savePartialMeetingTranscript(sessionID: sessionID)
        }
    }

    private func savePartialMeetingTranscript(sessionID: UUID) {
        let merged = MeetingChunkTranscriptMerger.merge(meetingChunkTranscriptions)
        let text = postProcessTranscript(merged.text)
        guard !text.isEmpty else { return }
        guard isCurrentMeetingLifecycle(sessionID: sessionID),
              var session = try? store.activeRecordingSession(id: sessionID),
              session.kind == .meeting,
              session.phase != .cancelled
        else { return }

        let transcript = Transcript(
            sessionID: sessionID,
            text: text,
            engineIdentifier: engine.identifier,
            speakerTranscript: nil,
            summaryText: nil,
            diarizationState: .processing,
            summaryState: MuesliPreferences.meetingSummariesEnabled ? .processing : .notStarted
        )
        do {
            try store.saveTranscript(transcript)
        } catch {
            return
        }
        cacheTranscript(transcript)
        session.transcriptID = transcript.id
        session.engineIdentifier = engine.identifier
        _ = try? saveActiveMeetingSession(session)
        refreshHistory()
    }

    private func finalizeStreamingMeeting(_ session: RecordingSession) {
        beginTranscriptionBackgroundTask()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                endTranscriptionBackgroundTask()
                isMeetingTranscribing = false
            }

            var session = session
            do {
                try ensureMeetingLifecycleActive(sessionID: session.id)
                meetingStatusText = "Transcribing"
                for task in meetingChunkTasks {
                    if let transcription = await task.value,
                       !meetingChunkTranscriptions.contains(where: { $0.chunk.index == transcription.chunk.index }) {
                        meetingChunkTranscriptions.append(transcription)
                    }
                }
                meetingChunkTasks.removeAll(keepingCapacity: false)
                try ensureMeetingLifecycleActive(sessionID: session.id)

                let mergedTranscription = MeetingChunkTranscriptMerger.merge(meetingChunkTranscriptions)
                let text = postProcessTranscript(mergedTranscription.text)
                if let latestSession = try? store.recordingSession(id: session.id) {
                    session.manualNotes = latestSession.manualNotes
                }
                let audioURL = try session.audioFileName.map { try store.audioFileURL(fileName: $0) }
                let finalTranscript = try await finalizeMeetingTranscript(
                    session: session,
                    text: text,
                    detailedTranscription: DetailedTranscriptionResult(
                        text: text,
                        duration: mergedTranscription.duration,
                        tokens: mergedTranscription.tokens
                    ),
                    audioURL: audioURL
                )
                try ensureMeetingLifecycleActive(sessionID: session.id)

                session.phase = .completed
                session.title = finalTranscript.resolvedTitle
                session.transcriptID = finalTranscript.transcript.id
                session.engineIdentifier = engine.identifier
                session.errorMessage = nil
                cleanupNonRetainedAudio(for: &session)
                guard try saveActiveMeetingSession(session) else {
                    meetingStatusText = "Ready"
                    cleanupMeetingChunks()
                    return
                }
                scheduleICloudSyncAfterLocalChange(reason: "meeting_completed")
                cleanupMeetingChunks()
                meetingStatusText = "Ready"
                refreshHistory()
                await liveActivityController.end(
                    phase: "Completed",
                    detail: finalTranscript.transcript.summaryText == nil ? "Meeting transcript saved" : "Meeting notes saved",
                    session: session
                )
                AppTelemetry.signal("meeting_transcription_completed", parameters: [
                    "engine": engine.identifier,
                    "empty": text.isEmpty ? "true" : "false",
                    "diarized": finalTranscript.transcript.diarizationState == .completed ? "true" : "false",
                    "summarized": finalTranscript.transcript.summaryState == .completed ? "true" : "false",
                    "chunked": "true"
                ])
                finishMeetingLifecycle(sessionID: session.id)
            } catch is CancellationError {
                if isCurrentMeetingLifecycle(sessionID: session.id) {
                    finishMeetingLifecycle(sessionID: session.id)
                }
                cleanupMeetingChunks()
                meetingStatusText = "Ready"
                refreshHistory()
            } catch {
                guard isCurrentMeetingLifecycle(sessionID: session.id) else {
                    cleanupMeetingChunks()
                    meetingStatusText = "Ready"
                    refreshHistory()
                    return
                }

                session.phase = .failed
                session.errorMessage = error.localizedDescription
                cleanupNonRetainedAudio(for: &session)
                _ = try? saveActiveMeetingSession(session)
                cleanupMeetingChunks()
                meetingStatusText = error.localizedDescription
                refreshHistory()
                await liveActivityController.end(
                    phase: "Failed",
                    detail: "Transcription failed",
                    session: session
                )
                AppTelemetry.failure(
                    "meeting_transcription_failed",
                    domain: .transcription,
                    stage: "meeting_finalize_chunked",
                    error: error,
                    parameters: [
                        "engine": engine.identifier,
                        "chunked": "true"
                    ]
                )
                finishMeetingLifecycle(sessionID: session.id)
            }
        }
        setMeetingFinalizationTask(task, sessionID: session.id)
    }

    func transcribeSession(_ session: RecordingSession) {
        guard !isRecording, !hasMeetingRecordingInProgress, !isMeetingTranscribing else { return }
        guard let audioFileName = session.audioFileName else { return }
        var session = session
        session.phase = .transcribing
        session.errorMessage = nil
        try? store.saveSession(session)
        refreshHistory()
        beginMeetingLifecycle(sessionID: session.id, event: .transcriptionStarted(session.id))
        isMeetingTranscribing = true
        meetingStatusText = "Transcribing"
        Task {
            await liveActivityController.start(
                session: session,
                requestID: nil,
                phase: "Transcribing",
                detail: "Transcribing meeting locally"
            )
        }

        beginTranscriptionBackgroundTask()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                endTranscriptionBackgroundTask()
                isMeetingTranscribing = false
            }

            do {
                try ensureMeetingLifecycleActive(sessionID: session.id)
                let audioURL = try store.audioFileURL(fileName: audioFileName)
                let outcome = try await runOfflineTranscriptionJob(
                    audioURL: audioURL,
                    onProgress: { [weak self] update in
                        guard let self else { return }
                        self.meetingStatusText = self.transcriptionStatusMessage(for: update)
                    }
                ) { [weak self] in
                    guard let self else { return }
                    let message = "Transcription stalled. Try again."
                    var failedSession = session
                    failedSession.phase = .failed
                    failedSession.errorMessage = message
                    self.cleanupNonRetainedAudio(for: &failedSession)
                    try? self.store.saveSession(failedSession)
                    self.meetingStatusText = message
                    self.isMeetingTranscribing = false
                    self.refreshHistory()
                    Task {
                        await self.liveActivityController.end(
                            phase: "Failed",
                            detail: "Transcription stalled",
                            session: session
                        )
                    }
                    AppTelemetry.failure(
                        "meeting_transcription_failed",
                        domain: .transcription,
                        stage: "meeting_transcription_timeout",
                        reason: "timeout",
                        isTimeout: true,
                        parameters: ["engine": self.engine.identifier]
                    )
                    self.finishMeetingLifecycle(sessionID: session.id)
                } operation: { [engine] progress in
                    try await engine.transcribeDetailed(audioURL: audioURL, progress: progress)
                }
                guard case .completed(let detailedTranscription) = outcome else { return }
                try ensureMeetingLifecycleActive(sessionID: session.id)
                let text = postProcessTranscript(detailedTranscription.text)
                if let latestSession = try? store.recordingSession(id: session.id) {
                    session.manualNotes = latestSession.manualNotes
                }
                let finalTranscript = try await finalizeMeetingTranscript(
                    session: session,
                    text: text,
                    detailedTranscription: DetailedTranscriptionResult(
                        text: text,
                        duration: detailedTranscription.duration,
                        tokens: detailedTranscription.tokens
                    ),
                    audioURL: audioURL
                )
                try ensureMeetingLifecycleActive(sessionID: session.id)
                session.phase = .completed
                session.title = finalTranscript.resolvedTitle
                session.transcriptID = finalTranscript.transcript.id
                session.engineIdentifier = engine.identifier
                session.errorMessage = nil
                cleanupNonRetainedAudio(for: &session)
                guard try saveActiveMeetingSession(session) else { return }
                scheduleICloudSyncAfterLocalChange(reason: "meeting_completed")
                meetingStatusText = "Ready"
                refreshHistory()
                await liveActivityController.end(
                    phase: "Completed",
                    detail: finalTranscript.transcript.summaryText == nil ? "Meeting transcript saved" : "Meeting notes saved",
                    session: session
                )
                AppTelemetry.signal("meeting_transcription_completed", parameters: [
                    "engine": engine.identifier,
                    "empty": text.isEmpty ? "true" : "false",
                    "diarized": finalTranscript.transcript.diarizationState == .completed ? "true" : "false",
                    "summarized": finalTranscript.transcript.summaryState == .completed ? "true" : "false"
                ])
                finishMeetingLifecycle(sessionID: session.id)
            } catch is CancellationError {
                if isCurrentMeetingLifecycle(sessionID: session.id) {
                    finishMeetingLifecycle(sessionID: session.id)
                }
                meetingStatusText = "Ready"
                refreshHistory()
            } catch {
                guard isCurrentMeetingLifecycle(sessionID: session.id) else { return }
                session.phase = .failed
                session.errorMessage = error.localizedDescription
                cleanupNonRetainedAudio(for: &session)
                try? store.saveSession(session)
                meetingStatusText = error.localizedDescription
                refreshHistory()
                await liveActivityController.end(
                    phase: "Failed",
                    detail: "Transcription failed",
                    session: session
                )
                AppTelemetry.failure(
                    "meeting_transcription_failed",
                    domain: .transcription,
                    stage: "meeting_transcription",
                    error: error,
                    parameters: ["engine": engine.identifier]
                )
                finishMeetingLifecycle(sessionID: session.id)
            }
        }
        setMeetingFinalizationTask(task, sessionID: session.id)
    }

    private struct FinalizedMeetingTranscript {
        let transcript: Transcript
        let resolvedTitle: String?
    }

    private func finalizeMeetingTranscript(
        session: RecordingSession,
        text: String,
        detailedTranscription: DetailedTranscriptionResult,
        audioURL: URL?
    ) async throws -> FinalizedMeetingTranscript {
        var speakerTranscript: String?
        var diarizationState: MeetingProcessingState = audioURL == nil ? .unavailable : .processing
        var diarizationErrorMessage: String?

        if let audioURL {
            try ensureMeetingLifecycleActive(sessionID: session.id)
            meetingStatusText = "Diarizing"
            do {
                let diarizationSegments = try await engine.diarize(audioURL: audioURL)
                try ensureMeetingLifecycleActive(sessionID: session.id)
                speakerTranscript = MeetingTranscriptFormatter.speakerTranscript(
                    transcription: detailedTranscription,
                    diarizationSegments: diarizationSegments,
                    meetingStart: session.startedAt ?? session.createdAt
                )
                diarizationState = .completed
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                speakerTranscript = nil
                diarizationState = .failed
                diarizationErrorMessage = error.localizedDescription
                AppTelemetry.failure(
                    "meeting_diarization_failed",
                    domain: .transcription,
                    stage: "meeting_diarization",
                    error: error
                )
            }
            try ensureMeetingLifecycleActive(sessionID: session.id)
        }

        var summaryText: String?
        var summaryState: MeetingProcessingState = MuesliPreferences.meetingSummariesEnabled ? .processing : .notStarted
        var summaryBackend: String?
        var summaryModel: String?
        var summaryErrorMessage: String?
        var resolvedTitle = session.title

        if MuesliPreferences.meetingSummariesEnabled {
            try ensureMeetingLifecycleActive(sessionID: session.id)
            meetingStatusText = "Summarizing"
            let summarySource = speakerTranscript?.isEmpty == false ? speakerTranscript! : text
            do {
                let summary = try await MeetingSummaryClient.summarize(
                    transcript: summarySource,
                    meetingTitle: session.title ?? session.kind.title,
                    manualNotesToRetain: session.manualNotes
                )
                try ensureMeetingLifecycleActive(sessionID: session.id)
                summaryText = summary.notes
                summaryState = .completed
                summaryBackend = summary.backend.rawValue
                summaryModel = summary.model
                if !summary.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    resolvedTitle = summary.title
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                summaryText = MeetingSummaryClient.failureNotes(
                    transcript: summarySource,
                    meetingTitle: session.title ?? session.kind.title,
                    error: error,
                    manualNotes: session.manualNotes
                )
                summaryState = .failed
                let backend = MuesliPreferences.meetingSummaryBackend
                summaryBackend = backend.rawValue
                summaryModel = backend == .chatGPT
                    ? MuesliPreferences.chatGPTModel
                    : MuesliPreferences.openRouterModel
                summaryErrorMessage = error.localizedDescription
                AppTelemetry.failure(
                    "meeting_summary_failed",
                    domain: .summary,
                    stage: "meeting_summary",
                    error: error,
                    parameters: [
                        "backend": summaryBackend ?? "unknown",
                        "model": SummaryModelPreset.telemetryIdentifier(
                            for: summaryModel ?? "",
                            backend: backend
                        )
                    ]
                )
            }
            try ensureMeetingLifecycleActive(sessionID: session.id)
        }

        let transcript = Transcript(
            sessionID: session.id,
            text: text,
            engineIdentifier: engine.identifier,
            speakerTranscript: speakerTranscript,
            summaryText: summaryText,
            diarizationState: diarizationState,
            diarizationErrorMessage: diarizationErrorMessage,
            summaryState: summaryState,
            summaryBackend: summaryBackend,
            summaryModel: summaryModel,
            summaryErrorMessage: summaryErrorMessage
        )
        try ensureMeetingLifecycleActive(sessionID: session.id)
        try store.saveTranscript(transcript)
        cacheTranscript(transcript)
        return FinalizedMeetingTranscript(transcript: transcript, resolvedTitle: resolvedTitle)
    }

    private func meetingChunkDirectory(for sessionID: UUID) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-meeting-chunks", isDirectory: true)
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func cleanupMeetingChunks(cancelTasks: Bool = false) {
        if cancelTasks {
            meetingChunkTasks.forEach { $0.cancel() }
        }
        if let meetingChunksDirectory {
            try? FileManager.default.removeItem(at: meetingChunksDirectory)
        }
        meetingChunksDirectory = nil
        meetingChunkTasks.removeAll(keepingCapacity: false)
        meetingChunkTranscriptions.removeAll(keepingCapacity: false)
    }

    private func abortCancelledMeeting(_ session: RecordingSession) {
        let session = (try? store.recordingSession(id: session.id)) ?? session
        cleanupMeetingChunks(cancelTasks: true)
        if let audioFileName = session.audioFileName {
            try? store.deleteAudioFile(fileName: audioFileName)
        }
        try? store.deleteTranscript(for: session.id)
        removeCachedTranscript(for: session.id)
        try? store.deleteRecordingSession(id: session.id)
        activeSession = nil
        meetingRecorder = nil
        meetingVadController = nil
        isMeetingRecording = false
        isMeetingTranscribing = false
        meetingStatusText = "Ready"
        finishMeetingLifecycle(sessionID: session.id)
        refreshHistory()
    }

    @discardableResult
    private func saveActiveMeetingSession(_ session: RecordingSession) throws -> Bool {
        guard shouldContinueMeetingFinalization(sessionID: session.id) else { return false }
        try store.saveSession(session)
        return true
    }

    private func shouldContinueMeetingFinalization(sessionID: UUID) -> Bool {
        guard isCurrentMeetingLifecycle(sessionID: sessionID),
              (try? store.activeRecordingSession(id: sessionID)) != nil
        else { return false }
        return true
    }

    private func startMetering(update: @escaping @MainActor (Double) -> Void) {
        meteringTask?.cancel()
        meteringTask = Task { @MainActor [weak self] in
            var smoothedLevel = 0.0

            while !Task.isCancelled {
                guard let self else { return }
                let power = if self.keyboardSessionKeeper.isRecordingSegment {
                    Double(self.keyboardSessionKeeper.currentPower())
                } else {
                    Double(self.realtimeDictationRecorder?.currentPower() ?? self.recorder.currentPower())
                }
                let normalized = min(max((power + 50) / 50, 0), 1)
                smoothedLevel = (0.35 * normalized) + (0.65 * smoothedLevel)
                update(smoothedLevel)
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    private func startRecordingTimer(startedAt: Date) {
        recordingTimerTask?.cancel()
        recordingElapsedTime = 0
        recordingTimerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.recordingElapsedTime = max(0, Date().timeIntervalSince(startedAt))
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func stopRecordingTimer() {
        recordingTimerTask?.cancel()
        recordingTimerTask = nil
        recordingElapsedTime = 0
    }

    private func offlineTranscriptionTimeout(for audioURL: URL?) -> TimeInterval {
        guard let audioURL,
              let audioFile = try? AVAudioFile(forReading: audioURL),
              audioFile.fileFormat.sampleRate > 0
        else {
            return Self.offlineTranscriptionNoProgressTimeout
        }

        let duration = Double(audioFile.length) / audioFile.fileFormat.sampleRate
        return min(max(Self.offlineTranscriptionNoProgressTimeout, duration * 2), 300)
    }

    private func transcriptionStatusMessage(
        for update: TranscriptionProgressUpdate,
        fallback: String = "Transcribing"
    ) -> String {
        guard let fraction = update.fractionCompleted, fraction > 0, fraction < 1 else {
            return update.message ?? fallback
        }
        return "\(update.message ?? fallback) \(Int((fraction * 100).rounded()))%"
    }

    private func runOfflineTranscriptionJob<Output: Sendable>(
        audioURL: URL,
        onProgress: (@MainActor @Sendable (TranscriptionProgressUpdate) -> Void)? = nil,
        onTimeout: @escaping @MainActor @Sendable () -> Void,
        operation: @escaping @Sendable (@escaping @Sendable (TranscriptionProgressUpdate) -> Void) async throws -> Output
    ) async throws -> OfflineTranscriptionJobOutcome<Output> {
        let tracker = OfflineTranscriptionProgressTracker()
        let timeout = offlineTranscriptionTimeout(for: audioURL)
        let control = OfflineTranscriptionJobControl<Output>()
        let progressHandler: @Sendable (TranscriptionProgressUpdate) -> Void = { update in
            Task {
                await tracker.record(update)
            }
            guard let onProgress else { return }
            Task { @MainActor in
                guard !control.isFinished else { return }
                onProgress(update)
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                control.setContinuation(continuation)

                let transcriptionTask = Task {
                    do {
                        let output = try await operation(progressHandler)
                        control.resume(returning: .completed(output))
                    } catch {
                        control.resume(throwing: error)
                    }
                }
                control.setTranscriptionTask(transcriptionTask)

                let watchdogTask = Task.detached(priority: .utility) {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(2))
                        guard !Task.isCancelled else { return }
                        if await tracker.hasNoProgress(for: timeout) {
                            guard control.claimTimeout() else { return }
                            await onTimeout()
                            control.completeTimeout()
                            return
                        }
                    }
                }
                control.setWatchdogTask(watchdogTask)
            }
        } onCancel: {
            control.cancel()
        }
    }

    private func keyboardTranscriptionProgressUpdate(
        requestID: UUID,
        startedFromKeyboard: Bool,
        update: TranscriptionProgressUpdate
    ) {
        let message = transcriptionStatusMessage(for: update)
        statusText = message
        try? store.saveStatus(.init(requestID: requestID, phase: .transcribing, message: message))
        if startedFromKeyboard {
            saveKeyboardHandoff(requestID: requestID, phase: .transcribingStarted, message: message)
            saveKeyboardRuntimeStatus(
                isActive: true,
                activeRequestID: requestID,
                phase: .transcribing,
                message: message,
                supportsBackgroundStart: canStartKeyboardRequestsInBackground
            )
        }
    }

    private func runKeyboardTranscriptionJob(
        audioURL: URL,
        request: DictationRequest,
        startedFromKeyboard: Bool
    ) async throws -> OfflineTranscriptionJobOutcome<String> {
        try await runOfflineTranscriptionJob(
            audioURL: audioURL,
            onProgress: { [weak self] update in
                self?.keyboardTranscriptionProgressUpdate(
                    requestID: request.id,
                    startedFromKeyboard: startedFromKeyboard,
                    update: update
                )
            },
            onTimeout: {}
        ) { [engine] progress in
            try await engine.transcribe(audioURL: audioURL, progress: progress)
        }
    }

    private func cleanupNonRetainedAudio(for session: inout RecordingSession) {
        guard !session.protectedAudioUntilTranscriptCompletes,
              !session.keepsAudioRecording,
              let audioFileName = session.audioFileName
        else { return }

        try? store.deleteAudioFile(fileName: audioFileName)
        session.audioFileName = nil
    }

    private func clearMissingRetainedAudioReference(for session: inout RecordingSession) {
        guard session.keepsAudioRecording,
              let audioFileName = session.audioFileName,
              let audioURL = try? store.audioFileURL(fileName: audioFileName),
              !FileManager.default.fileExists(atPath: audioURL.path)
        else { return }

        session.audioFileName = nil
    }

    private func discardAudio(for session: inout RecordingSession) {
        guard let audioFileName = session.audioFileName else { return }
        try? store.deleteAudioFile(fileName: audioFileName)
        session.audioFileName = nil
        session.keepsAudioRecording = false
    }

    private func exportRetainedAudioIfNeeded(for session: RecordingSession) {
        guard session.keepsAudioRecording,
              let audioFileName = session.audioFileName
        else { return }

        _ = try? store.exportAudioFileToDocuments(fileName: audioFileName)
    }

    private func startMeetingMetering() {
        meteringTask?.cancel()
        meteringTask = Task { @MainActor [weak self] in
            var smoothedLevel = 0.0

            while !Task.isCancelled {
                guard let self else { return }
                let power = Double(self.meetingRecorder?.currentPower() ?? -160)
                let normalized = min(max((power + 50) / 50, 0), 1)
                smoothedLevel = (0.35 * normalized) + (0.65 * smoothedLevel)
                self.inputLevel = smoothedLevel
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    private func stopMetering() {
        meteringTask?.cancel()
        meteringTask = nil
        inputLevel = 0
        onboardingTestInputLevel = 0
    }

    private func startCommandPolling(for requestID: UUID) {
        commandPollingTask?.cancel()
        commandPollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let command = try? self.store.pendingCommand(), command.requestID == requestID {
                    try? self.store.clearPendingCommand()
                    switch command.action {
                    case .start:
                        break
                    case .stop:
                        self.saveKeyboardHandoff(
                            requestID: requestID,
                            phase: .stopAcknowledged,
                            message: "Stopping"
                        )
                        self.stopRecording(requestID: requestID)
                    case .cancel:
                        self.saveKeyboardHandoff(
                            requestID: requestID,
                            phase: .cancelled,
                            message: "Cancelled"
                        )
                        self.cancelRecording(requestID: requestID)
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func stopCommandPolling() {
        commandPollingTask?.cancel()
        commandPollingTask = nil
    }

    private func startKeyboardRuntimePolling() {
        guard keyboardRuntimePollingTask == nil else { return }
        refreshKeyboardRuntimeHeartbeat()

        keyboardRuntimePollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.processKeyboardRuntimeTick()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func handleKeyboardSessionInputActivity(powerDB: Float, isCapturing: Bool) async {
        guard MuesliPreferences.keyboardSessionModeEnabled || isCapturing else { return }
        let normalized = min(max((Double(powerDB) + 50) / 50, 0), 1)
        await processKeyboardRuntimeTick(inputLevel: normalized)
    }

    private func processKeyboardRuntimeTick(inputLevel: Double? = nil) async {
        guard !keyboardRuntimeTickInProgress else { return }
        keyboardRuntimeTickInProgress = true
        defer { keyboardRuntimeTickInProgress = false }

        if isKeyboardSessionArmed,
           !keyboardSessionKeeper.isRunning,
           !isRecording,
           !hasMeetingRecordingInProgress,
           activeRequest == nil
        {
            _ = await ensureKeyboardSessionKeeperRunning(publishReady: false)
        }
        refreshKeyboardRuntimeHeartbeat(inputLevel: inputLevel)

        guard let command = try? store.pendingCommand() else { return }
        try? store.clearPendingCommand()
        guard !rejectConflictingKeyboardCommand(
            requestID: command.requestID,
            action: command.action
        ) else { return }
        switch command.action {
        case .start:
            break
        case .stop:
            saveKeyboardHandoff(
                requestID: command.requestID,
                phase: .stopAcknowledged,
                message: "Stopping"
            )
            stopRecording(requestID: command.requestID)
            return
        case .cancel:
            saveKeyboardHandoff(
                requestID: command.requestID,
                phase: .cancelled,
                message: "Cancelled"
            )
            cancelRecording(requestID: command.requestID)
            return
        }

        let pendingRequest = try? store.pendingRequest()
        let request = pendingRequest?.id == command.requestID
            ? pendingRequest!
            : DictationRequest(id: command.requestID)

        if refreshActiveKeyboardRequestIfNeeded(request) {
            return
        }

        guard !isRecording, !hasMeetingRecordingInProgress, statusText != "Transcribing" else {
            saveKeyboardHandoff(
                requestID: command.requestID,
                phase: .failed,
                message: "Muesli is busy"
            )
            try? store.saveStatus(.init(
                requestID: command.requestID,
                phase: .failed,
                message: "Muesli is busy"
            ))
            return
        }

        transitionKeyboardSession(.handoffStarted(request.id))
        startRecording(for: request, source: "keyboard")
    }

    private func refreshKeyboardRuntimeHeartbeat(inputLevel: Double? = nil) {
        let phase: DictationPhase
        let message: String

        if isRecording {
            phase = .recording
            message = "Listening"
        } else if activeRequest != nil && statusText == "Transcribing" {
            phase = .transcribing
            message = "Transcribing"
        } else if isKeyboardSessionArmed {
            phase = .idle
            message = "Keyboard session ready"
        } else {
            phase = .idle
            message = "Ready"
        }

        saveKeyboardRuntimeStatus(
            isActive: isKeyboardHotMicEngineReady || isRecording || activeRequest != nil,
            activeRequestID: activeRequest?.id,
            phase: phase,
            message: message,
            supportsBackgroundStart: canStartKeyboardRequestsInBackground,
            inputLevel: inputLevel
        )
    }

    private func publishKeyboardSessionReadyIfAvailable() {
        guard MuesliPreferences.keyboardSessionModeEnabled, canStartKeyboardRequestsInBackground else { return }
        startKeyboardRuntimePolling()
        saveKeyboardRuntimeStatus(
            isActive: true,
            activeRequestID: nil,
            phase: .idle,
            message: "Keyboard session ready",
            supportsBackgroundStart: true
        )
    }

    @discardableResult
    private func ensureKeyboardSessionKeeperRunning(publishReady: Bool = true) async -> Bool {
        guard MuesliPreferences.keyboardSessionModeEnabled, isKeyboardSessionArmed else { return false }
        if keyboardSessionKeeper.canAcceptStartCommand {
            if publishReady, !isRecording, !hasMeetingRecordingInProgress, activeRequest == nil {
                publishKeyboardSessionReadyIfAvailable()
            }
            return true
        }
        guard !isRecording, !hasMeetingRecordingInProgress else { return false }
        if keyboardSessionKeeper.isRunning {
            let becameReady = await keyboardSessionKeeper.waitUntilCanAcceptStartCommand(timeout: 0.75)
            if becameReady {
                if publishReady, activeRequest == nil {
                    publishKeyboardSessionReadyIfAvailable()
                }
                return true
            }
            keyboardSessionKeeper.stop(deactivateSession: false)
            try? await Task.sleep(for: .milliseconds(150))
        }

        transitionKeyboardSession(.resumeRequested)
        do {
            try await keyboardSessionKeeper.start()
            guard !abortKeyboardSessionStartIfModeDisabled() else { return false }
            guard await keyboardSessionKeeper.waitUntilCanAcceptStartCommand() else {
                throw AudioRecorder.RecordingError.startFailed(stage: "keyboard session input")
            }
            guard !abortKeyboardSessionStartIfModeDisabled() else { return false }
            keyboardSessionRetryTask?.cancel()
            keyboardSessionRetryTask = nil
            keyboardSessionRetryAttempt = 0
            transitionKeyboardSession(.startSucceeded)
            if publishReady, activeRequest == nil {
                saveKeyboardRuntimeStatus(
                    isActive: true,
                    activeRequestID: nil,
                    phase: .idle,
                    message: "Keyboard session ready",
                    supportsBackgroundStart: true
                )
            }
            if let session = keyboardSessionActivitySession {
                await liveActivityController.start(
                    session: session,
                    requestID: nil,
                    phase: "Ready",
                    detail: "Keyboard voice note session active"
                )
            }
            return true
        } catch {
            let isRecoverable = isRecoverableKeyboardSessionError(error)
            if isRecoverable {
                transitionKeyboardSession(.retryScheduled(message: Self.keyboardSessionRetryMessage))
                scheduleKeyboardSessionRetry()
            } else {
                keyboardSessionRetryAttempt = 0
                transitionKeyboardSession(.startFailed(message: error.localizedDescription, recoverable: false))
            }
            saveKeyboardRuntimeStatus(
                isActive: false,
                activeRequestID: nil,
                phase: .failed,
                message: isRecoverable ? Self.keyboardSessionRetryMessage : error.localizedDescription
            )
            return false
        }
    }

    private func saveKeyboardRuntimeStatus(
        isActive: Bool,
        activeRequestID: UUID?,
        phase: DictationPhase,
        message: String?,
        supportsBackgroundStart: Bool = false,
        inputLevel: Double? = nil
    ) {
        let runtimeInputLevel = inputLevel ?? (phase == .recording ? self.inputLevel : 0)
        let canAcceptStartCommand = isActive
            && supportsBackgroundStart
            && activeRequestID == nil
            && phase == .idle
        try? store.saveKeyboardRuntimeStatus(.init(
            isActive: isActive,
            activeRequestID: activeRequestID,
            phase: phase,
            message: message,
            supportsBackgroundStart: supportsBackgroundStart,
            canAcceptStartCommand: canAcceptStartCommand,
            inputLevel: runtimeInputLevel
        ))
    }

    private func publishKeyboardRuntimeLevel(_ level: Double, requestID: UUID) {
        guard activeRequest?.id == requestID, isRecording else { return }

        let now = Date()
        guard now.timeIntervalSince(lastKeyboardRuntimeLevelWriteAt) >= 0.08 else { return }
        lastKeyboardRuntimeLevelWriteAt = now
        saveKeyboardRuntimeStatus(
            isActive: true,
            activeRequestID: requestID,
            phase: .recording,
            message: "Listening",
            supportsBackgroundStart: canStartKeyboardRequestsInBackground,
            inputLevel: level
        )
    }

    private func saveKeyboardHandoff(
        requestID: UUID,
        phase: KeyboardHandoffPhase,
        message: String? = nil
    ) {
        let previous = try? store.keyboardHandoffState()
        let state: KeyboardHandoffState
        if let previous, previous.requestID == requestID {
            state = previous.advanced(to: phase, message: message)
        } else {
            state = KeyboardHandoffState(requestID: requestID, phase: phase, message: message)
        }
        try? store.saveKeyboardHandoffState(state)
    }

    private func saveKeyboardLiveTranscript(text: String, isFinal: Bool) {
        guard isKeyboardHandoffActive, let requestID = activeRequest?.id else { return }

        let cleanedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedText.isEmpty else {
            clearKeyboardLiveTranscript()
            return
        }

        try? store.saveKeyboardLiveTranscript(.init(
            requestID: requestID,
            text: cleanedText,
            isFinal: isFinal
        ))
    }

    private func clearKeyboardLiveTranscript() {
        try? store.clearKeyboardLiveTranscript()
    }

    private func scheduleKeyboardSessionRetry(attempt: Int? = nil) {
        guard MuesliPreferences.keyboardSessionModeEnabled else { return }
        let retryAttempt = attempt ?? (keyboardSessionRetryAttempt + 1)
        guard retryAttempt <= Self.keyboardSessionMaxRetryAttempts else {
            keyboardSessionRetryTask?.cancel()
            keyboardSessionRetryTask = nil
            keyboardSessionRetryAttempt = 0
            transitionKeyboardSession(.startFailed(message: Self.keyboardSessionUnavailableMessage, recoverable: false))
            saveKeyboardRuntimeStatus(
                isActive: false,
                activeRequestID: nil,
                phase: .failed,
                message: Self.keyboardSessionUnavailableMessage
            )
            return
        }

        keyboardSessionRetryAttempt = retryAttempt
        let delay = Self.keyboardSessionRetryBaseDelaySeconds * pow(2, Double(retryAttempt - 1))
        keyboardSessionRetryTask?.cancel()
        keyboardSessionRetryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  MuesliPreferences.keyboardSessionModeEnabled,
                  !self.keyboardSessionKeeper.canAcceptStartCommand
            else { return }

            guard !self.keyboardSessionState.isWorkflowActive,
                  !self.isRecording,
                  !self.hasMeetingRecordingInProgress,
                  self.activeRequest == nil
            else {
                self.scheduleKeyboardSessionRetry(attempt: retryAttempt)
                return
            }

            await self.startKeyboardSessionMode()
        }
    }

    private func resumeKeyboardSessionKeeperIfNeeded() {
        guard MuesliPreferences.keyboardSessionModeEnabled,
              isKeyboardSessionArmed,
              !isRecording,
              !hasMeetingRecordingInProgress
        else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.ensureKeyboardSessionKeeperRunning()
        }
    }

    @discardableResult
    private func completeDeferredKeyboardSessionStopIfNeeded() -> Bool {
        guard stopKeyboardSessionAfterCurrentRequest,
              activeRequest == nil,
              !isRecording
        else { return false }

        stopKeyboardSessionMode(reason: .turnedOff)
        return true
    }

    private func beginTranscriptionBackgroundTask() {
        endTranscriptionBackgroundTask()
        transcriptionBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "MuesliTranscription") { [weak self] in
            Task { @MainActor in
                self?.endTranscriptionBackgroundTask()
            }
        }
    }

    private func endTranscriptionBackgroundTask() {
        guard transcriptionBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(transcriptionBackgroundTask)
        transcriptionBackgroundTask = .invalid
    }

    private func cancelRecording(requestID: UUID) {
        guard activeRequest?.id == requestID else {
            if let pendingRequest = try? store.pendingRequest(), pendingRequest.id == requestID {
                try? store.clearPendingRequest()
            }
            clearKeyboardSessionLiveActivityRoute(for: requestID)
            if activeRequest == nil {
                try? store.saveStatus(.idle)
                saveKeyboardRuntimeStatus(
                    isActive: canStartKeyboardRequestsInBackground,
                    activeRequestID: nil,
                    phase: .idle,
                    message: isKeyboardSessionArmed ? "Keyboard session ready" : "Ready",
                    supportsBackgroundStart: canStartKeyboardRequestsInBackground
                )
            }
            saveKeyboardHandoff(requestID: requestID, phase: .cancelled, message: "Cancelled")
            return
        }
        if let session = activeSession {
            guard transitionVoiceNoteLifecycle(.cancelRequested(session.id)) else { return }
        } else {
            guard isRecording else { return }
        }
        isRecording = false
        let usesKeyboardSessionLiveActivity = usesKeyboardSessionLiveActivity(for: requestID)
        stopMetering()
        stopRecordingTimer()
        stopCommandPolling()
        if usesKeyboardSessionLiveActivity {
            keyboardSessionKeeper.cancelSegment()
        } else {
            _ = try? recorder.stop()
            cleanupRealtimeDictationRecorder()
        }
        if var session = activeSession {
            stopVoiceNoteRecordingTasks(sessionID: session.id)
            session.phase = .cancelled
            session.endedAt = .now
            discardAudio(for: &session)
            try? store.saveSession(session)
            if session.longFormThresholdSeconds != nil {
                Task {
                    try? await voiceNoteCheckpointStore.delete(sessionID: session.id)
                }
            }
            finishVoiceNoteLifecycle(sessionID: session.id)
            if let index = recordingSessions.firstIndex(where: { $0.id == session.id }) {
                recordingSessions[index] = session
            }
            if usesKeyboardSessionLiveActivity {
                refreshKeyboardSessionLiveActivity(
                    phase: "Ready",
                    detail: "Keyboard voice note session active"
                )
            } else {
                Task {
                    await liveActivityController.end(
                        phase: "Cancelled",
                        detail: "Recording cancelled",
                        session: session
                    )
                }
            }
        }
        clearKeyboardSessionLiveActivityRoute(for: requestID)
        activeRequest = nil
        activeSession = nil
        if completeDeferredKeyboardSessionStopIfNeeded() {
            transitionKeyboardSession(.requestFinished)
            statusText = "Ready"
            try? store.clearPendingCommand()
            try? store.clearPendingRequest()
            try? store.saveStatus(.idle)
            saveKeyboardHandoff(requestID: requestID, phase: .cancelled, message: "Cancelled")
            clearKeyboardLiveTranscript()
            return
        }
        resumeKeyboardSessionKeeperIfNeeded()
        saveKeyboardRuntimeStatus(
            isActive: canStartKeyboardRequestsInBackground,
            activeRequestID: nil,
            phase: .idle,
            message: isKeyboardSessionArmed ? "Keyboard session ready" : "Ready",
            supportsBackgroundStart: canStartKeyboardRequestsInBackground
        )
        transitionKeyboardSession(.requestFinished)
        statusText = "Ready"
        try? store.clearPendingCommand()
        try? store.clearPendingRequest()
        try? store.saveStatus(.idle)
        saveKeyboardHandoff(requestID: requestID, phase: .cancelled, message: "Cancelled")
        clearKeyboardLiveTranscript()
    }

    private func isRecordingSessionCancelled(requestID: UUID) -> Bool {
        if activeSession?.requestID == requestID, activeSession?.phase == .cancelled {
            return true
        }

        do {
            guard let session = try store.recordingSession(requestID: requestID) else { return false }
            return session.phase == .cancelled
        } catch {
            return false
        }
    }

    private func cleanupRealtimeDictationRecorder() {
        realtimeDictationRecorder?.cancel()
        realtimeDictationRecorder = nil
        realtimeDictationBufferPipe?.finish()
        realtimeDictationBufferPipe = nil
        realtimeDictationProcessingTask?.cancel()
        realtimeDictationProcessingTask = nil
        isRealtimeDictationSessionActive = false
        if let realtimeDictationChunksDirectory {
            try? FileManager.default.removeItem(at: realtimeDictationChunksDirectory)
        }
        realtimeDictationChunksDirectory = nil
        realtimeDictationCommittedText = ""
        liveDictationTranscript = ""
    }
}

private actor OfflineTranscriptionProgressTracker {
    private var lastProgressAt = Date()

    func record(_ update: TranscriptionProgressUpdate) {
        lastProgressAt = update.updatedAt
    }

    func hasNoProgress(for timeout: TimeInterval, now: Date = .now) -> Bool {
        now.timeIntervalSince(lastProgressAt) >= timeout
    }
}

private enum OfflineTranscriptionJobOutcome<Output: Sendable>: Sendable {
    case completed(Output)
    case timedOut
}

private enum VoiceNoteRetryError: LocalizedError {
    case timeout

    var errorDescription: String? {
        switch self {
        case .timeout:
            "Transcription stalled. Open Muesli to try again."
        }
    }
}

private enum VoiceNoteCaptureFailure: LocalizedError {
    case writer(CheckpointingAudioWriterFailure)
    case missingDurableCheckpoint
    case invalidLifecycleTransition

    var failureReason: VoiceNoteTranscriptionFailureReason {
        switch self {
        case .writer, .missingDurableCheckpoint:
            .checkpointFailure
        case .invalidLifecycleTransition:
            .unknown
        }
    }

    var errorDescription: String? {
        switch self {
        case .writer:
            "Audio could not be finalized reliably. Your recoverable audio was kept."
        case .missingDurableCheckpoint:
            "No durable audio checkpoint was available. Any recoverable audio was kept."
        case .invalidLifecycleTransition:
            "Voice note processing stopped because its lifecycle changed unexpectedly."
        }
    }
}

private final class OfflineTranscriptionJobControl<Output: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<OfflineTranscriptionJobOutcome<Output>, Error>?
    private var pendingCompletion: Result<OfflineTranscriptionJobOutcome<Output>, Error>?
    private var transcriptionTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var didFinish = false

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didFinish
    }

    func setContinuation(_ continuation: CheckedContinuation<OfflineTranscriptionJobOutcome<Output>, Error>) {
        lock.lock()
        let pendingCompletion = pendingCompletion
        if pendingCompletion == nil {
            self.continuation = continuation
        }
        lock.unlock()

        if let pendingCompletion {
            continuation.resume(with: pendingCompletion)
        }
    }

    func setTranscriptionTask(_ task: Task<Void, Never>) {
        lock.lock()
        if didFinish {
            lock.unlock()
            task.cancel()
        } else {
            transcriptionTask = task
            lock.unlock()
        }
    }

    func setWatchdogTask(_ task: Task<Void, Never>) {
        lock.lock()
        if didFinish {
            lock.unlock()
            task.cancel()
        } else {
            watchdogTask = task
            lock.unlock()
        }
    }

    func resume(returning outcome: OfflineTranscriptionJobOutcome<Output>) {
        finish(.success(outcome), cancelTranscription: false)
    }

    func resume(throwing error: Error) {
        finish(.failure(error), cancelTranscription: false)
    }

    func claimTimeout() -> Bool {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return false
        }
        didFinish = true
        let transcriptionTask = transcriptionTask
        self.transcriptionTask = nil
        let watchdogTask = watchdogTask
        self.watchdogTask = nil
        lock.unlock()

        watchdogTask?.cancel()
        transcriptionTask?.cancel()
        return true
    }

    func completeTimeout() {
        completeClaimedFinish(.success(.timedOut))
    }

    func cancel() {
        finish(.failure(CancellationError()), cancelTranscription: true)
    }

    private func completeClaimedFinish(_ result: Result<OfflineTranscriptionJobOutcome<Output>, Error>) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        if continuation == nil {
            pendingCompletion = result
        }
        lock.unlock()

        continuation?.resume(with: result)
    }

    private func finish(
        _ result: Result<OfflineTranscriptionJobOutcome<Output>, Error>,
        cancelTranscription: Bool
    ) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        let continuation = continuation
        self.continuation = nil
        if continuation == nil {
            pendingCompletion = result
        }
        let transcriptionTask = transcriptionTask
        self.transcriptionTask = nil
        let watchdogTask = watchdogTask
        self.watchdogTask = nil
        lock.unlock()

        watchdogTask?.cancel()
        if cancelTranscription {
            transcriptionTask?.cancel()
        }
        continuation?.resume(with: result)
    }
}

extension DictationCoordinator: ModelBackgroundDownloadServiceDelegate {
    func modelBackgroundDownloadDidUpdate(model: LocalTranscriptionModel, progress: Double, detail: String) {
        guard selectedTranscriptionModel == model else { return }
        modelPreparation = ModelPreparationState(
            phase: .downloading,
            progress: progress,
            status: "Downloading \(model.shortName)",
            detail: detail
        )
    }

    func modelBackgroundDownloadDidFinish(model: LocalTranscriptionModel) {
        guard selectedTranscriptionModel == model else { return }
        modelPreparation = ModelPreparationState(
            phase: .preparing,
            progress: nil,
            status: "Optimizing for this iPhone...",
            detail: "Download complete"
        )
        prepareDownloadedModelAfterBackgroundDownload(model)
    }

    func modelBackgroundDownloadDidFail(model: LocalTranscriptionModel, message: String) {
        guard selectedTranscriptionModel == model else { return }
        modelPreparationTask = nil
        modelPreparation = ModelPreparationState(
            phase: .failed,
            progress: nil,
            status: "Download paused",
            detail: message
        )
        AppTelemetry.failure(
            "model_prepare_failed",
            domain: .model,
            stage: "background_download",
            reason: "background_download_failed",
            parameters: ["engine": model.engineIdentifier]
        )
    }
}

private struct SendableAudioBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

private final class RealtimeAudioBufferPipe: @unchecked Sendable {
    let stream: AsyncStream<SendableAudioBuffer>
    private let lock = NSLock()
    private var continuation: AsyncStream<SendableAudioBuffer>.Continuation?

    init() {
        var streamContinuation: AsyncStream<SendableAudioBuffer>.Continuation?
        stream = AsyncStream<SendableAudioBuffer> { continuation in
            streamContinuation = continuation
        }
        continuation = streamContinuation
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let continuation = continuation
        lock.unlock()
        continuation?.yield(SendableAudioBuffer(buffer: buffer))
    }

    func finish() {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.finish()
    }
}
