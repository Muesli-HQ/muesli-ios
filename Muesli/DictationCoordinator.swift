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

@MainActor
@Observable
final class DictationCoordinator {
    private static let onboardingCompletedKey = "muesli.onboarding.completed"
    private static let userNameKey = "muesli.onboarding.userName"
    private static let useCaseKey = "muesli.onboarding.useCase"
    private static let offlineTranscriptionNoProgressTimeout: TimeInterval = 90

    private let store: SharedStore
    private let eventBus: any CrossProcessEventStreaming
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
    @ObservationIgnored private var recordingTimerStartedAt: Date?
    @ObservationIgnored nonisolated(unsafe) private var sharedEventObservationTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var longVoiceNoteRecoveryTask: Task<Void, Never>?
    private var keyboardCommandProcessingInProgress = false
    private var keyboardSessionRetryTask: Task<Void, Never>?
    private var keyboardSessionRetryAttempt = 0
    private var keyboardWaveformLevelThrottle = MuesliWaveformLevelThrottle()
    private let keyboardRuntimeStatusQueue = DispatchQueue(
        label: "com.phequals7.muesli.keyboard-runtime-status",
        qos: .utility
    )
    private var persistentKeyboardSessionRequestIDs = Set<UUID>()
    private var iCloudSyncTask: Task<Void, Never>?
    private var iCloudSyncDebounceTask: Task<Void, Never>?
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
        return hasCompletedOnboarding && !isSelectedModelDownloadSuppressed
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
            && !isRemovingTranscriptionModel
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
            UserDefaults.standard.removeObject(
                forKey: MuesliPreferences.manuallyRemovedTranscriptionModelKey
            )
            UserDefaults.standard.set(
                selectedTranscriptionModel.rawValue,
                forKey: MuesliPreferences.transcriptionModelKey
            )
            let preparationTask = modelPreparationTask
            modelPreparationTask = nil
            preparationTask?.cancel()
            modelPrewarmTask?.cancel()
            modelPrewarmTask = nil
            modelPreparation = ModelPreparationState(
                status: "\(selectedTranscriptionModel.shortName) is not downloaded",
                detail: selectedTranscriptionModel.detail
            )
            AppTelemetry.signal(
                "transcription_model_selected",
                parameters: ["engine": selectedTranscriptionModel.engineIdentifier]
            )
            automaticallyPrepareSelectedModelIfNeeded()
        }
    }
    var modelPreparation = ModelPreparationState()
    var isRemovingTranscriptionModel = false
    var canRemoveDownloadedModels: Bool {
        !isRemovingTranscriptionModel
            && !modelPreparation.isPreparing
            && !isModelPrewarmInProgress
            && !isRecording
            && !hasMeetingRecordingInProgress
            && !isMeetingTranscribing
            && !voiceNoteLifecycleState.isWorkActive
            && !keyboardSessionState.isWorkflowActive
            && activeRequest == nil
            && statusText != "Transcribing"
    }
    private var isSelectedModelDownloadSuppressed: Bool {
        MuesliPreferences.manuallyRemovedTranscriptionModel == selectedTranscriptionModel
            && !selectedTranscriptionModel.isDownloaded
    }
    var isOnboardingTestRecording = false
    var isOnboardingTestTranscribing = false
    var onboardingTestInputLevel = 0.0
    var onboardingTestTranscript = ""
    var onboardingTestError: String?
    var isRecording = false
    let voiceNoteLiveState = VoiceNoteLiveState()
    var inputLevel: Double {
        get { voiceNoteLiveState.inputLevel }
        set { voiceNoteLiveState.setInputLevel(newValue) }
    }
    var recordingElapsedTime: TimeInterval {
        get { TimeInterval(voiceNoteLiveState.elapsedSeconds) }
        set { voiceNoteLiveState.setElapsedTime(newValue) }
    }
    var statusText = "Ready"
    var audioInputRouteText = AudioInputRouteManager.currentSnapshot().displayText
    var meetingStatusText = "Ready"
    var lastTranscript = ""
    var liveDictationTranscript: String {
        get { voiceNoteLiveState.transcript }
        set { voiceNoteLiveState.setTranscript(newValue) }
    }
    var dictationHistory: [DictationResult] = []
    var recordingSessions: [RecordingSession] = []
    private var transcriptCache: [UUID: Transcript] = [:]
    var isMeetingRecording: Bool {
        meetingPresentationState.isCapturing
            && meetingLifecycleState.isRecording
            && meetingRecorder != nil
    }
    var isMeetingTranscribing: Bool { meetingPresentationState.isProcessing }
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
        meetingPresentationState.isBusy
    }

    var isMeetingRecoveryNeeded: Bool {
        meetingPresentationState.needsRecovery
    }

    var isMeetingCaptureVisible: Bool {
        meetingPresentationState.isCapturing || meetingPresentationState.needsRecovery
    }

    func canStopMeetingCapture(sessionID: UUID) -> Bool {
        if meetingPresentationState == .capturing(sessionID),
           meetingLifecycleState.activeSessionID == sessionID {
            return meetingLifecycleState.acceptsCaptureStopRequest
        }
        return meetingPresentationState == .recovery(sessionID)
    }

    func isActivelyRecordingMeeting(sessionID: UUID) -> Bool {
        isMeetingRecording && activeMeetingSessionID == sessionID
    }

    func meetingNeedsRecovery(sessionID: UUID) -> Bool {
        meetingPresentationState == .recovery(sessionID)
    }

    var activeMeetingSessionID: UUID? {
        meetingPresentationState.sessionID
    }

    var effectiveMeetingStatusText: String {
        if isMeetingRecoveryNeeded {
            "Interrupted — choose Stop to recover the saved audio"
        } else if isMeetingRecording {
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

    private var meetingPresentationState: MeetingPresentationState {
        let runtimeSession = meetingLifecycleState.activeSessionID.flatMap { sessionID in
            recordingSessions.first(where: { $0.id == sessionID && $0.kind == .meeting })
        }
        let recoverySession = runtimeSession == nil ? persistedRecordingMeetingSession : nil
        return MeetingPresentationPolicy.state(for: MeetingPresentationSnapshot(
            runtime: meetingLifecycleState,
            persistedSessionID: runtimeSession?.id ?? recoverySession?.id,
            persistedPhase: runtimeSession?.phase ?? recoverySession?.phase,
            recorderIsPresent: meetingRecorder != nil
        ))
    }

    init(
        store: SharedStore? = nil,
        eventBus: any CrossProcessEventStreaming = DarwinCrossProcessEventBus.shared
    ) {
        let store = store ?? SharedStore(eventPoster: eventBus)
        self.store = store
        self.eventBus = eventBus
        voiceNoteCheckpointStore = VoiceNoteCheckpointStore(store: store)
        ModelBackgroundDownloadService.shared.delegate = self

        #if DEBUG
        let isConfiguringForUITesting = Self.shouldConfigureForUITestingFromLaunchArguments()
        if isConfiguringForUITesting {
            configureForUITesting()
        } else if Self.shouldResetOnboardingFromLaunchArguments() {
            resetOnboardingForTesting()
        }
        #else
        let isConfiguringForUITesting = false
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
            guard let type = rawType.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) else { return }
            let rawReason = notification.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt
            let reason = rawReason.flatMap(AVAudioSession.InterruptionReason.init(rawValue:))
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
            Task { @MainActor in
                self?.handleAudioSessionInterruption(
                    type: type,
                    cause: Self.meetingInterruptionCause(for: reason),
                    shouldResume: shouldResume
                )
            }
        }
        mediaServicesResetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleAudioServicesReset()
            }
        }
        keyboardSessionKeeper.onRecordingFailure = { [weak self] failure in
            Task { @MainActor in
                self?.handleVoiceNoteWriterFailure(failure)
            }
        }
        startSharedEventObservation()
        MeetingLiveActivityActionDispatcher.register { [weak self] sessionID in
            self?.stopMeetingRecordingFromLiveActivity(sessionID: sessionID) ?? .unavailable
        }

        refreshAudioInputRoute()
        if !isConfiguringForUITesting {
            refreshHistory()
            recoverLongVoiceNotesIfNeeded()
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
        sharedEventObservationTask?.cancel()
        longVoiceNoteRecoveryTask?.cancel()
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

    @discardableResult
    private func transitionMeetingLifecycle(_ event: MeetingLifecycleEvent) -> Bool {
        let previousState = meetingLifecycleState
        let transition = MeetingLifecycleReducer.transition(previousState, event: event)
        meetingLifecycleState = transition.state
        if !transition.accepted {
            AppTelemetry.failure(
                "meeting_lifecycle_transition_rejected",
                domain: .stateMachine,
                stage: "meeting_lifecycle",
                reason: "invalid_transition",
                parameters: [
                    "from_phase": previousState.phase.telemetryName,
                    "event": event.telemetryName,
                ]
            )
        }
        return transition.accepted
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

    private func prepareVoiceNoteLifecycleForPersistedRetry(sessionID: UUID) -> Bool {
        guard !voiceNoteLifecycleState.isWorkActive else { return false }
        guard let previousSessionID = voiceNoteLifecycleState.activeSessionID,
              previousSessionID != sessionID
        else { return true }
        return transitionVoiceNoteLifecycle(.finished(previousSessionID))
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
        let session = activeSession,
        session.id == sessionID
        else { return }

        guard longVoiceNoteAudioIsSecured,
              session.hasDurableAudioCheckpoint
        else {
            handleVoiceNoteWriterFailure(.checkpointRotation)
            return
        }
        _ = promoteActiveVoiceNoteToLongForm(sessionID: sessionID)
    }

    @discardableResult
    private func promoteActiveVoiceNoteToLongForm(sessionID: UUID) -> RecordingSession? {
        guard let runner = voiceNoteLifecycleRunner,
              runner.sessionID == sessionID,
              isRecording,
              var session = activeSession,
              session.id == sessionID
        else { return nil }

        switch voiceNoteLifecycleState.phase {
        case .recordingShort(let activeID) where activeID == sessionID:
            guard transitionVoiceNoteLifecycle(.longFormActivated(sessionID)) else { return nil }
        case .recordingLongProtected(let activeID) where activeID == sessionID:
            break
        default:
            return nil
        }

        let isFirstActivation = !session.isLongForm
        session.isLongForm = true
        session.longFormActivatedAt = session.longFormActivatedAt ?? .now
        session.protectedAudioUntilTranscriptCompletes = session.hasDurableAudioCheckpoint
        session.lastTranscriptionFailureReason = nil
        activeSession = session
        try? store.saveSession(session)

        guard isFirstActivation else { return session }
        if session.kind == .quickDictation {
            presentedLongVoiceNoteSessionID = session.id
        }
        if session.hasDurableAudioCheckpoint {
            statusText = "Audio saved locally"
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

        let durabilityDetail = session.hasDurableAudioCheckpoint
            ? "Audio protected locally"
            : "Securing audio"
        if session.kind == .keyboardDictation {
            refreshKeyboardSessionLiveActivity(
                phase: "Long voice note",
                detail: durabilityDetail
            )
        } else {
            Task {
                await liveActivityController.update(
                    phase: "Long voice note",
                    detail: durabilityDetail,
                    session: session
                )
            }
        }
        return session
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

    private static func meetingInterruptionCause(
        for reason: AVAudioSession.InterruptionReason?
    ) -> MeetingAudioInterruptionCause {
        switch reason {
        case .routeDisconnected: .routeDisconnected
        case .builtInMicMuted: .microphoneMuted
        case .none, .default, .appWasSuspended: .system
        @unknown default: .system
        }
    }

    private func handleAudioSessionInterruption(
        type: AVAudioSession.InterruptionType,
        cause: MeetingAudioInterruptionCause,
        shouldResume: Bool
    ) {
        if meetingLifecycleState.isRecordingVisible || meetingRecorder != nil {
            if type == .ended {
                resumeMeetingCaptureAfterInterruptionIfNeeded(
                    cause: cause,
                    shouldResume: shouldResume
                )
                return
            }
            switch MeetingAudioInterruptionPolicy.disposition(for: cause) {
            case .keepCaptureAlive:
                AppTelemetry.signal(
                    "meeting_audio_interruption_began",
                    parameters: ["cause": cause.rawValue]
                )
            case .finalizeForRecovery:
                handleMeetingRecordingInterruption(
                    message: "Meeting recording was interrupted by the system",
                    cause: cause
                )
            }
            return
        }
        guard type == .began else { return }
        handleVoiceNoteRecordingInterruption(
            message: "Recording was interrupted by the system",
            cause: .interrupted
        )
    }

    private func handleAudioServicesReset() {
        if meetingLifecycleState.isRecordingVisible || meetingRecorder != nil {
            handleMeetingRecordingInterruption(
                message: "Audio services restarted during the meeting",
                cause: .system
            )
            return
        }
        handleVoiceNoteRecordingInterruption(
            message: "Audio services restarted",
            cause: .interrupted
        )
    }

    private func handleMeetingRecordingInterruption(
        message: String,
        cause: MeetingAudioInterruptionCause
    ) {
        guard let session = activeSession ?? persistedRecordingMeetingSession,
              session.kind == .meeting
        else {
            reconcileMeetingRuntime(reason: "audio_interruption_without_session")
            return
        }

        meetingStatusText = message
        AppTelemetry.failure(
            "meeting_recording_interrupted",
            domain: .meeting,
            stage: "audio_interruption",
            reason: cause.rawValue
        )
        if meetingLifecycleState.isStarting(sessionID: session.id) {
            _ = stopMeetingStartup(session)
        } else {
            stopMeetingRecording(queueForTranscription: false)
        }
    }

    private func resumeMeetingCaptureAfterInterruptionIfNeeded(
        cause: MeetingAudioInterruptionCause,
        shouldResume: Bool
    ) {
        guard meetingLifecycleState.isRecording,
              let meetingRecorder
        else { return }
        do {
            let didResume = try meetingRecorder.resumeIfNeeded()
            guard didResume else {
                stopMeetingRecording(queueForTranscription: false)
                return
            }
            AppTelemetry.signal(
                "meeting_recording_resumed_after_interruption",
                parameters: [
                    "cause": cause.rawValue,
                    "system_should_resume": shouldResume ? "true" : "false",
                ]
            )
        } catch {
            AppTelemetry.failure(
                "meeting_recording_resume_failed",
                domain: .audio,
                stage: "interruption_resume",
                error: error,
                reason: cause.rawValue
            )
            stopMeetingRecording(queueForTranscription: false)
        }
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
           currentRecordingElapsedTime() >= Double(threshold),
           let promotedSession = promoteActiveVoiceNoteToLongForm(sessionID: session.id) {
            session = promotedSession
        }
        session.lastTranscriptionFailureReason = cause.failureReason
        session.errorMessage = message
        activeSession = session
        try? store.saveSession(session)
        stopRecording(requestID: requestID)
    }

    func recoverLongVoiceNotesIfNeeded() {
        guard longVoiceNoteRecoveryTask == nil else { return }
        longVoiceNoteRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await recoverLongVoiceNotesOnLaunch()
            longVoiceNoteRecoveryTask = nil
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
        let inventoryResult = VoiceNoteRecoveryInventory.load {
            try store.recordingSessions()
        }
        let sessions: [RecordingSession]
        switch inventoryResult {
        case .success(let inventory):
            sessions = inventory.sessions
        case .failure(let error):
            AppTelemetry.failure(
                "long_voice_note_recovery_inventory_failed",
                domain: .persistence,
                stage: "load_sessions",
                error: error
            )
            return
        }
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
                  voiceNoteLifecycleRunner?.sessionID != original.id,
                  original.phase != .failed || original.longFormRecoveryValidatedAt == nil
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
                try? await voiceNoteCheckpointStore.delete(sessionID: session.id)
            }
            session.longFormRecoveryValidatedAt = .now
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
        let duration = max(0, session.duration ?? currentRecordingElapsedTime())
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

    @discardableResult
    private func beginMeetingLifecycle(
        sessionID: UUID,
        event: MeetingLifecycleEvent,
        operationID: UUID = UUID()
    ) -> Bool {
        guard transitionMeetingLifecycle(event) else { return false }
        meetingLifecycleRunner?.cancelAll()
        meetingLifecycleRunner = MeetingLifecycleRunner(id: operationID, sessionID: sessionID)
        return true
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

    @discardableResult
    private func cancelMeetingLifecycle(sessionID: UUID) -> Bool {
        guard meetingLifecycleRunner?.sessionID == sessionID || meetingLifecycleState.activeSessionID == sessionID else {
            return false
        }
        guard transitionMeetingLifecycle(.cancelRequested(sessionID)) else { return false }
        meetingLifecycleRunner?.cancelAll()
        return true
    }

    @discardableResult
    private func finishMeetingLifecycle(sessionID: UUID) -> Bool {
        guard meetingLifecycleRunner?.sessionID == sessionID || meetingLifecycleState.activeSessionID == sessionID else {
            return false
        }
        guard transitionMeetingLifecycle(.finished(sessionID)) else { return false }
        meetingLifecycleRunner?.cancelAll()
        meetingLifecycleRunner = nil
        if activeSession?.kind == .meeting, activeSession?.id == sessionID {
            activeSession = nil
        }
        resumeKeyboardSessionKeeperIfNeeded()
        return true
    }

    private func isCurrentMeetingLifecycle(sessionID: UUID, operationID: UUID? = nil) -> Bool {
        meetingLifecycleState.activeSessionID == sessionID
            && !meetingLifecycleState.isCancelling
            && meetingLifecycleRunner?.sessionID == sessionID
            && (operationID == nil || meetingLifecycleRunner?.id == operationID)
    }

    private func ensureMeetingLifecycleActive(sessionID: UUID, operationID: UUID? = nil) throws {
        try Task.checkCancellation()
        guard isCurrentMeetingLifecycle(sessionID: sessionID, operationID: operationID) else {
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
        if action == MuesliAppConstants.cancelAction {
            guard !rejectConflictingKeyboardCommand(requestID: requestID, action: .cancel) else {
                try? store.clearPendingCommand()
                return
            }
            saveKeyboardHandoff(
                requestID: requestID,
                phase: .cancelled,
                message: "Cancelled"
            )
            cancelRecording(requestID: requestID)
            try? store.clearPendingCommand()
            return
        }
        if action == MuesliAppConstants.stopAction {
            guard !rejectConflictingKeyboardCommand(requestID: requestID, action: .stop) else {
                try? store.clearPendingCommand()
                return
            }
            saveKeyboardHandoff(
                requestID: requestID,
                phase: .stopAcknowledged,
                message: "Stopping"
            )
            stopRecording(requestID: requestID)
            try? store.clearPendingCommand()
            return
        }

        guard !rejectConflictingKeyboardCommand(requestID: requestID, action: .start) else {
            try? store.clearPendingCommand()
            return
        }
        defer { try? store.clearPendingCommand() }

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

        guard prepareVoiceNoteLifecycleForPersistedRetry(sessionID: session.id) else {
            let message = "Finish the active voice note first"
            saveKeyboardHandoff(requestID: request.id, phase: .failed, message: message)
            return true
        }
        transitionKeyboardSession(.transcribing(request.id))
        activeRequest = request
        activeSession = session
        voiceNoteLifecycleRunner?.cancelAll()
        voiceNoteLifecycleRunner = VoiceNoteLifecycleRunner(
            sessionID: session.id,
            requestID: request.id
        )
        guard let lifecycleRunnerID = voiceNoteLifecycleRunner?.id,
              transitionVoiceNoteLifecycle(.retryRequested(session.id)),
              transitionVoiceNoteLifecycle(.transcriptionStarted(session.id))
        else {
            finishVoiceNoteLifecycle(sessionID: session.id)
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

        if ProcessInfo.processInfo.arguments.contains(MuesliAppConstants.processingMeetingSummaryUITestLaunchArgument) {
            configureProcessingMeetingSummaryUITestFixture()
        } else if ProcessInfo.processInfo.arguments.contains(MuesliAppConstants.liveMeetingTranscriptUITestLaunchArgument) {
            configureLiveMeetingTranscriptUITestFixture()
        } else if ProcessInfo.processInfo.arguments.contains(MuesliAppConstants.processingMeetingUITestLaunchArgument) {
            configureProcessingMeetingUITestFixture()
        } else if ProcessInfo.processInfo.arguments.contains(MuesliAppConstants.interruptedMeetingRecoveryUITestLaunchArgument) {
            configureInterruptedMeetingRecoveryUITestFixture()
        } else if ProcessInfo.processInfo.arguments.contains(MuesliAppConstants.missingActiveMeetingHistoryUITestLaunchArgument) {
            configureMissingActiveMeetingHistoryUITestFixture()
        } else if ProcessInfo.processInfo.arguments.contains(MuesliAppConstants.completedLongVoiceNoteUITestLaunchArgument) {
            configureCompletedLongVoiceNoteUITestFixture()
        } else if ProcessInfo.processInfo.arguments.contains(MuesliAppConstants.longVoiceNoteUITestLaunchArgument) {
            configureLongVoiceNoteUITestFixture()
        }
    }

    private func configureProcessingMeetingSummaryUITestFixture() {
        let operationID = UUID()
        var session = RecordingSession(
            kind: .meeting,
            title: "Summary Selection Meeting",
            startedAt: Date.now.addingTimeInterval(-90),
            endedAt: .now,
            phase: .transcribing,
            source: "iphone"
        )
        session.meetingOperationID = operationID
        let partialTranscript = Transcript(
            sessionID: session.id,
            text: "Raw transcript should no longer be selected after processing.",
            engineIdentifier: "ui-test",
            diarizationState: .processing,
            summaryState: .processing
        )
        session.transcriptID = partialTranscript.id
        activeSession = session
        recordingSessions = [session]
        transcriptCache[session.id] = partialTranscript
        meetingLifecycleRunner = MeetingLifecycleRunner(id: operationID, sessionID: session.id)
        transitionMeetingLifecycle(.transcriptionStarted(session.id))
        meetingStatusText = "Transcribing"

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self else { return }
            let completedTranscript = Transcript(
                id: partialTranscript.id,
                sessionID: session.id,
                text: partialTranscript.text,
                engineIdentifier: "ui-test",
                summaryText: "The generated meeting summary is selected by default.",
                diarizationState: .completed,
                summaryState: .completed
            )
            self.transcriptCache[session.id] = completedTranscript
            var completedSession = session
            completedSession.phase = .completed
            completedSession.meetingOperationID = nil
            self.recordingSessions = [completedSession]
            self.finishMeetingLifecycle(sessionID: session.id)
            self.meetingStatusText = "Ready"
        }
    }

    private func configureLiveMeetingTranscriptUITestFixture() {
        let operationID = UUID()
        var session = RecordingSession(
            kind: .meeting,
            title: "Live Transcript Meeting",
            startedAt: Date.now.addingTimeInterval(-20),
            phase: .recording,
            source: "iphone"
        )
        session.meetingOperationID = operationID
        let transcript = Transcript(
            sessionID: session.id,
            text: "This transcript appeared while the meeting was still recording.",
            engineIdentifier: "ui-test"
        )
        session.transcriptID = transcript.id
        activeSession = session
        recordingSessions = [session]
        transcriptCache[session.id] = transcript
        meetingRecorder = StreamingMeetingRecorder()
        meetingLifecycleRunner = MeetingLifecycleRunner(id: operationID, sessionID: session.id)
        transitionMeetingLifecycle(.startRequested(session.id))
        transitionMeetingLifecycle(.recordingStarted(session.id))
        meetingStatusText = "Recording"
    }

    private func configureProcessingMeetingUITestFixture() {
        let session = RecordingSession(
            kind: .meeting,
            title: "Processing Meeting",
            startedAt: Date.now.addingTimeInterval(-90),
            endedAt: .now,
            phase: .transcribing,
            audioFileName: "processing-meeting.wav",
            source: "iphone"
        )
        activeSession = session
        recordingSessions = [session]
        meetingLifecycleRunner = MeetingLifecycleRunner(sessionID: session.id)
        transitionMeetingLifecycle(.transcriptionStarted(session.id))
        meetingStatusText = "Transcribing"
    }

    private func configureInterruptedMeetingRecoveryUITestFixture() {
        let session = RecordingSession(
            kind: .meeting,
            title: "Interrupted Meeting",
            startedAt: Date.now.addingTimeInterval(-45),
            phase: .recording,
            audioFileName: "interrupted-meeting.wav",
            source: "iphone"
        )
        recordingSessions = [session]
        meetingStatusText = "Ready"
    }

    private func configureMissingActiveMeetingHistoryUITestFixture() {
        let session = RecordingSession(
            kind: .meeting,
            title: "Recovered Live Meeting",
            startedAt: Date.now.addingTimeInterval(-20),
            phase: .recording,
            source: "iphone"
        )

        activeSession = session
        recordingSessions = []
        meetingStatusText = "Recording"
        meetingLifecycleRunner = MeetingLifecycleRunner(sessionID: session.id)
        transitionMeetingLifecycle(.startRequested(session.id))
        transitionMeetingLifecycle(.recordingStarted(session.id))
        reconcileMeetingRuntime(with: [], reason: "ui_missing_durable_session")
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
        #if DEBUG
        guard !Self.shouldConfigureForUITestingFromLaunchArguments() else { return }
        #endif
        do {
            dictationHistory = try store.resultsHistory()
            let persistedSessions = try store.recordingSessions()
            let inventoryActiveSession = activeSession?.kind == .meeting ? nil : activeSession
            let repairedSessions = RecordingSessionInventory.preservingActiveSession(
                inventoryActiveSession,
                in: persistedSessions
            )
            if let inventoryActiveSession,
               !persistedSessions.contains(where: { $0.id == inventoryActiveSession.id }) {
                AppTelemetry.failure(
                    "recording_session_inventory_repaired",
                    domain: .stateMachine,
                    stage: "history_refresh",
                    reason: "active_session_missing",
                    parameters: [
                        "kind": inventoryActiveSession.kind.rawValue,
                        "phase": inventoryActiveSession.phase.rawValue,
                    ]
                )
            }
            recordingSessions = repairedSessions
            reconcileMeetingRuntime(with: persistedSessions, reason: "history_refresh")
            transcriptCache = transcriptsBySessionID(try store.transcripts())
            lastTranscript = dictationHistory.first?.text ?? lastTranscript
        } catch {
            statusText = error.localizedDescription
        }
    }

    func reconcileMeetingRuntime(reason: String) {
        do {
            let persistedSessions = try store.recordingSessions()
            reconcileMeetingRuntime(with: persistedSessions, reason: reason)
        } catch {
            AppTelemetry.failure(
                "meeting_runtime_reconciliation_failed",
                domain: .stateMachine,
                stage: reason,
                error: error,
                reason: "inventory_unavailable"
            )
        }
    }

    private func reconcileMeetingRuntime(
        with persistedSessions: [RecordingSession],
        reason: String
    ) {
        let snapshot = MeetingRuntimeSnapshot(
            lifecycle: meetingLifecycleState,
            activeSessionID: activeSession?.kind == .meeting ? activeSession?.id : nil,
            persistedSessionIDs: Set(
                persistedSessions.lazy.filter { $0.kind == .meeting }.map(\.id)
            ),
            recorderIsPresent: meetingRecorder != nil,
            persistedSessionPhases: Dictionary(uniqueKeysWithValues: persistedSessions.lazy
                .filter { $0.kind == .meeting }
                .map { ($0.id, $0.phase) })
        )
        let issues = MeetingRuntimeInvariant.issues(in: snapshot)
        if !issues.isEmpty {
            AppTelemetry.failure(
                "meeting_runtime_invariant_violated",
                domain: .stateMachine,
                stage: reason,
                reason: issues.map(\.telemetryName).joined(separator: ","),
                parameters: ["phase": meetingLifecycleState.phase.telemetryName]
            )
        }

        guard let sessionID = meetingLifecycleState.activeSessionID else {
            let hadOrphanedRuntime = activeSession?.kind == .meeting
                || meetingRecorder != nil
                || meetingVadController != nil
            if activeSession?.kind == .meeting {
                activeSession = nil
            }
            if hadOrphanedRuntime {
                stopOrphanedMeetingCapture()
            }
            for session in persistedSessions where session.kind == .meeting {
                switch session.phase {
                case .recording, .transcribing:
                    recoverPersistedMeeting(session, reason: "orphaned_\(session.phase.rawValue)")
                case .transcriptionQueued, .completed, .failed, .cancelled:
                    break
                }
            }
            return
        }

        guard let persistedSession = persistedSessions.first(where: {
            $0.id == sessionID && $0.kind == .meeting
        }) else {
            stopOrphanedMeetingCapture()
            activeSession = nil
            meetingStatusText = "Meeting was removed and stale work was stopped"
            finishMeetingLifecycle(sessionID: sessionID)
            return
        }

        guard persistedSession.phase.isCompatible(with: meetingLifecycleState.phase),
              persistedSession.meetingOperationID == meetingLifecycleRunner?.id
        else {
            stopOrphanedMeetingCapture()
            activeSession = nil
            meetingStatusText = persistedSession.phase == .completed
                ? "Ready"
                : (persistedSession.errorMessage ?? "Meeting work ended")
            finishMeetingLifecycle(sessionID: sessionID)
            return
        }

        activeSession = persistedSession

        if !meetingLifecycleState.allowsRecorder, meetingRecorder != nil {
            meetingVadController?.stop()
            meetingRecorder?.cancel()
            meetingRecorder = nil
            meetingVadController = nil
            stopMetering()
        }

        guard meetingLifecycleState.requiresRecorder else { return }
        guard let meetingRecorder else {
            recoverPersistedMeeting(persistedSession, reason: "missing_recorder")
            finishMeetingLifecycle(sessionID: sessionID)
            return
        }

        if reason == "foreground", !meetingRecorder.isCapturingAudio {
            do {
                _ = try meetingRecorder.resumeIfNeeded(routeStage: "meeting foreground recovery")
            } catch {
                recoverPersistedMeeting(persistedSession, reason: "foreground_resume_failed")
                finishMeetingLifecycle(sessionID: sessionID)
            }
        }
    }

    private func recoverPersistedMeeting(_ session: RecordingSession, reason: String) {
        let recovered: RecordingSession?
        do {
            recovered = try store.transitionMeetingSession(
                id: session.id,
                expectedPhases: [session.phase],
                expectedOperationID: session.meetingOperationID,
                update: { persisted in
                    persisted.endedAt = persisted.endedAt ?? .now
                    if persisted.audioFileName == nil {
                        persisted.phase = .failed
                        persisted.errorMessage = "Meeting audio was interrupted before it could be saved."
                    } else {
                        persisted.phase = .transcriptionQueued
                        persisted.errorMessage = "Meeting recording was interrupted. Audio is ready to transcribe."
                    }
                    persisted.meetingOperationID = nil
                }
            )
        } catch {
            recovered = nil
        }
        activeSession = nil
        stopOrphanedMeetingCapture()
        meetingStatusText = recovered?.errorMessage ?? "Meeting recording interrupted"
        if let recovered {
            if let index = recordingSessions.firstIndex(where: { $0.id == session.id }) {
                recordingSessions[index] = recovered
            } else {
                recordingSessions.insert(recovered, at: 0)
            }
        }
        AppTelemetry.signal("meeting_recovered_to_durable_state", parameters: ["reason": reason])
    }

    private func stopOrphanedMeetingCapture() {
        meetingVadController?.stop()
        meetingRecorder?.cancel()
        meetingRecorder = nil
        meetingVadController = nil
        stopMetering()
        cleanupMeetingChunks(cancelTasks: true)
        meetingStatusText = "Meeting recording recovered"
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
              !isRemovingTranscriptionModel,
              var session = try? store.activeRecordingSession(id: sessionID),
              session.canRetryVoiceNoteTranscription,
              let requestID = session.requestID,
              let audioFileName = session.audioFileName,
              let audioURL = try? store.audioFileURL(fileName: audioFileName)
        else { return }

        guard prepareVoiceNoteLifecycleForPersistedRetry(sessionID: sessionID) else { return }
        voiceNoteLifecycleRunner?.cancelAll()
        voiceNoteLifecycleRunner = VoiceNoteLifecycleRunner(
            sessionID: sessionID,
            requestID: requestID
        )
        guard let runnerID = voiceNoteLifecycleRunner?.id else { return }
        guard transitionVoiceNoteLifecycle(.retryRequested(sessionID)) else {
            finishVoiceNoteLifecycle(sessionID: sessionID)
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
        guard !meetingLifecycleState.owns(sessionID: session.id),
              activeSession?.id != session.id
        else {
            clipboardStatusText = "Stop or discard the active meeting first"
            clearClipboardStatusSoon()
            return false
        }
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
        guard !meetingLifecycleState.owns(sessionID: session.id),
              activeSession?.id != session.id
        else {
            clipboardStatusText = "Stop the active meeting before deleting its audio"
            clearClipboardStatusSoon()
            return false
        }
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
            if activeSession?.id == session.id {
                activeSession = session
            }
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

    func meetingSession(id: UUID) -> RecordingSession? {
        if let cachedSession = recordingSessions.first(where: { $0.id == id && $0.kind == .meeting }) {
            return cachedSession
        }
        if let activeSession, activeSession.id == id, activeSession.kind == .meeting {
            return activeSession
        }
        guard let storedSession = try? store.activeRecordingSession(id: id),
              storedSession.kind == .meeting
        else { return nil }
        return storedSession
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
                    supportsBackgroundStart: false
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
        if isRecording, let requestID = activeRequest?.id, usesPersistentKeyboardSession(for: requestID) {
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

    private func setUsesPersistentKeyboardSession(_ usesKeyboardSession: Bool, for requestID: UUID) {
        if usesKeyboardSession {
            persistentKeyboardSessionRequestIDs.insert(requestID)
        } else {
            persistentKeyboardSessionRequestIDs.remove(requestID)
        }
    }

    private func usesPersistentKeyboardSession(for requestID: UUID) -> Bool {
        persistentKeyboardSessionRequestIDs.contains(requestID)
    }

    private func clearPersistentKeyboardSessionRoute(for requestID: UUID) {
        persistentKeyboardSessionRequestIDs.remove(requestID)
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
        prepareSelectedModel(reason: "onboarding")
    }

    func prepareModel() {
        prepareSelectedModel(reason: "retry")
    }

    func selectTranscriptionModel(_ model: LocalTranscriptionModel) {
        UserDefaults.standard.removeObject(
            forKey: MuesliPreferences.manuallyRemovedTranscriptionModelKey
        )
        if selectedTranscriptionModel == model {
            guard !model.isDownloaded else { return }
            modelPreparation = ModelPreparationState(
                status: "\(model.shortName) is not downloaded",
                detail: model.detail
            )
            automaticallyPrepareSelectedModelIfNeeded()
            return
        }
        selectedTranscriptionModel = model
    }

    func removeDownloadedModel(_ model: LocalTranscriptionModel) async throws {
        guard canRemoveDownloadedModels else {
            throw TranscriptionModelRemovalError.modelInUse
        }

        isRemovingTranscriptionModel = true
        defer { isRemovingTranscriptionModel = false }

        if selectedTranscriptionModel == model {
            modelPreparationTask?.cancel()
            modelPreparationTask = nil
            modelPrewarmTask?.cancel()
            modelPrewarmTask = nil
            await engine.unloadModel(model)
        }

        try await Task.detached(priority: .userInitiated) {
            try ModelBackgroundDownloadService.removeDownloadedModel(model)
        }.value

        if selectedTranscriptionModel == model {
            UserDefaults.standard.set(
                model.rawValue,
                forKey: MuesliPreferences.manuallyRemovedTranscriptionModelKey
            )
            modelPreparation = ModelPreparationState(
                status: "\(model.shortName) removed",
                detail: "Select this model again when you want to download it."
            )
        }

        AppTelemetry.signal(
            "transcription_model_removed",
            parameters: [
                "engine": model.engineIdentifier,
                "was_active": selectedTranscriptionModel == model ? "true" : "false",
            ]
        )
    }

    private func automaticallyPrepareSelectedModelIfNeeded() {
        #if DEBUG
        guard !Self.shouldSkipModelPrewarmForTesting() else { return }
        #endif
        guard hasCompletedOnboarding else { return }
        guard !isSelectedModelDownloadSuppressed else { return }
        prepareSelectedModel(reason: "selection")
    }

    private func prepareSelectedModel(reason: String) {
        guard !modelPreparation.isPreparing, !modelPreparation.isReady else { return }

        let model = selectedTranscriptionModel
        modelPreparationTask?.cancel()
        modelPreparation = ModelPreparationState(
            phase: .downloading,
            progress: 0,
            status: "Checking model files...",
            detail: model.shortName
        )
        AppTelemetry.signal(
            "model_prepare_started",
            parameters: [
                "engine": model.engineIdentifier,
                "reason": reason,
            ]
        )

        let coordinator = self
        modelPreparationTask = Task { [engine, model] in
            do {
                await engine.selectModel(model)
                let didStartBackgroundDownload = try await ModelBackgroundDownloadService.shared.startDownload(for: model)
                if didStartBackgroundDownload {
                    await MainActor.run {
                        if coordinator.selectedTranscriptionModel == model {
                            coordinator.modelPreparationTask = nil
                        }
                    }
                    return
                }
                try await engine.prepare { progress, status in
                    Task { @MainActor in
                        coordinator.applyModelPreparationProgress(progress, status: status, model: model)
                    }
                }

                await MainActor.run {
                    guard coordinator.selectedTranscriptionModel == model else { return }
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
                    if coordinator.selectedTranscriptionModel == model {
                        coordinator.modelPreparationTask = nil
                    }
                }
            } catch {
                await MainActor.run {
                    guard coordinator.selectedTranscriptionModel == model else { return }
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

    func prewarmModelIfNeeded(reason: String) {
        #if DEBUG
        guard !Self.shouldSkipModelPrewarmForTesting() else { return }
        #endif
        guard hasCompletedOnboarding else { return }
        guard !isSelectedModelDownloadSuppressed else { return }
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
                        guard coordinator.selectedTranscriptionModel == model else { return }
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
                        coordinator.applyModelPreparationProgress(progress, status: status, model: model)
                    }
                }

                await MainActor.run {
                    guard coordinator.selectedTranscriptionModel == model else { return }
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
                    if coordinator.selectedTranscriptionModel == model {
                        coordinator.modelPrewarmTask = nil
                    }
                }
            } catch {
                await MainActor.run {
                    guard coordinator.selectedTranscriptionModel == model else { return }
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

    private func applyModelPreparationProgress(
        _ progress: Double,
        status: String?,
        model: LocalTranscriptionModel
    ) {
        guard selectedTranscriptionModel == model else { return }
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
                : "Downloading \(model.shortName)",
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
                        coordinator.applyModelPreparationProgress(progress, status: status, model: model)
                    }
                }

                await MainActor.run {
                    guard coordinator.selectedTranscriptionModel == model else { return }
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
                    if coordinator.selectedTranscriptionModel == model {
                        coordinator.modelPreparationTask = nil
                    }
                }
            } catch {
                await MainActor.run {
                    guard coordinator.selectedTranscriptionModel == model else { return }
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
              statusText != "Transcribing",
              !isRemovingTranscriptionModel
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
        let usesPersistentKeyboardSession = source == "keyboard" && isKeyboardSessionArmed
        setUsesPersistentKeyboardSession(usesPersistentKeyboardSession, for: request.id)
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
                if !usesPersistentKeyboardSession, keyboardSessionKeeper.isRunning {
                    keyboardSessionKeeper.stop(deactivateSession: true)
                    transitionKeyboardSession(.requestFinished)
                    try? store.clearKeyboardRuntimeStatus()
                    try? await Task.sleep(for: .milliseconds(150))
                }
                if usesPersistentKeyboardSession {
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
                if source == "keyboard", !usesPersistentKeyboardSession {
                    transitionKeyboardSession(.recordingStarted(request.id))
                }
                startRecordingTimer(startedAt: session.startedAt ?? .now)
                if source == "keyboard" {
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
                }
                startMetering { [weak self] level in
                    guard let self else { return }
                    self.inputLevel = level
                    if source == "keyboard" {
                        self.publishKeyboardRuntimeLevel(level, requestID: request.id)
                    }
                }
                statusText = "Recording"
                AppTelemetry.signal("dictation_started", parameters: ["source": source])
                try store.saveRequest(request)
                try store.saveStatus(.init(requestID: request.id, phase: .recording))
                if source == "keyboard" {
                    await processPendingKeyboardCommand()
                }
                Task {
                    if usesPersistentKeyboardSession {
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
                clearPersistentKeyboardSessionRoute(for: request.id)
                stopMetering()
                if usesPersistentKeyboardSession {
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
                    if let command = try? store.pendingCommand(), command.requestID == request.id {
                        try? store.clearPendingCommand()
                    }
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

        if let thresholdSession = session,
           !thresholdSession.isLongForm,
           let threshold = thresholdSession.longFormThresholdSeconds,
           currentRecordingElapsedTime() >= Double(threshold),
           let promotedSession = promoteActiveVoiceNoteToLongForm(sessionID: thresholdSession.id) {
            session = promotedSession
        }

        let usesPersistentKeyboardSession = usesPersistentKeyboardSession(for: request.id)
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
                if usesPersistentKeyboardSession {
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

                if usesPersistentKeyboardSession {
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
                    clearPersistentKeyboardSessionRoute(for: request.id)
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
                if usesPersistentKeyboardSession {
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
                if startedFromKeyboard, usesPersistentKeyboardSession, !completedDeferredStop {
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
                clearPersistentKeyboardSessionRoute(for: request.id)
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
                        isActive: isKeyboardHandoffActive || usesPersistentKeyboardSession || canStartKeyboardRequestsInBackground,
                        activeRequestID: nil,
                        phase: .failed,
                        message: error.localizedDescription,
                        supportsBackgroundStart: canStartKeyboardRequestsInBackground
                    )
                }
                if usesPersistentKeyboardSession, !completedDeferredStop {
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
                clearPersistentKeyboardSessionRoute(for: request.id)
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
              statusText != "Transcribing",
              !isRemovingTranscriptionModel
        else { return nil }
        MuesliHaptics.dictationStart()
        activeMeetingTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Untitled Meeting"
            : title.trimmingCharacters(in: .whitespacesAndNewlines)
        var session = RecordingSession(kind: .meeting, title: activeMeetingTitle)
        let operationID = UUID()
        session.keepsAudioRecording = MuesliPreferences.keepMeetingAudioRecordingsEnabled
        session.meetingOperationID = operationID
        do {
            try store.saveSession(session)
        } catch {
            meetingStatusText = error.localizedDescription
            return nil
        }
        activeSession = session
        if !recordingSessions.contains(where: { $0.id == session.id }) {
            recordingSessions.insert(session, at: 0)
        }
        meetingStatusText = "Preparing"
        guard beginMeetingLifecycle(
            sessionID: session.id,
            event: .startRequested(session.id),
            operationID: operationID
        ) else {
            activeSession = nil
            recordingSessions.removeAll { $0.id == session.id }
            try? store.deleteRecordingSession(id: session.id)
            meetingStatusText = "A meeting is already active"
            return nil
        }

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
            guard let operationID = meetingLifecycleRunner?.id,
                  let preparedSession = try store.transitionMeetingSession(
                    id: session.id,
                    expectedPhases: [.recording],
                    expectedOperationID: operationID,
                    update: { persisted in
                        persisted.audioFileName = audioURL.lastPathComponent
                        persisted.startedAt = .now
                    }
                  )
            else { throw CancellationError() }
            session = preparedSession
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
            meetingStatusText = "Recording"
            guard transitionMeetingLifecycle(.recordingStarted(session.id)) else {
                vadController.stop()
                streamingRecorder.cancel()
                meetingRecorder = nil
                meetingVadController = nil
                throw CancellationError()
            }
            startMeetingMetering()
            prewarmModelIfNeeded(reason: "meeting_recording")
            refreshHistory()
            AppTelemetry.signal("meeting_recording_started")
            Task {
                await liveActivityController.start(
                    session: session,
                    requestID: nil,
                    phase: "Recording",
                    detail: "Meeting recording in progress"
                )
            }
        } catch is CancellationError {
            guard isCurrentMeetingLifecycle(sessionID: session.id) else { return }
            abortCancelledMeeting(session)
        } catch {
            guard isCurrentMeetingLifecycle(sessionID: session.id) else { return }
            let operationID = meetingLifecycleRunner?.id
            _ = try? store.transitionMeetingSession(
                id: session.id,
                expectedPhases: [.recording],
                expectedOperationID: operationID,
                update: { persisted in
                    persisted.phase = .failed
                    persisted.errorMessage = error.localizedDescription
                    persisted.meetingOperationID = nil
                }
            )
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

    @discardableResult
    func stopCurrentMeetingRecording() -> Bool {
        guard let session = activeSession ?? persistedRecordingMeetingSession,
              session.kind == .meeting
        else { return false }

        switch meetingLifecycleState.phase {
        case .starting(let sessionID) where sessionID == session.id:
            return stopMeetingStartup(session)
        case .recording(let sessionID) where sessionID == session.id:
            guard meetingRecorder != nil else {
                reconcileMeetingRuntime(reason: "stop_requested_without_recorder")
                return false
            }
            stopMeetingRecording(queueForTranscription: true)
            return true
        case .stopping, .transcribing, .cancelling:
            AppTelemetry.failure(
                "meeting_capture_command_rejected",
                domain: .stateMachine,
                stage: "stop",
                reason: "lifecycle_not_stoppable",
                parameters: ["phase": meetingLifecycleState.phase.telemetryName]
            )
            return false
        case .starting, .recording:
            AppTelemetry.failure(
                "meeting_capture_command_rejected",
                domain: .stateMachine,
                stage: "stop",
                reason: "session_mismatch",
                parameters: ["phase": meetingLifecycleState.phase.telemetryName]
            )
            return false
        case .idle:
            guard isMeetingRecoveryNeeded, persistedRecordingMeetingSession?.id == session.id else {
                return false
            }
        }

        guard session.audioFileName != nil else {
            let failed: RecordingSession?
            do {
                failed = try store.transitionMeetingSession(
                    id: session.id,
                    expectedPhases: [.recording],
                    expectedOperationID: session.meetingOperationID,
                    update: { persisted in
                        persisted.endedAt = persisted.endedAt ?? .now
                        persisted.phase = .failed
                        persisted.errorMessage = "Meeting audio is unavailable. The stale recording state was cleared."
                        persisted.meetingOperationID = nil
                    }
                )
            } catch {
                failed = nil
            }
            activeSession = nil
            meetingStatusText = failed?.errorMessage ?? "Meeting recovery failed"
            refreshHistory()
            return failed != nil
        }

        meetingRecorder = nil
        meetingVadController = nil
        activeSession = nil
        stopMetering()
        let queued: RecordingSession?
        do {
            queued = try store.transitionMeetingSession(
                id: session.id,
                expectedPhases: [.recording],
                expectedOperationID: session.meetingOperationID,
                update: { persisted in
                    persisted.endedAt = .now
                    persisted.phase = .transcriptionQueued
                    persisted.errorMessage = nil
                    persisted.meetingOperationID = nil
                }
            )
        } catch {
            queued = nil
        }
        guard let queued else {
            refreshHistory()
            return false
        }
        refreshHistory()
        AppTelemetry.signal("meeting_recording_recovered_for_transcription")
        transcribeSession(queued)
        return true
    }

    func stopMeetingRecordingFromLiveActivity(sessionID: UUID) -> MeetingLiveActivityStopResult {
        guard canStopMeetingCapture(sessionID: sessionID) else {
            AppTelemetry.failure(
                "meeting_capture_command_rejected",
                domain: .stateMachine,
                stage: "live_activity_stop",
                reason: "session_not_stoppable"
            )
            return .alreadyHandled
        }
        guard stopCurrentMeetingRecording() else {
            AppTelemetry.failure(
                "meeting_capture_command_failed",
                domain: .stateMachine,
                stage: "live_activity_stop",
                reason: "stop_did_not_complete"
            )
            return .failed
        }
        AppTelemetry.signal("meeting_recording_stopped_from_live_activity")
        return .accepted
    }

    private func stopMeetingStartup(_ session: RecordingSession) -> Bool {
        MuesliHaptics.dictationStop()
        guard cancelMeetingLifecycle(sessionID: session.id) else { return false }
        abortCancelledMeeting(session)
        Task {
            await liveActivityController.end(
                phase: "Stopped",
                detail: "Meeting recording stopped before audio capture",
                session: session,
                dismissal: .immediate
            )
        }
        AppTelemetry.signal("meeting_recording_startup_stopped")
        return true
    }

    func cancelCurrentMeetingRecording() {
        guard isMeetingRecording || meetingRecorder != nil || activeSession?.kind == .meeting || persistedRecordingMeetingSession != nil else { return }
        guard let session = activeSession ?? persistedRecordingMeetingSession, session.kind == .meeting else { return }
        let latestSession = (try? store.recordingSession(id: session.id)) ?? session

        let didBeginCancellation: Bool
        if meetingLifecycleState.activeSessionID == nil {
            didBeginCancellation = beginMeetingLifecycle(
                sessionID: latestSession.id,
                event: .cancelRequested(latestSession.id)
            )
        } else {
            didBeginCancellation = cancelMeetingLifecycle(sessionID: latestSession.id)
        }
        guard didBeginCancellation else { return }
        MuesliHaptics.dictationStop()
        stopMetering()
        meetingStatusText = "Ready"

        meetingVadController?.stop()
        meetingRecorder?.cancel()
        meetingRecorder = nil
        meetingVadController = nil
        activeSession = nil
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
                session: latestSession,
                dismissal: .immediate
            )
        }
        AppTelemetry.signal("meeting_recording_discarded")
    }

    func stopMeetingRecording(queueForTranscription: Bool = true) {
        guard isMeetingRecording || meetingRecorder != nil else { return }
        guard var session = activeSession ?? persistedRecordingMeetingSession, session.kind == .meeting else { return }
        guard let operationID = meetingLifecycleRunner?.id else {
            reconcileMeetingRuntime(reason: "stop_without_operation_lease")
            return
        }
        guard transitionMeetingLifecycle(.stopRequested(session.id)) else { return }
        MuesliHaptics.dictationStop()
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
                scheduleMeetingChunkTranscription(
                    finalChunk,
                    sessionID: session.id,
                    operationID: operationID
                )
            }
            session.audioFileName = session.audioFileName ?? stoppedAudio?.retainedAudioURL?.lastPathComponent
            session.keepsAudioRecording = MuesliPreferences.keepMeetingAudioRecordingsEnabled
            session.endedAt = .now
            guard let queuedSession = try store.transitionMeetingSession(
                id: session.id,
                expectedPhases: [.recording],
                expectedOperationID: operationID,
                update: { persisted in
                    persisted.audioFileName = session.audioFileName
                    persisted.keepsAudioRecording = session.keepsAudioRecording
                    persisted.endedAt = session.endedAt
                    persisted.phase = .transcriptionQueued
                    persisted.errorMessage = nil
                    persisted.meetingOperationID = nil
                }
            ) else {
                cleanupMeetingChunks(cancelTasks: true)
                finishMeetingLifecycle(sessionID: session.id)
                refreshHistory()
                return
            }
            activeSession = queuedSession
            finishMeetingLifecycle(sessionID: session.id)
            refreshHistory()
            Task {
                await liveActivityController.end(
                    phase: "Stopped",
                    detail: "Meeting recording ended",
                    session: queuedSession,
                    dismissal: .immediate
                )
            }
            AppTelemetry.signal("meeting_recording_stopped", parameters: [
                "queued": "true",
                "automatic_transcription": queueForTranscription ? "true" : "false",
            ])
            if queueForTranscription {
                startMeetingTranscription(queuedSession, useStreamingChunks: true)
            } else {
                cleanupMeetingChunks(cancelTasks: true)
            }
        } catch {
            _ = try? store.transitionMeetingSession(
                id: session.id,
                expectedPhases: [.recording],
                expectedOperationID: operationID,
                update: { persisted in
                    persisted.phase = .failed
                    persisted.endedAt = persisted.endedAt ?? .now
                    persisted.errorMessage = error.localizedDescription
                    persisted.meetingOperationID = nil
                }
            )
            activeSession = nil
            meetingStatusText = error.localizedDescription
            cleanupMeetingChunks(cancelTasks: true)
            finishMeetingLifecycle(sessionID: session.id)
            refreshHistory()
            Task {
                await liveActivityController.end(
                    phase: "Stopped",
                    detail: "Meeting recording ended with an error",
                    session: session,
                    dismissal: .immediate
                )
            }
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
        stopMeetingRecording(queueForTranscription: false)
    }

    private func rotateActiveMeetingChunk() {
        guard isMeetingRecording, let session = activeSession, session.kind == .meeting else { return }
        guard let operationID = meetingLifecycleRunner?.id else { return }
        guard let chunk = meetingRecorder?.rotateChunk() else { return }
        meetingVadController?.notifyRotation()
        scheduleMeetingChunkTranscription(
            chunk,
            sessionID: session.id,
            operationID: operationID
        )
    }

    private func scheduleMeetingChunkTranscription(
        _ chunk: MeetingAudioChunk,
        sessionID: UUID,
        operationID: UUID
    ) {
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
            self.savePartialMeetingTranscript(
                sessionID: sessionID,
                operationID: operationID
            )
        }
    }

    private func savePartialMeetingTranscript(sessionID: UUID, operationID: UUID) {
        let merged = MeetingChunkTranscriptMerger.merge(meetingChunkTranscriptions)
        let text = postProcessTranscript(merged.text)
        guard !text.isEmpty else { return }
        guard isCurrentMeetingLifecycle(sessionID: sessionID, operationID: operationID) else { return }

        let transcript = Transcript(
            sessionID: sessionID,
            text: text,
            engineIdentifier: engine.identifier,
            speakerTranscript: nil,
            summaryText: nil,
            diarizationState: .processing,
            summaryState: MuesliPreferences.meetingSummariesEnabled ? .processing : .notStarted
        )
        guard (try? store.saveMeetingDraftTranscript(
            transcript,
            expectedOperationID: operationID
        )) == true else { return }
        cacheTranscript(transcript)
    }

    private func finalizeStreamingMeeting(_ initialSession: RecordingSession, operationID: UUID) {
        beginTranscriptionBackgroundTask()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                endTranscriptionBackgroundTask()
            }

            var session = initialSession
            do {
                try ensureMeetingLifecycleActive(sessionID: session.id, operationID: operationID)
                meetingStatusText = "Transcribing"
                for task in meetingChunkTasks {
                    if let transcription = await task.value,
                       !meetingChunkTranscriptions.contains(where: { $0.chunk.index == transcription.chunk.index }) {
                        meetingChunkTranscriptions.append(transcription)
                    }
                }
                meetingChunkTasks.removeAll(keepingCapacity: false)
                try ensureMeetingLifecycleActive(sessionID: session.id, operationID: operationID)

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
                    audioURL: audioURL,
                    operationID: operationID
                )
                try ensureMeetingLifecycleActive(sessionID: session.id, operationID: operationID)

                session.phase = .completed
                session.meetingOperationID = nil
                session.title = finalTranscript.resolvedTitle
                session.transcriptID = finalTranscript.transcript.id
                session.engineIdentifier = engine.identifier
                session.errorMessage = nil
                cleanupNonRetainedAudio(for: &session)
                guard try store.completeMeetingSession(
                    session,
                    transcript: finalTranscript.transcript,
                    expectedOperationID: operationID
                ) else {
                    meetingStatusText = "Ready"
                    cleanupMeetingChunks()
                    return
                }
                cacheTranscript(finalTranscript.transcript)
                scheduleICloudSyncAfterLocalChange(reason: "meeting_completed")
                cleanupMeetingChunks()
                meetingStatusText = "Ready"
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
                refreshHistory()
            } catch is CancellationError {
                if activeSession?.id == session.id {
                    activeSession = nil
                }
                if isCurrentMeetingLifecycle(sessionID: session.id, operationID: operationID) {
                    finishMeetingLifecycle(sessionID: session.id)
                }
                cleanupMeetingChunks()
                meetingStatusText = "Ready"
                refreshHistory()
            } catch {
                guard isCurrentMeetingLifecycle(sessionID: session.id, operationID: operationID) else {
                    cleanupMeetingChunks()
                    meetingStatusText = "Ready"
                    refreshHistory()
                    return
                }

                _ = try? store.transitionMeetingSession(
                    id: session.id,
                    expectedPhases: [.transcribing],
                    expectedOperationID: operationID,
                    update: { persisted in
                        persisted.phase = .failed
                        persisted.errorMessage = error.localizedDescription
                        persisted.meetingOperationID = nil
                    }
                )
                cleanupMeetingChunks()
                meetingStatusText = error.localizedDescription
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
                refreshHistory()
            }
        }
        setMeetingFinalizationTask(task, sessionID: initialSession.id)
    }

    func transcribeSession(_ session: RecordingSession) {
        startMeetingTranscription(session, useStreamingChunks: false)
    }

    private func startMeetingTranscription(_ queuedSession: RecordingSession, useStreamingChunks: Bool) {
        guard !isRecording,
              !hasMeetingRecordingInProgress,
              !isMeetingTranscribing,
              !isRemovingTranscriptionModel
        else { return }
        guard let audioFileName = queuedSession.audioFileName else { return }
        let operationID = UUID()
        let session: RecordingSession
        do {
            guard let transitioned = try store.transitionMeetingSession(
                id: queuedSession.id,
                expectedPhases: [.transcriptionQueued, .failed],
                update: { persisted in
                    persisted.phase = .transcribing
                    persisted.errorMessage = nil
                    persisted.meetingOperationID = operationID
                }
            ) else { return }
            session = transitioned
        } catch {
            meetingStatusText = error.localizedDescription
            return
        }
        guard beginMeetingLifecycle(
            sessionID: session.id,
            event: .transcriptionStarted(session.id),
            operationID: operationID
        ) else {
            _ = try? store.transitionMeetingSession(
                id: session.id,
                expectedPhases: [.transcribing],
                expectedOperationID: operationID,
                update: { persisted in
                    persisted.phase = .transcriptionQueued
                    persisted.meetingOperationID = nil
                }
            )
            return
        }
        activeSession = session
        refreshHistory()
        meetingStatusText = "Transcribing"
        if useStreamingChunks {
            finalizeStreamingMeeting(session, operationID: operationID)
            return
        }

        beginTranscriptionBackgroundTask()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                endTranscriptionBackgroundTask()
            }

            do {
                try ensureMeetingLifecycleActive(sessionID: session.id, operationID: operationID)
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
                    _ = try? self.store.transitionMeetingSession(
                        id: session.id,
                        expectedPhases: [.transcribing],
                        expectedOperationID: operationID,
                        update: { persisted in
                            persisted.phase = .failed
                            persisted.errorMessage = message
                            persisted.meetingOperationID = nil
                        }
                    )
                    self.meetingStatusText = message
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
                    self.refreshHistory()
                } operation: { [engine] progress in
                    try await engine.transcribeDetailed(audioURL: audioURL, progress: progress)
                }
                guard case .completed(let detailedTranscription) = outcome else { return }
                try ensureMeetingLifecycleActive(sessionID: session.id, operationID: operationID)
                var completedSession = session
                let text = postProcessTranscript(detailedTranscription.text)
                if let latestSession = try? store.recordingSession(id: session.id) {
                    completedSession.manualNotes = latestSession.manualNotes
                }
                let finalTranscript = try await finalizeMeetingTranscript(
                    session: completedSession,
                    text: text,
                    detailedTranscription: DetailedTranscriptionResult(
                        text: text,
                        duration: detailedTranscription.duration,
                        tokens: detailedTranscription.tokens
                    ),
                    audioURL: audioURL,
                    operationID: operationID
                )
                try ensureMeetingLifecycleActive(sessionID: session.id, operationID: operationID)
                completedSession.phase = .completed
                completedSession.meetingOperationID = nil
                completedSession.title = finalTranscript.resolvedTitle
                completedSession.transcriptID = finalTranscript.transcript.id
                completedSession.engineIdentifier = engine.identifier
                completedSession.errorMessage = nil
                cleanupNonRetainedAudio(for: &completedSession)
                guard try store.completeMeetingSession(
                    completedSession,
                    transcript: finalTranscript.transcript,
                    expectedOperationID: operationID
                ) else { return }
                cacheTranscript(finalTranscript.transcript)
                scheduleICloudSyncAfterLocalChange(reason: "meeting_completed")
                meetingStatusText = "Ready"
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
                refreshHistory()
            } catch is CancellationError {
                if activeSession?.id == session.id {
                    activeSession = nil
                }
                if isCurrentMeetingLifecycle(sessionID: session.id, operationID: operationID) {
                    finishMeetingLifecycle(sessionID: session.id)
                }
                meetingStatusText = "Ready"
                refreshHistory()
            } catch {
                guard isCurrentMeetingLifecycle(sessionID: session.id, operationID: operationID) else { return }
                _ = try? store.transitionMeetingSession(
                    id: session.id,
                    expectedPhases: [.transcribing],
                    expectedOperationID: operationID,
                    update: { persisted in
                        persisted.phase = .failed
                        persisted.errorMessage = error.localizedDescription
                        persisted.meetingOperationID = nil
                    }
                )
                meetingStatusText = error.localizedDescription
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
                refreshHistory()
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
        audioURL: URL?,
        operationID: UUID
    ) async throws -> FinalizedMeetingTranscript {
        var speakerTranscript: String?
        var diarizationState: MeetingProcessingState = audioURL == nil ? .unavailable : .processing
        var diarizationErrorMessage: String?

        if let audioURL {
            try ensureMeetingLifecycleActive(sessionID: session.id, operationID: operationID)
            meetingStatusText = "Diarizing"
            do {
                let diarizationSegments = try await engine.diarize(audioURL: audioURL)
                try ensureMeetingLifecycleActive(sessionID: session.id, operationID: operationID)
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
            try ensureMeetingLifecycleActive(sessionID: session.id, operationID: operationID)
        }

        var summaryText: String?
        var summaryState: MeetingProcessingState = MuesliPreferences.meetingSummariesEnabled ? .processing : .notStarted
        var summaryBackend: String?
        var summaryModel: String?
        var summaryErrorMessage: String?
        var resolvedTitle = session.title

        if MuesliPreferences.meetingSummariesEnabled {
            try ensureMeetingLifecycleActive(sessionID: session.id, operationID: operationID)
            meetingStatusText = "Summarizing"
            let summarySource = speakerTranscript?.isEmpty == false ? speakerTranscript! : text
            do {
                let summary = try await MeetingSummaryClient.summarize(
                    transcript: summarySource,
                    meetingTitle: session.title ?? session.kind.title,
                    manualNotesToRetain: session.manualNotes
                )
                try ensureMeetingLifecycleActive(sessionID: session.id, operationID: operationID)
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
            try ensureMeetingLifecycleActive(sessionID: session.id, operationID: operationID)
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
        try ensureMeetingLifecycleActive(sessionID: session.id, operationID: operationID)
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
        meetingStatusText = "Ready"
        finishMeetingLifecycle(sessionID: session.id)
        refreshHistory()
    }

    private func startMetering(update: @escaping @MainActor (Double) -> Void) {
        beginMetering(
            readPower: { [weak self] in
                guard let self else { return -160 }
                if self.keyboardSessionKeeper.isRecordingSegment {
                    return Double(self.keyboardSessionKeeper.currentPower())
                }
                return Double(self.realtimeDictationRecorder?.currentPower() ?? self.recorder.currentPower())
            },
            update: update
        )
    }

    private func beginMetering(
        readPower: @escaping @MainActor () -> Double,
        update: @escaping @MainActor (Double) -> Void
    ) {
        meteringTask?.cancel()
        meteringTask = Task { @MainActor [weak self] in
            var smoothedLevel = 0.0

            while !Task.isCancelled {
                // The callbacks intentionally capture the coordinator weakly.
                // End this unstructured loop when its owner disappears instead
                // of leaving a 20 Hz orphan task alive for the process lifetime.
                guard self != nil else { return }
                let normalized = min(max((readPower() + 50) / 50, 0), 1)
                // 0.48 at 20 Hz preserves approximately the same response time
                // as the previous 0.35 smoothing factor at 30 Hz.
                smoothedLevel = (0.48 * normalized) + (0.52 * smoothedLevel)
                update(smoothedLevel)
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func startRecordingTimer(startedAt: Date) {
        recordingTimerTask?.cancel()
        recordingTimerStartedAt = startedAt
        recordingElapsedTime = currentRecordingElapsedTime()
        recordingTimerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let elapsed = self.currentRecordingElapsedTime()
                self.recordingElapsedTime = elapsed
                let fractionalSecond = elapsed - elapsed.rounded(.down)
                let delay = max(0.05, 1 - fractionalSecond)
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    private func stopRecordingTimer() {
        recordingTimerTask?.cancel()
        recordingTimerTask = nil
        recordingTimerStartedAt = nil
        recordingElapsedTime = 0
    }

    private func currentRecordingElapsedTime(now: Date = .now) -> TimeInterval {
        VoiceNoteElapsedClock.exactElapsed(
            startedAt: recordingTimerStartedAt,
            now: now,
            fallback: recordingElapsedTime
        )
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
        beginMetering(
            readPower: { [weak self] in
                Double(self?.meetingRecorder?.currentPower() ?? -160)
            },
            update: { [weak self] level in
                self?.inputLevel = level
            }
        )
    }

    private func stopMetering() {
        meteringTask?.cancel()
        meteringTask = nil
        inputLevel = 0
        onboardingTestInputLevel = 0
    }

    private func startSharedEventObservation() {
        sharedEventObservationTask?.cancel()
        sharedEventObservationTask = Task { @MainActor [weak self, eventBus] in
            for await event in eventBus.events() {
                guard !Task.isCancelled, let self else { return }
                guard event == .commandChanged else { continue }
                await self.processPendingKeyboardCommand()
            }
        }
    }

    private func processPendingKeyboardCommand() async {
        guard !keyboardCommandProcessingInProgress else { return }
        keyboardCommandProcessingInProgress = true
        defer { keyboardCommandProcessingInProgress = false }

        guard let command = try? store.pendingCommand() else { return }
        guard !rejectConflictingKeyboardCommand(
            requestID: command.requestID,
            action: command.action
        ) else {
            try? store.clearPendingCommand()
            return
        }
        if KeyboardCommandArbitration.shouldDeferUntilRecorderStarts(
            action: command.action,
            activeRequestMatches: activeRequest?.id == command.requestID,
            hasActiveSession: activeSession != nil,
            isRecording: isRecording
        ) {
            // Recorder startup is still awaiting permission or audio setup. Keep
            // the durable command in SQLite and consume it after startup settles.
            return
        }
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
            try? store.clearPendingCommand()
            return
        case .cancel:
            saveKeyboardHandoff(
                requestID: command.requestID,
                phase: .cancelled,
                message: "Cancelled"
            )
            cancelRecording(requestID: command.requestID)
            try? store.clearPendingCommand()
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
            try? store.clearPendingCommand()
            return
        }

        transitionKeyboardSession(.handoffStarted(request.id))
        startRecording(for: request, source: "keyboard")
        try? store.clearPendingCommand()
    }

    private func publishKeyboardSessionReadyIfAvailable() {
        guard MuesliPreferences.keyboardSessionModeEnabled, canStartKeyboardRequestsInBackground else { return }
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
        let status = keyboardRuntimeStatus(
            isActive: isActive,
            activeRequestID: activeRequestID,
            phase: phase,
            message: message,
            supportsBackgroundStart: supportsBackgroundStart,
            inputLevel: inputLevel
        )

        // Lifecycle writes stay ordered behind any queued waveform samples so a
        // stale recording level cannot overwrite a later terminal phase.
        keyboardRuntimeStatusQueue.sync {
            try? store.saveKeyboardRuntimeStatus(status)
        }
    }

    private func keyboardRuntimeStatus(
        isActive: Bool,
        activeRequestID: UUID?,
        phase: DictationPhase,
        message: String?,
        supportsBackgroundStart: Bool,
        inputLevel: Double?
    ) -> KeyboardRuntimeStatus {
        let runtimeInputLevel = inputLevel ?? (phase == .recording ? self.inputLevel : 0)
        let canAcceptStartCommand = isActive
            && supportsBackgroundStart
            && activeRequestID == nil
            && phase == .idle
        return KeyboardRuntimeStatus(
            isActive: isActive,
            activeRequestID: activeRequestID,
            phase: phase,
            message: message,
            supportsBackgroundStart: supportsBackgroundStart,
            canAcceptStartCommand: canAcceptStartCommand,
            inputLevel: runtimeInputLevel
        )
    }

    private func publishKeyboardRuntimeLevel(_ level: Double, requestID: UUID) {
        guard activeRequest?.id == requestID, isRecording else { return }
        guard let publishedLevel = keyboardWaveformLevelThrottle.valueToPublish(level) else { return }
        let status = keyboardRuntimeStatus(
            isActive: true,
            activeRequestID: requestID,
            phase: .recording,
            message: "Listening",
            supportsBackgroundStart: false,
            inputLevel: publishedLevel
        )
        let store = store
        keyboardRuntimeStatusQueue.async {
            try? store.saveKeyboardRuntimeStatus(status)
        }
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
                self?.handleTranscriptionBackgroundTaskExpiration()
            }
        }
    }

    private func handleTranscriptionBackgroundTaskExpiration() {
        defer { endTranscriptionBackgroundTask() }
        guard case .transcribing(let sessionID) = meetingLifecycleState.phase,
              let operationID = meetingLifecycleRunner?.id
        else { return }

        meetingLifecycleRunner?.finalizationTask?.cancel()
        let recovered: RecordingSession?
        do {
            recovered = try store.transitionMeetingSession(
                id: sessionID,
                expectedPhases: [.transcribing],
                expectedOperationID: operationID,
                update: { session in
                    session.phase = .transcriptionQueued
                    session.errorMessage = "Processing paused in the background. Tap Transcribe to continue."
                    session.meetingOperationID = nil
                }
            )
        } catch {
            recovered = nil
        }
        cleanupMeetingChunks(cancelTasks: true)
        finishMeetingLifecycle(sessionID: sessionID)
        meetingStatusText = recovered?.errorMessage ?? "Processing paused"
        refreshHistory()
        AppTelemetry.signal("meeting_transcription_deferred", parameters: [
            "reason": "background_time_expired",
        ])
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
            clearPersistentKeyboardSessionRoute(for: requestID)
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
        let usesPersistentKeyboardSession = usesPersistentKeyboardSession(for: requestID)
        stopMetering()
        stopRecordingTimer()
        if usesPersistentKeyboardSession {
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
            if usesPersistentKeyboardSession {
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
        clearPersistentKeyboardSessionRoute(for: requestID)
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

private enum TranscriptionModelRemovalError: LocalizedError {
    case modelInUse

    var errorDescription: String? {
        "Finish active recording, transcription, or model preparation before removing a model."
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
