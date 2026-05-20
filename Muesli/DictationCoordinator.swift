import AVFoundation
import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class DictationCoordinator {
    private static let onboardingCompletedKey = "muesli.onboarding.completed"
    private static let userNameKey = "muesli.onboarding.userName"
    private static let useCaseKey = "muesli.onboarding.useCase"

    private let store = SharedStore()
    private let engine = FluidAudioTranscriptionEngine()
    private let recorder = AudioRecorder()
    private let keyboardSessionKeeper = KeyboardSessionKeeper()
    private let liveActivityController = MuesliLiveActivityController()
    private var modelPreparationTask: Task<Void, Never>?
    private var meteringTask: Task<Void, Never>?
    private var commandPollingTask: Task<Void, Never>?
    private var keyboardRuntimePollingTask: Task<Void, Never>?
    private var keyboardSessionTimeoutTask: Task<Void, Never>?
    private var transcriptionBackgroundTask: UIBackgroundTaskIdentifier = .invalid

    private var activeRequest: DictationRequest?
    private var activeSession: RecordingSession?
    private var keyboardSessionActivitySession: RecordingSession?
    var isKeyboardHandoffActive = false
    var isKeyboardSessionArmed = false
    var keyboardSessionStatusText = "Off"
    var hasCompletedOnboarding = UserDefaults.standard.bool(forKey: onboardingCompletedKey)
    var userName = UserDefaults.standard.string(forKey: userNameKey) ?? ""
    var selectedUseCase = OnboardingUseCase(
        rawValue: UserDefaults.standard.string(forKey: useCaseKey) ?? ""
    ) ?? .keyboardDictation
    var modelPreparation = ModelPreparationState()
    var isOnboardingTestRecording = false
    var isOnboardingTestTranscribing = false
    var onboardingTestInputLevel = 0.0
    var onboardingTestTranscript = ""
    var onboardingTestError: String?
    var isRecording = false
    var inputLevel = 0.0
    var statusText = "Ready"
    var meetingStatusText = "Ready"
    var lastTranscript = ""
    var dictationHistory: [DictationResult] = []
    var recordingSessions: [RecordingSession] = []
    var isMeetingRecording = false
    var isMeetingTranscribing = false
    var activeMeetingTitle = "Untitled Meeting"
    var clipboardStatusText: String?

    init() {
        #if DEBUG
        if Self.shouldResetOnboardingFromLaunchArguments() {
            resetOnboardingForTesting()
        }
        #endif

        refreshHistory()
        Task {
            await liveActivityController.endInactiveActivities()
        }
        if MuesliPreferences.keyboardSessionModeEnabled {
            Task { @MainActor in
                await startKeyboardSessionMode()
            }
        }
    }

    func handleOpenURL(_ url: URL) {
        #if DEBUG
        if handleDebugURL(url) {
            return
        }
        #endif

        guard url.scheme == MuesliAppConstants.urlScheme,
              url.host == MuesliAppConstants.dictateHost,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let value = components.queryItems?.first(where: { $0.name == MuesliAppConstants.requestQueryItem })?.value,
              let requestID = UUID(uuidString: value)
        else { return }

        let action = components.queryItems?.first(where: { $0.name == MuesliAppConstants.actionQueryItem })?.value
            ?? MuesliAppConstants.startAction
        if action == MuesliAppConstants.stopAction {
            stopRecording(requestID: requestID)
            return
        }

        let pendingRequest = try? store.pendingRequest()
        let request = pendingRequest?.id == requestID
            ? pendingRequest!
            : DictationRequest(id: requestID)
        isKeyboardHandoffActive = true
        activeRequest = request
        startKeyboardRuntimePolling()
        startRecording(for: request, source: "keyboard")
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
    #endif

    func toggleRecording() {
        if isRecording {
            MuesliHaptics.dictationStop()
            stopRecording()
        } else if statusText != "Transcribing" {
            MuesliHaptics.dictationStart()
            startRecording(for: DictationRequest(), source: "app")
        }
    }

    func refreshHistory() {
        do {
            dictationHistory = try store.resultsHistory()
            recordingSessions = try store.recordingSessions()
            lastTranscript = dictationHistory.first?.text ?? lastTranscript
        } catch {
            statusText = error.localizedDescription
        }
    }

    private func postProcessTranscript(_ text: String) -> String {
        TranscriptPostProcessor(store: store).process(text)
    }

    func copyToClipboard(_ result: DictationResult) {
        UIPasteboard.general.string = result.text
        clipboardStatusText = "Copied"
        AppTelemetry.signal("dictation_copied")

        Task {
            try? await Task.sleep(for: .seconds(1.2))
            if clipboardStatusText == "Copied" {
                clipboardStatusText = nil
            }
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

    private func clearClipboardStatusSoon() {
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            if clipboardStatusText == "Copied" {
                clipboardStatusText = nil
            }
        }
    }

    func applyLiveActivityPreferences() {
        Task {
            await liveActivityController.endDisabledActivities()
        }
    }

    func setKeyboardSessionModeEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: MuesliPreferences.keyboardSessionModeKey)
        if enabled {
            Task { await startKeyboardSessionMode() }
        } else {
            stopKeyboardSessionMode(reason: "Turned off")
        }
    }

    func refreshKeyboardSessionTimeout() {
        guard isKeyboardSessionArmed else { return }
        scheduleKeyboardSessionTimeout()
    }

    func startKeyboardSessionMode() async {
        guard !isKeyboardSessionArmed else {
            saveKeyboardRuntimeStatus(
                isActive: true,
                activeRequestID: activeRequest?.id,
                phase: isRecording ? .recording : .idle,
                message: isRecording ? "Listening" : "Keyboard session ready",
                supportsBackgroundStart: true
            )
            return
        }

        keyboardSessionStatusText = "Starting"
        do {
            try await keyboardSessionKeeper.start()
            isKeyboardSessionArmed = true
            keyboardSessionStatusText = "Ready"
            isKeyboardHandoffActive = false
            startKeyboardRuntimePolling()
            scheduleKeyboardSessionTimeout()

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
                detail: "Keyboard dictation session active"
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
            isKeyboardSessionArmed = false
            keyboardSessionStatusText = error.localizedDescription
            saveKeyboardRuntimeStatus(
                isActive: false,
                activeRequestID: nil,
                phase: .failed,
                message: error.localizedDescription
            )
            AppTelemetry.signal("keyboard_session_failed", parameters: ["error": String(describing: type(of: error))])
        }
    }

    func stopKeyboardSessionMode(reason: String = "Stopped") {
        keyboardSessionTimeoutTask?.cancel()
        keyboardSessionTimeoutTask = nil
        isKeyboardSessionArmed = false
        keyboardSessionStatusText = "Off"
        keyboardSessionKeeper.stop(deactivateSession: !isRecording)
        saveKeyboardRuntimeStatus(
            isActive: false,
            activeRequestID: activeRequest?.id,
            phase: activeRequest == nil ? .idle : .recording,
            message: reason
        )

        if let session = keyboardSessionActivitySession {
            Task {
                await liveActivityController.end(
                    phase: "Ended",
                    detail: reason,
                    session: session,
                    dismissal: .immediate
                )
            }
        }
        keyboardSessionActivitySession = nil
        AppTelemetry.signal("keyboard_session_stopped", parameters: ["reason": reason])
    }

    func transcript(for session: RecordingSession) -> Transcript? {
        try? store.transcript(for: session.id)
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

        modelPreparationTask?.cancel()
        modelPreparation = ModelPreparationState(
            phase: .downloading,
            progress: 0,
            status: "Checking model files...",
            detail: "Parakeet v3"
        )
        AppTelemetry.signal("model_prepare_started", parameters: ["engine": engine.identifier])

        let coordinator = self
        modelPreparationTask = Task { [engine] in
            do {
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
                        status: "Parakeet v3 ready",
                        detail: "Ready for on-device dictation"
                    )
                    AppTelemetry.signal("model_prepare_completed", parameters: ["engine": coordinator.engine.identifier])
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
                    AppTelemetry.signal(
                        "model_prepare_failed",
                        parameters: [
                            "engine": coordinator.engine.identifier,
                            "error": String(describing: type(of: error))
                        ]
                    )
                }
            }
        }
    }

    func prepareModel() {
        prepareModelForOnboarding()
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
                AppTelemetry.signal("onboarding_test_failed", parameters: ["stage": "recording"])
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
                let text = postProcessTranscript(try await engine.transcribe(audioURL: audioURL))
                isOnboardingTestTranscribing = false
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
                AppTelemetry.signal(
                    "onboarding_test_failed",
                    parameters: [
                        "stage": "transcription",
                        "engine": engine.identifier,
                        "error": String(describing: type(of: error))
                    ]
                )
            }
        }
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
            status: phase == .preparing ? "Optimizing for this iPhone..." : "Downloading Parakeet v3",
            detail: detail
        )
    }

    private func startRecording(for request: DictationRequest, source: String) {
        guard !isRecording, !isMeetingRecording, statusText != "Transcribing" else { return }
        activeRequest = request
        let kind: RecordingSessionKind = source == "keyboard" ? .keyboardDictation : .quickDictation
        var session = RecordingSession(requestID: request.id, kind: kind)

        Task {
            do {
                let audioURL = try store.newAudioFileURL(sessionID: session.id)
                session.audioFileName = audioURL.lastPathComponent
                session.startedAt = .now
                try store.saveSession(session)
                try await recorder.requestPermission()
                if source == "keyboard", isKeyboardSessionArmed {
                    keyboardSessionKeeper.stop(deactivateSession: false)
                    keyboardSessionStatusText = "Recording"
                }
                try recorder.start(outputURL: audioURL)
                activeSession = session
                isRecording = true
                if source == "keyboard" {
                    startKeyboardRuntimePolling()
                    saveKeyboardRuntimeStatus(
                        isActive: true,
                        activeRequestID: request.id,
                        phase: .recording,
                        message: "Listening",
                        supportsBackgroundStart: isKeyboardSessionArmed
                    )
                }
                startMetering { [weak self] level in
                    self?.inputLevel = level
                }
                if source == "keyboard" {
                    startCommandPolling(for: request.id)
                }
                statusText = "Recording"
                AppTelemetry.signal("dictation_started", parameters: ["source": source])
                try store.saveRequest(request)
                try store.saveStatus(.init(requestID: request.id, phase: .recording))
                Task {
                    await liveActivityController.start(
                        session: session,
                        requestID: request.id,
                        phase: "Listening",
                        detail: source == "keyboard" ? "Keyboard dictation active" : "Recording dictation"
                    )
                }
            } catch {
                session.phase = .failed
                session.errorMessage = error.localizedDescription
                try? store.saveSession(session)
                activeSession = nil
                activeRequest = nil
                statusText = error.localizedDescription
                stopMetering()
                resumeKeyboardSessionKeeperIfNeeded()
                AppTelemetry.signal("dictation_failed", parameters: ["stage": "recording"])
                try? store.saveStatus(.init(requestID: request.id, phase: .failed, message: error.localizedDescription))
            }
        }
    }

    private func stopRecording() {
        guard let request = activeRequest else { return }
        stopRecording(requestID: request.id)
    }

    private func stopRecording(requestID: UUID) {
        let request: DictationRequest
        var session = activeSession
        if let activeRequest, activeRequest.id == requestID {
            request = activeRequest
        } else if let pendingRequest = try? store.pendingRequest(), pendingRequest.id == requestID {
            request = pendingRequest
            activeRequest = pendingRequest
            session = try? store.recordingSession(requestID: requestID)
        } else {
            let message = "No active recording found. Start a new dictation."
            statusText = message
            try? store.saveStatus(.init(requestID: requestID, phase: .failed, message: message))
            return
        }

        isRecording = false
        stopMetering()
        stopCommandPolling()
        statusText = "Transcribing"
        try? store.saveStatus(.init(requestID: request.id, phase: .transcribing, message: "Transcribing"))
        if isKeyboardHandoffActive {
            saveKeyboardRuntimeStatus(
                isActive: true,
                activeRequestID: request.id,
                phase: .transcribing,
                message: "Transcribing",
                supportsBackgroundStart: isKeyboardSessionArmed
            )
        }
        if var session {
            session.phase = .transcribing
            session.endedAt = .now
            try? store.saveSession(session)
            activeSession = session
            Task {
                await liveActivityController.update(
                    phase: "Transcribing",
                    detail: "Preparing text for the keyboard",
                    session: session
                )
            }
        }

        beginTranscriptionBackgroundTask()
        Task {
            defer { endTranscriptionBackgroundTask() }

            do {
                let audioURL = try recorder.stop()
                if isKeyboardSessionArmed {
                    try? await keyboardSessionKeeper.start()
                    keyboardSessionStatusText = "Transcribing"
                }
                let text = postProcessTranscript(try await engine.transcribe(audioURL: audioURL))
                let completedSession = activeSession ?? session
                let transcript: Transcript?
                if var completedSession {
                    let savedTranscript = Transcript(
                        sessionID: completedSession.id,
                        text: text,
                        engineIdentifier: engine.identifier
                    )
                    try store.saveTranscript(savedTranscript)
                    completedSession.phase = .completed
                    completedSession.audioFileName = completedSession.audioFileName ?? audioURL.lastPathComponent
                    completedSession.transcriptID = savedTranscript.id
                    completedSession.engineIdentifier = engine.identifier
                    completedSession.errorMessage = nil
                    try store.saveSession(completedSession)
                    transcript = savedTranscript
                } else {
                    transcript = nil
                }
                let result = DictationResult(
                    requestID: request.id,
                    sessionID: transcript?.sessionID,
                    text: text,
                    engineIdentifier: engine.identifier
                )
                try store.saveResult(result)
                try store.clearPendingRequest()
                refreshHistory()
                lastTranscript = text
                activeRequest = nil
                activeSession = nil
                if isKeyboardHandoffActive {
                    saveKeyboardRuntimeStatus(
                        isActive: true,
                        activeRequestID: nil,
                        phase: .idle,
                        message: isKeyboardSessionArmed ? "Keyboard session ready" : "Ready",
                        supportsBackgroundStart: isKeyboardSessionArmed
                    )
                }
                isKeyboardHandoffActive = false
                resumeKeyboardSessionKeeperIfNeeded()
                statusText = "Ready"
                if let completedSession = try? store.recordingSession(requestID: request.id) {
                    Task {
                        await liveActivityController.end(
                            phase: "Completed",
                            detail: "Transcript saved",
                            session: completedSession,
                            dismissal: .immediate
                        )
                    }
                }
                AppTelemetry.signal(
                    "dictation_completed",
                    parameters: [
                        "engine": engine.identifier,
                        "empty": text.isEmpty ? "true" : "false"
                    ]
                )
            } catch {
                if var session = activeSession ?? session {
                    session.phase = .failed
                    session.errorMessage = error.localizedDescription
                    try? store.saveSession(session)
                }
                activeRequest = nil
                activeSession = nil
                saveKeyboardRuntimeStatus(
                    isActive: isKeyboardHandoffActive || isKeyboardSessionArmed,
                    activeRequestID: nil,
                    phase: .failed,
                    message: error.localizedDescription,
                    supportsBackgroundStart: isKeyboardSessionArmed
                )
                isKeyboardHandoffActive = false
                resumeKeyboardSessionKeeperIfNeeded()
                statusText = error.localizedDescription
                refreshHistory()
                AppTelemetry.signal(
                    "dictation_failed",
                    parameters: [
                        "stage": "transcription",
                        "engine": engine.identifier,
                        "error": String(describing: type(of: error))
                    ]
                )
                try? store.saveStatus(.init(requestID: request.id, phase: .failed, message: error.localizedDescription))
            }
        }
    }

    func startMeetingRecording(title: String = "Untitled Meeting") {
        guard !isRecording, !isMeetingRecording, !isMeetingTranscribing, statusText != "Transcribing" else { return }
        MuesliHaptics.dictationStart()
        activeMeetingTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Untitled Meeting"
            : title.trimmingCharacters(in: .whitespacesAndNewlines)
        var session = RecordingSession(kind: .meeting, title: activeMeetingTitle)
        session.keepsAudioRecording = MuesliPreferences.keepMeetingAudioRecordingsEnabled

        Task {
            do {
                let audioURL = try store.newAudioFileURL(sessionID: session.id)
                session.audioFileName = audioURL.lastPathComponent
                session.startedAt = .now
                try store.saveSession(session)
                try await recorder.requestPermission()
                try recorder.start(outputURL: audioURL)
                activeSession = session
                isMeetingRecording = true
                meetingStatusText = "Recording"
                startMetering { [weak self] level in
                    self?.inputLevel = level
                }
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
            } catch {
                session.phase = .failed
                session.errorMessage = error.localizedDescription
                try? store.saveSession(session)
                activeSession = nil
                meetingStatusText = error.localizedDescription
                stopMetering()
                refreshHistory()
                AppTelemetry.signal("meeting_recording_failed", parameters: ["stage": "recording"])
            }
        }
    }

    func stopMeetingRecording(queueForTranscription: Bool = true) {
        guard isMeetingRecording, var session = activeSession, session.kind == .meeting else { return }
        MuesliHaptics.dictationStop()
        isMeetingRecording = false
        stopMetering()
        meetingStatusText = queueForTranscription ? "Queued for transcription" : "Transcribing"

        do {
            let audioURL = try recorder.stop()
            session.audioFileName = session.audioFileName ?? audioURL.lastPathComponent
            session.keepsAudioRecording = MuesliPreferences.keepMeetingAudioRecordingsEnabled
            session.endedAt = .now
            session.phase = queueForTranscription ? .transcriptionQueued : .transcribing
            try store.saveSession(session)
            activeSession = nil
            refreshHistory()
            Task {
                await liveActivityController.end(
                    phase: queueForTranscription ? "Queued" : "Transcribing",
                    detail: queueForTranscription ? "Saved for delayed transcription" : "Transcribing locally",
                    session: session
                )
            }
            AppTelemetry.signal("meeting_recording_stopped", parameters: [
                "queued": queueForTranscription ? "true" : "false"
            ])

            if !queueForTranscription {
                transcribeSession(session)
            }
        } catch {
            session.phase = .failed
            session.errorMessage = error.localizedDescription
            try? store.saveSession(session)
            activeSession = nil
            meetingStatusText = error.localizedDescription
            refreshHistory()
            AppTelemetry.signal("meeting_recording_failed", parameters: ["stage": "stop"])
        }
    }

    func transcribeSession(_ session: RecordingSession) {
        guard !isRecording, !isMeetingRecording, !isMeetingTranscribing else { return }
        guard let audioFileName = session.audioFileName else { return }
        var session = session
        session.phase = .transcribing
        session.errorMessage = nil
        session.keepsAudioRecording = MuesliPreferences.keepMeetingAudioRecordingsEnabled
        try? store.saveSession(session)
        refreshHistory()
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
        Task {
            defer {
                endTranscriptionBackgroundTask()
                isMeetingTranscribing = false
            }

            do {
                let audioURL = try store.audioFileURL(fileName: audioFileName)
                let detailedTranscription = try await engine.transcribeDetailed(audioURL: audioURL)
                let text = postProcessTranscript(detailedTranscription.text)
                var speakerTranscript: String?
                var diarizationState: MeetingProcessingState = .processing
                var diarizationErrorMessage: String?
                meetingStatusText = "Diarizing"

                do {
                    let diarizationSegments = try await engine.diarize(audioURL: audioURL)
                    speakerTranscript = MeetingTranscriptFormatter.speakerTranscript(
                        transcription: DetailedTranscriptionResult(
                            text: text,
                            duration: detailedTranscription.duration,
                            tokens: detailedTranscription.tokens
                        ),
                        diarizationSegments: diarizationSegments,
                        meetingStart: session.startedAt ?? session.createdAt
                    )
                    diarizationState = .completed
                } catch {
                    speakerTranscript = nil
                    diarizationState = .failed
                    diarizationErrorMessage = error.localizedDescription
                    AppTelemetry.signal("meeting_diarization_failed", parameters: [
                        "error": String(describing: type(of: error))
                    ])
                }

                var summaryText: String?
                var summaryState: MeetingProcessingState = MuesliPreferences.meetingSummariesEnabled ? .processing : .notStarted
                var summaryBackend: String?
                var summaryModel: String?
                var summaryErrorMessage: String?
                var resolvedTitle = session.title

                if MuesliPreferences.meetingSummariesEnabled {
                    meetingStatusText = "Summarizing"
                    let summarySource = speakerTranscript?.isEmpty == false ? speakerTranscript! : text
                    do {
                        let summary = try await MeetingSummaryClient.summarize(
                            transcript: summarySource,
                            meetingTitle: session.title ?? session.kind.title
                        )
                        summaryText = summary.notes
                        summaryState = .completed
                        summaryBackend = summary.backend.rawValue
                        summaryModel = summary.model
                        if !summary.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            resolvedTitle = summary.title
                        }
                    } catch {
                        summaryText = MeetingSummaryClient.failureNotes(
                            transcript: summarySource,
                            meetingTitle: session.title ?? session.kind.title,
                            error: error
                        )
                        summaryState = .failed
                        summaryBackend = MuesliPreferences.meetingSummaryBackend.rawValue
                        summaryModel = MuesliPreferences.meetingSummaryBackend == .chatGPT
                            ? MuesliPreferences.chatGPTModel
                            : MuesliPreferences.openRouterModel
                        summaryErrorMessage = error.localizedDescription
                        AppTelemetry.signal("meeting_summary_failed", parameters: [
                            "backend": summaryBackend ?? "unknown",
                            "error": String(describing: type(of: error))
                        ])
                    }
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
                try store.saveTranscript(transcript)
                session.phase = .completed
                session.title = resolvedTitle
                session.transcriptID = transcript.id
                session.engineIdentifier = engine.identifier
                session.errorMessage = nil
                if !session.keepsAudioRecording {
                    try? store.deleteAudioFile(fileName: audioFileName)
                    session.audioFileName = nil
                }
                try store.saveSession(session)
                meetingStatusText = "Ready"
                refreshHistory()
                await liveActivityController.end(
                    phase: "Completed",
                    detail: summaryText == nil ? "Meeting transcript saved" : "Meeting notes saved",
                    session: session
                )
                AppTelemetry.signal("meeting_transcription_completed", parameters: [
                    "engine": engine.identifier,
                    "empty": text.isEmpty ? "true" : "false",
                    "diarized": diarizationState == .completed ? "true" : "false",
                    "summarized": summaryState == .completed ? "true" : "false"
                ])
            } catch {
                session.phase = .failed
                session.errorMessage = error.localizedDescription
                try? store.saveSession(session)
                meetingStatusText = error.localizedDescription
                refreshHistory()
                await liveActivityController.end(
                    phase: "Failed",
                    detail: "Transcription failed",
                    session: session
                )
                AppTelemetry.signal("meeting_transcription_failed", parameters: [
                    "engine": engine.identifier,
                    "error": String(describing: type(of: error))
                ])
            }
        }
    }

    private func startMetering(update: @escaping @MainActor (Double) -> Void) {
        meteringTask?.cancel()
        meteringTask = Task { @MainActor [weak self] in
            var smoothedLevel = 0.0

            while !Task.isCancelled {
                guard let self else { return }
                let power = Double(self.recorder.currentPower())
                let normalized = min(max((power + 50) / 50, 0), 1)
                smoothedLevel = (0.35 * normalized) + (0.65 * smoothedLevel)
                update(smoothedLevel)
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
                        self.stopRecording(requestID: requestID)
                    case .cancel:
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
                self.refreshKeyboardRuntimeHeartbeat()

                if let command = try? self.store.pendingCommand(), command.action == .start {
                    try? self.store.clearPendingCommand()
                    guard !self.isRecording, !self.isMeetingRecording, self.statusText != "Transcribing" else {
                        try? self.store.saveStatus(.init(
                            requestID: command.requestID,
                            phase: .failed,
                            message: "Muesli is busy"
                        ))
                        try? await Task.sleep(for: .milliseconds(500))
                        continue
                    }

                    let pendingRequest = try? self.store.pendingRequest()
                    let request = pendingRequest?.id == command.requestID
                        ? pendingRequest!
                        : DictationRequest(id: command.requestID)
                    self.isKeyboardHandoffActive = true
                    self.activeRequest = request
                    self.startRecording(for: request, source: "keyboard")
                }

                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func refreshKeyboardRuntimeHeartbeat() {
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
            isActive: isKeyboardSessionArmed || isRecording || activeRequest != nil,
            activeRequestID: activeRequest?.id,
            phase: phase,
            message: message,
            supportsBackgroundStart: isKeyboardSessionArmed
        )
    }

    private func saveKeyboardRuntimeStatus(
        isActive: Bool,
        activeRequestID: UUID?,
        phase: DictationPhase,
        message: String?,
        supportsBackgroundStart: Bool = false
    ) {
        try? store.saveKeyboardRuntimeStatus(.init(
            isActive: isActive,
            activeRequestID: activeRequestID,
            phase: phase,
            message: message,
            supportsBackgroundStart: supportsBackgroundStart
        ))
    }

    private func scheduleKeyboardSessionTimeout() {
        keyboardSessionTimeoutTask?.cancel()
        let timeoutMinutes = MuesliPreferences.keyboardSessionTimeoutMinutes
        keyboardSessionTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(timeoutMinutes * 60))
            guard let self, self.isKeyboardSessionArmed else { return }
            self.stopKeyboardSessionMode(reason: "Timed out")
        }
    }

    private func resumeKeyboardSessionKeeperIfNeeded() {
        guard isKeyboardSessionArmed, !isRecording, !isMeetingRecording else { return }
        keyboardSessionStatusText = "Resuming"
        Task { @MainActor [weak self] in
            guard let self, self.isKeyboardSessionArmed else { return }
            do {
                try await self.keyboardSessionKeeper.start()
                self.keyboardSessionStatusText = "Ready"
                self.scheduleKeyboardSessionTimeout()
                self.saveKeyboardRuntimeStatus(
                    isActive: true,
                    activeRequestID: nil,
                    phase: .idle,
                    message: "Keyboard session ready",
                    supportsBackgroundStart: true
                )
                if let session = self.keyboardSessionActivitySession {
                    await self.liveActivityController.start(
                        session: session,
                        requestID: nil,
                        phase: "Ready",
                        detail: "Keyboard dictation session active"
                    )
                }
            } catch {
                self.isKeyboardSessionArmed = false
                self.keyboardSessionStatusText = error.localizedDescription
                self.saveKeyboardRuntimeStatus(
                    isActive: false,
                    activeRequestID: nil,
                    phase: .failed,
                    message: error.localizedDescription
                )
            }
        }
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
        guard activeRequest?.id == requestID else { return }
        isRecording = false
        stopMetering()
        stopCommandPolling()
        _ = try? recorder.stop()
        if var session = activeSession {
            session.phase = .cancelled
            session.endedAt = .now
            try? store.saveSession(session)
            Task {
                await liveActivityController.end(
                    phase: "Cancelled",
                    detail: "Recording cancelled",
                    session: session
                )
            }
        }
        activeRequest = nil
        activeSession = nil
        resumeKeyboardSessionKeeperIfNeeded()
        saveKeyboardRuntimeStatus(
            isActive: isKeyboardSessionArmed,
            activeRequestID: nil,
            phase: .idle,
            message: isKeyboardSessionArmed ? "Keyboard session ready" : "Ready",
            supportsBackgroundStart: isKeyboardSessionArmed
        )
        isKeyboardHandoffActive = false
        statusText = "Ready"
        try? store.clearPendingCommand()
        try? store.clearPendingRequest()
        try? store.saveStatus(.idle)
    }
}
