import AVFoundation
import Foundation
@preconcurrency import FluidAudio
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
    private var meetingRecorder: StreamingMeetingRecorder?
    private var realtimeDictationRecorder: StreamingMeetingRecorder?
    private var realtimeDictationBufferPipe: RealtimeAudioBufferPipe?
    private var realtimeDictationProcessingTask: Task<Void, Never>?
    private var realtimeDictationChunksDirectory: URL?
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
    private var keyboardSessionTimeoutTask: Task<Void, Never>?
    private var iCloudSyncTask: Task<Void, Never>?
    private var iCloudSyncDebounceTask: Task<Void, Never>?
    private var pendingICloudSyncReason: String?
    private var onboardingModelReadyCueModel: LocalTranscriptionModel?
    private var meetingChunkTasks: [Task<MeetingChunkTranscription?, Never>] = []
    private var meetingChunkTranscriptions: [MeetingChunkTranscription] = []
    private var meetingChunksDirectory: URL?
    private let meetingVadQueue = DispatchQueue(label: "com.phequals7.muesli.meeting-vad")
    private var transcriptionBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var audioRouteObserver: NSObjectProtocol?

    private var activeRequest: DictationRequest?
    private var activeSession: RecordingSession?
    private var keyboardSessionActivitySession: RecordingSession?
    var isKeyboardHandoffActive = false
    var isKeyboardSessionArmed = false
    var keyboardSessionStatusText = "Off"
    var iCloudSyncStatusText: String?
    var isICloudSyncInProgress = false
    var syncSetupRequestID: UUID? {
        didSet {
            if syncSetupRequestID == nil {
                syncSetupSource = nil
            }
        }
    }
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
    var isMeetingRecording = false
    var isMeetingTranscribing = false
    var activeMeetingTitle = "Untitled Meeting"
    var clipboardStatusText: String?

    var hasMeetingRecordingInProgress: Bool {
        isMeetingRecording || persistedRecordingMeetingSession != nil
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

        refreshAudioInputRoute()
        refreshHistory()
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

    isolated deinit {
        if let audioRouteObserver {
            NotificationCenter.default.removeObserver(audioRouteObserver)
        }
    }

    func refreshAudioInputRoute() {
        audioInputRouteText = AudioInputRouteManager.currentSnapshot().displayText
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

        guard url.scheme == MuesliAppConstants.urlScheme,
              url.host == MuesliAppConstants.dictateHost,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let value = components.queryItems?.first(where: { $0.name == MuesliAppConstants.requestQueryItem })?.value,
              let requestID = UUID(uuidString: value)
        else { return }

        let action = components.queryItems?.first(where: { $0.name == MuesliAppConstants.actionQueryItem })?.value
            ?? MuesliAppConstants.startAction
        if action == MuesliAppConstants.stopAction {
            saveKeyboardHandoff(
                requestID: requestID,
                phase: .stopAcknowledged,
                message: "Stopping"
            )
            stopRecording(requestID: requestID)
            return
        }

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
        isKeyboardHandoffActive = true
        activeRequest = request
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

        isKeyboardHandoffActive = true
        startKeyboardRuntimePolling()

        if isRecording {
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
                supportsBackgroundStart: isKeyboardSessionArmed
            )
            return true
        }

        if statusText == "Transcribing" || activeSession?.requestID == request.id {
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
                supportsBackgroundStart: isKeyboardSessionArmed
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
            supportsBackgroundStart: isKeyboardSessionArmed
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

        isKeyboardHandoffActive = true
        activeRequest = request
        activeSession = session
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
            supportsBackgroundStart: isKeyboardSessionArmed
        )
        recoverKeyboardTranscription(request: request, session: session, audioURL: audioURL)
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
        isKeyboardHandoffActive = false
        UserDefaults.standard.set(true, forKey: Self.onboardingCompletedKey)
        UserDefaults.standard.set(userName, forKey: Self.userNameKey)
        UserDefaults.standard.set(selectedUseCase.rawValue, forKey: Self.useCaseKey)
        UserDefaults.standard.set(AppSection.defaultPinnedStorage, forKey: MuesliPreferences.pinnedSectionsKey)
        modelPreparation = ModelPreparationState(
            phase: .ready,
            progress: 1,
            status: "\(selectedTranscriptionModel.shortName) ready",
            detail: "UI testing"
        )
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

        clearClipboardStatusSoon()
    }

    func deleteDictation(_ result: DictationResult) {
        do {
            if let session = recordingSession(for: result) {
                if let audioFileName = session.audioFileName {
                    try? store.deleteAudioFile(fileName: audioFileName)
                }
                try? store.deleteTranscript(for: session.id)
                try? store.deleteRecordingSession(id: session.id)
                recordingSessions.removeAll { $0.id == session.id }
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
            guard var session = recordingSession(for: result),
                  let audioFileName = session.audioFileName
            else {
                clipboardStatusText = "Audio already removed"
                clearClipboardStatusSoon()
                return true
            }

            try store.deleteAudioFile(fileName: audioFileName)
            session.audioFileName = nil
            session.keepsAudioRecording = false
            try store.saveSession(session)

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

    func deleteMeeting(_ session: RecordingSession) {
        do {
            if let audioFileName = session.audioFileName {
                try? store.deleteAudioFile(fileName: audioFileName)
            }
            try store.deleteTranscript(for: session.id)
            try store.deleteRecordingSession(id: session.id)
            recordingSessions.removeAll { $0.id == session.id }
            clipboardStatusText = "Deleted"
            AppTelemetry.signal("meeting_deleted")
            clearClipboardStatusSoon()
            scheduleICloudSyncAfterLocalChange(reason: "meeting_deleted")
        } catch {
            clipboardStatusText = "Delete failed"
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
        if let sessionID = result.sessionID,
           let session = try? store.recordingSession(id: sessionID) {
            return session
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
                AppTelemetry.signal(
                    "icloud_text_sync_failed",
                    parameters: ["reason": reason, "error": String(describing: type(of: error))]
                )
                if reason == "onboarding_bridge" || reason == "settings_toggle" {
                    AppTelemetry.signal(
                        "bridge_enable_failed",
                        parameters: ["platform": "ios", "source": reason, "error": String(describing: type(of: error))]
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
            prewarmModelIfNeeded(reason: "keyboard_session")
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
            prewarmModelIfNeeded(reason: "keyboard_session")
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
                    AppTelemetry.signal(
                        "model_prepare_failed",
                        parameters: [
                            "engine": model.engineIdentifier,
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

    func prewarmModelIfNeeded(reason: String) {
        #if DEBUG
        guard !Self.shouldSkipModelPrewarmForTesting() else { return }
        #endif
        guard hasCompletedOnboarding else { return }
        guard modelPrewarmTask == nil else { return }
        guard modelPreparationTask == nil, !modelPreparation.isPreparing else { return }
        guard !isRecording, !isMeetingRecording else { return }

        let model = selectedTranscriptionModel
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
                try await engine.prepare()

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
                    AppTelemetry.signal(
                        "model_prewarm_failed",
                        parameters: [
                            "engine": model.engineIdentifier,
                            "reason": reason,
                            "error": String(describing: type(of: error))
                        ]
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
                    AppTelemetry.signal(
                        "model_prepare_failed",
                        parameters: [
                            "engine": model.engineIdentifier,
                            "error": String(describing: type(of: error))
                        ]
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

    private func startRealtimeDictationRecorder(audioURL: URL, sessionID: UUID) async throws {
        await engine.selectModel(selectedTranscriptionModel)
        realtimeDictationCommittedText = ""
        liveDictationTranscript = ""
        clearKeyboardLiveTranscript()
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

        let chunksDirectory = try meetingChunkDirectory(for: sessionID)
        try? FileManager.default.removeItem(at: chunksDirectory)
        try FileManager.default.createDirectory(at: chunksDirectory, withIntermediateDirectories: true)

        let pipe = RealtimeAudioBufferPipe()
        let streamingRecorder = StreamingMeetingRecorder()
        streamingRecorder.onAudioBuffer = { [pipe] buffer in
            pipe.append(buffer)
        }

        realtimeDictationProcessingTask = Task { [engine, pipe] in
            for await audioBuffer in pipe.stream {
                do {
                    try await engine.processRealtimeAudioBuffer(audioBuffer.buffer)
                } catch is CancellationError {
                    return
                } catch {
                    AppTelemetry.signal(
                        "realtime_dictation_buffer_failed",
                        parameters: ["error": String(describing: type(of: error))]
                    )
                }
            }
        }

        try streamingRecorder.start(
            chunksDirectory: chunksDirectory,
            retainedAudioURL: audioURL,
            routeStage: "realtime dictation"
        )
        realtimeDictationRecorder = streamingRecorder
        realtimeDictationBufferPipe = pipe
        realtimeDictationChunksDirectory = chunksDirectory
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
        guard !isRecording, !isMeetingRecording, statusText != "Transcribing" else {
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
                    isActive: isKeyboardSessionArmed,
                    activeRequestID: nil,
                    phase: .failed,
                    message: message,
                    supportsBackgroundStart: isKeyboardSessionArmed
                )
            }
            return
        }
        activeRequest = request
        liveDictationTranscript = ""
        realtimeDictationCommittedText = ""
        clearKeyboardLiveTranscript()
        let kind: RecordingSessionKind = source == "keyboard" ? .keyboardDictation : .quickDictation
        var session = RecordingSession(
            requestID: request.id,
            kind: kind,
            keepsAudioRecording: MuesliPreferences.keepDictationAudioRecordingsEnabled
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
                if source == "keyboard", isKeyboardSessionArmed {
                    keyboardSessionKeeper.stop(deactivateSession: false)
                    keyboardSessionStatusText = "Recording"
                }
                if selectedTranscriptionModel.supportsRealtimeStreaming {
                    try await startRealtimeDictationRecorder(audioURL: audioURL, sessionID: session.id)
                } else {
                    try recorder.start(outputURL: audioURL)
                }
                refreshAudioInputRoute()
                activeSession = session
                isRecording = true
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
                        detail: source == "keyboard" ? "Keyboard voice note active" : "Recording voice note"
                    )
                }
            } catch {
                session.phase = .failed
                session.errorMessage = error.localizedDescription
                cleanupNonRetainedAudio(for: &session)
                try? store.saveSession(session)
                activeSession = nil
                activeRequest = nil
                stopRecordingTimer()
                statusText = error.localizedDescription
                clearKeyboardLiveTranscript()
                stopMetering()
                resumeKeyboardSessionKeeperIfNeeded()
                AppTelemetry.signal("dictation_failed", parameters: ["stage": "recording"])
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
        audioURL: URL
    ) {
        beginTranscriptionBackgroundTask()
        Task {
            defer { endTranscriptionBackgroundTask() }

            do {
                await engine.selectModel(selectedTranscriptionModel)
                saveKeyboardHandoff(
                    requestID: request.id,
                    phase: .transcribingStarted,
                    message: "Recovering transcription"
                )
                let text = postProcessTranscript(try await engine.transcribe(audioURL: audioURL))
                let savedTranscript = Transcript(
                    sessionID: session.id,
                    text: text,
                    engineIdentifier: engine.identifier
                )
                try store.saveTranscript(savedTranscript)

                var completedSession = session
                completedSession.phase = .completed
                completedSession.endedAt = completedSession.endedAt ?? .now
                completedSession.transcriptID = savedTranscript.id
                completedSession.engineIdentifier = engine.identifier
                completedSession.errorMessage = nil
                cleanupNonRetainedAudio(for: &completedSession)
                try store.saveSession(completedSession)
                exportRetainedAudioIfNeeded(for: completedSession)

                let result = DictationResult(
                    requestID: request.id,
                    sessionID: savedTranscript.sessionID,
                    text: text,
                    createdAt: completedSession.createdAt,
                    engineIdentifier: engine.identifier
                )
                try store.saveResult(result)
                scheduleICloudSyncAfterLocalChange(reason: "dictation_completed")
                saveKeyboardLiveTranscript(text: text, isFinal: true)
                saveKeyboardHandoff(requestID: request.id, phase: .resultReady, message: "Ready to insert")
                try store.clearPendingRequest()
                activeRequest = nil
                activeSession = nil
                isKeyboardHandoffActive = false
                statusText = "Ready"
                refreshHistory()
                saveKeyboardRuntimeStatus(
                    isActive: isKeyboardSessionArmed,
                    activeRequestID: nil,
                    phase: .idle,
                    message: isKeyboardSessionArmed ? "Keyboard session ready" : "Ready",
                    supportsBackgroundStart: isKeyboardSessionArmed
                )
                resumeKeyboardSessionKeeperIfNeeded()
                AppTelemetry.signal(
                    "keyboard_transcription_recovered",
                    parameters: [
                        "engine": engine.identifier,
                        "empty": text.isEmpty ? "true" : "false"
                    ]
                )
            } catch {
                var failedSession = session
                failedSession.phase = .failed
                failedSession.errorMessage = error.localizedDescription
                cleanupNonRetainedAudio(for: &failedSession)
                try? store.saveSession(failedSession)
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
                isKeyboardHandoffActive = false
                statusText = error.localizedDescription
                saveKeyboardRuntimeStatus(
                    isActive: isKeyboardSessionArmed,
                    activeRequestID: nil,
                    phase: .failed,
                    message: error.localizedDescription,
                    supportsBackgroundStart: isKeyboardSessionArmed
                )
                resumeKeyboardSessionKeeperIfNeeded()
                AppTelemetry.signal(
                    "keyboard_transcription_recovery_failed",
                    parameters: [
                        "engine": engine.identifier,
                        "error": String(describing: type(of: error))
                    ]
                )
            }
        }
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
            let message = "No active recording found. Start a new voice note."
            statusText = message
            try? store.saveStatus(.init(requestID: requestID, phase: .failed, message: message))
            saveKeyboardHandoff(requestID: requestID, phase: .failed, message: message)
            return
        }

        isRecording = false
        stopMetering()
        stopRecordingTimer()
        stopCommandPolling()
        statusText = "Transcribing"
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
            let startedFromKeyboard = isKeyboardHandoffActive

            do {
                let usesRealtimeStreaming = realtimeDictationRecorder != nil
                let audioURL: URL
                var text: String

                if usesRealtimeStreaming {
                    let stoppedAudio = realtimeDictationRecorder?.stop()
                    realtimeDictationRecorder = nil
                    realtimeDictationBufferPipe?.finish()
                    await realtimeDictationProcessingTask?.value
                    realtimeDictationProcessingTask = nil
                    realtimeDictationBufferPipe = nil
                    if let realtimeDictationChunksDirectory {
                        try? FileManager.default.removeItem(at: realtimeDictationChunksDirectory)
                    }
                    realtimeDictationChunksDirectory = nil
                    guard let retainedAudioURL = stoppedAudio?.retainedAudioURL else {
                        throw AudioRecorder.RecordingError.noRecording
                    }
                    audioURL = retainedAudioURL
                    if startedFromKeyboard {
                        saveKeyboardHandoff(
                            requestID: request.id,
                            phase: .transcribingStarted,
                            message: "Transcribing"
                        )
                    }
                    text = postProcessTranscript(try await engine.finishRealtimeSession())
                    if text.isEmpty {
                        text = postProcessTranscript(try await engine.transcribe(audioURL: audioURL))
                    }
                    liveDictationTranscript = text
                } else {
                    audioURL = try recorder.stop()
                    if startedFromKeyboard {
                        saveKeyboardHandoff(
                            requestID: request.id,
                            phase: .transcribingStarted,
                            message: "Transcribing"
                        )
                    }
                    text = postProcessTranscript(try await engine.transcribe(audioURL: audioURL))
                }
                if isKeyboardSessionArmed {
                    try? await keyboardSessionKeeper.start()
                    keyboardSessionStatusText = "Transcribing"
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
                    completedSession.phase = .completed
                    completedSession.audioFileName = completedSession.audioFileName ?? audioURL.lastPathComponent
                    completedSession.transcriptID = savedTranscript.id
                    completedSession.engineIdentifier = engine.identifier
                    completedSession.errorMessage = nil
                    cleanupNonRetainedAudio(for: &completedSession)
                    try store.saveSession(completedSession)
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
                    engineIdentifier: engine.identifier
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
                if startedFromKeyboard {
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
                liveDictationTranscript = ""
                realtimeDictationCommittedText = ""
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
                    cleanupNonRetainedAudio(for: &session)
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
                realtimeDictationRecorder?.cancel()
                realtimeDictationRecorder = nil
                realtimeDictationBufferPipe?.finish()
                realtimeDictationBufferPipe = nil
                realtimeDictationProcessingTask?.cancel()
                realtimeDictationProcessingTask = nil
                if let realtimeDictationChunksDirectory {
                    try? FileManager.default.removeItem(at: realtimeDictationChunksDirectory)
                }
                realtimeDictationChunksDirectory = nil
                liveDictationTranscript = ""
                realtimeDictationCommittedText = ""
                clearKeyboardLiveTranscript()
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
                if startedFromKeyboard {
                    saveKeyboardHandoff(
                        requestID: request.id,
                        phase: .failed,
                        message: error.localizedDescription
                    )
                }
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
        session.keepsAudioRecording = true

        Task {
            do {
                let audioURL = try store.newAudioFileURL(sessionID: session.id)
                let chunksDirectory = try meetingChunkDirectory(for: session.id)
                try? FileManager.default.removeItem(at: chunksDirectory)
                session.audioFileName = audioURL.lastPathComponent
                session.startedAt = .now
                try store.saveSession(session)
                try await recorder.requestPermission()

                let vadManager = try await VadManager()
                let vadController = StreamingVadController(vadManager: vadManager)
                let streamingRecorder = StreamingMeetingRecorder()
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

                try streamingRecorder.start(
                    chunksDirectory: chunksDirectory,
                    retainedAudioURL: audioURL,
                    routeStage: "meeting recording"
                )
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

    func stopCurrentMeetingRecording() {
        if isMeetingRecording || meetingRecorder != nil {
            stopMeetingRecording()
            return
        }

        guard var session = persistedRecordingMeetingSession else { return }
        session.endedAt = .now

        guard session.audioFileName != nil else {
            session.phase = .failed
            session.errorMessage = "Muesli found a recording session without an active recorder or saved audio."
            try? store.saveSession(session)
            meetingStatusText = session.errorMessage ?? "Recording recovery failed"
            refreshHistory()
            AppTelemetry.signal("meeting_recording_recovery_failed", parameters: [
                "reason": "missing_audio"
            ])
            return
        }

        session.phase = .transcriptionQueued
        session.errorMessage = nil
        try? store.saveSession(session)
        refreshHistory()
        AppTelemetry.signal("meeting_recording_recovered_for_transcription")
        transcribeSession(session)
    }

    func stopMeetingRecording(queueForTranscription _: Bool = false) {
        guard isMeetingRecording || meetingRecorder != nil else { return }
        guard var session = activeSession ?? persistedRecordingMeetingSession, session.kind == .meeting else { return }
        MuesliHaptics.dictationStop()
        isMeetingRecording = false
        isMeetingTranscribing = true
        stopMetering()
        meetingStatusText = "Finishing recording"

        do {
            meetingVadController?.stop()
            let stoppedAudio = meetingRecorder?.stop()
            meetingRecorder = nil
            meetingVadController = nil
            if let finalChunk = stoppedAudio?.finalChunk {
                scheduleMeetingChunkTranscription(finalChunk, sessionID: session.id)
            }
            session.audioFileName = session.audioFileName ?? stoppedAudio?.retainedAudioURL?.lastPathComponent
            session.keepsAudioRecording = true
            session.endedAt = .now
            session.phase = .transcribing
            try store.saveSession(session)
            activeSession = nil
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
            refreshHistory()
            AppTelemetry.signal("meeting_recording_failed", parameters: ["stage": "stop"])
        }
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
                AppTelemetry.signal("meeting_chunk_transcription_failed", parameters: [
                    "chunk": "\(chunk.index)",
                    "error": String(describing: type(of: error))
                ])
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

        let transcript = Transcript(
            sessionID: sessionID,
            text: text,
            engineIdentifier: engine.identifier,
            speakerTranscript: nil,
            summaryText: nil,
            diarizationState: .processing,
            summaryState: MuesliPreferences.meetingSummariesEnabled ? .processing : .notStarted
        )
        try? store.saveTranscript(transcript)
        if var session = try? store.recordingSession(id: sessionID) {
            session.transcriptID = transcript.id
            session.engineIdentifier = engine.identifier
            try? store.saveSession(session)
        }
        refreshHistory()
    }

    private func finalizeStreamingMeeting(_ session: RecordingSession) {
        beginTranscriptionBackgroundTask()
        Task {
            defer {
                endTranscriptionBackgroundTask()
                isMeetingTranscribing = false
            }

            var session = session
            do {
                meetingStatusText = "Transcribing"
                for task in meetingChunkTasks {
                    if let transcription = await task.value,
                       !meetingChunkTranscriptions.contains(where: { $0.chunk.index == transcription.chunk.index }) {
                        meetingChunkTranscriptions.append(transcription)
                    }
                }
                meetingChunkTasks.removeAll(keepingCapacity: false)

                let mergedTranscription = MeetingChunkTranscriptMerger.merge(meetingChunkTranscriptions)
                let text = postProcessTranscript(mergedTranscription.text)
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

                session.phase = .completed
                session.title = finalTranscript.resolvedTitle
                session.transcriptID = finalTranscript.transcript.id
                session.engineIdentifier = engine.identifier
                session.errorMessage = nil
                try store.saveSession(session)
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
            } catch {
                session.phase = .failed
                session.errorMessage = error.localizedDescription
                try? store.saveSession(session)
                cleanupMeetingChunks()
                meetingStatusText = error.localizedDescription
                refreshHistory()
                await liveActivityController.end(
                    phase: "Failed",
                    detail: "Transcription failed",
                    session: session
                )
                AppTelemetry.signal("meeting_transcription_failed", parameters: [
                    "engine": engine.identifier,
                    "error": String(describing: type(of: error)),
                    "chunked": "true"
                ])
            }
        }
    }

    func transcribeSession(_ session: RecordingSession) {
        guard !isRecording, !isMeetingRecording, !isMeetingTranscribing else { return }
        guard let audioFileName = session.audioFileName else { return }
        var session = session
        session.phase = .transcribing
        session.errorMessage = nil
        session.keepsAudioRecording = true
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
                session.phase = .completed
                session.title = finalTranscript.resolvedTitle
                session.transcriptID = finalTranscript.transcript.id
                session.engineIdentifier = engine.identifier
                session.errorMessage = nil
                try store.saveSession(session)
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
            meetingStatusText = "Diarizing"
            do {
                let diarizationSegments = try await engine.diarize(audioURL: audioURL)
                speakerTranscript = MeetingTranscriptFormatter.speakerTranscript(
                    transcription: detailedTranscription,
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
        return FinalizedMeetingTranscript(transcript: transcript, resolvedTitle: resolvedTitle)
    }

    private func meetingChunkDirectory(for sessionID: UUID) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-meeting-chunks", isDirectory: true)
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func cleanupMeetingChunks() {
        if let meetingChunksDirectory {
            try? FileManager.default.removeItem(at: meetingChunksDirectory)
        }
        meetingChunksDirectory = nil
        meetingChunkTasks.removeAll(keepingCapacity: false)
        meetingChunkTranscriptions.removeAll(keepingCapacity: false)
    }

    private func startMetering(update: @escaping @MainActor (Double) -> Void) {
        meteringTask?.cancel()
        meteringTask = Task { @MainActor [weak self] in
            var smoothedLevel = 0.0

            while !Task.isCancelled {
                guard let self else { return }
                let power = Double(self.realtimeDictationRecorder?.currentPower() ?? self.recorder.currentPower())
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

    private func cleanupNonRetainedAudio(for session: inout RecordingSession) {
        guard !session.keepsAudioRecording,
              let audioFileName = session.audioFileName
        else { return }

        try? store.deleteAudioFile(fileName: audioFileName)
        session.audioFileName = nil
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
                self.refreshKeyboardRuntimeHeartbeat()

                if let command = try? self.store.pendingCommand(), command.action == .start {
                    try? self.store.clearPendingCommand()
                    let pendingRequest = try? self.store.pendingRequest()
                    let request = pendingRequest?.id == command.requestID
                        ? pendingRequest!
                        : DictationRequest(id: command.requestID)

                    if self.refreshActiveKeyboardRequestIfNeeded(request) {
                        try? await Task.sleep(for: .milliseconds(500))
                        continue
                    }

                    guard !self.isRecording, !self.isMeetingRecording, self.statusText != "Transcribing" else {
                        self.saveKeyboardHandoff(
                            requestID: command.requestID,
                            phase: .failed,
                            message: "Muesli is busy"
                        )
                        try? self.store.saveStatus(.init(
                            requestID: command.requestID,
                            phase: .failed,
                            message: "Muesli is busy"
                        ))
                        try? await Task.sleep(for: .milliseconds(500))
                        continue
                    }

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
                        detail: "Keyboard voice note session active"
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
        stopRecordingTimer()
        stopCommandPolling()
        _ = try? recorder.stop()
        cleanupRealtimeDictationRecorder()
        if var session = activeSession {
            session.phase = .cancelled
            session.endedAt = .now
            cleanupNonRetainedAudio(for: &session)
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
        saveKeyboardHandoff(requestID: requestID, phase: .cancelled, message: "Cancelled")
        clearKeyboardLiveTranscript()
    }

    private func cleanupRealtimeDictationRecorder() {
        realtimeDictationRecorder?.cancel()
        realtimeDictationRecorder = nil
        realtimeDictationBufferPipe?.finish()
        realtimeDictationBufferPipe = nil
        realtimeDictationProcessingTask?.cancel()
        realtimeDictationProcessingTask = nil
        if let realtimeDictationChunksDirectory {
            try? FileManager.default.removeItem(at: realtimeDictationChunksDirectory)
        }
        realtimeDictationChunksDirectory = nil
        realtimeDictationCommittedText = ""
        liveDictationTranscript = ""
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
        AppTelemetry.signal(
            "model_prepare_failed",
            parameters: [
                "engine": model.engineIdentifier,
                "error": "background_download_failed"
            ]
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
