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
    private var modelPreparationTask: Task<Void, Never>?
    private var meteringTask: Task<Void, Never>?
    private var commandPollingTask: Task<Void, Never>?
    private var transcriptionBackgroundTask: UIBackgroundTaskIdentifier = .invalid

    private var activeRequest: DictationRequest?
    var isKeyboardHandoffActive = false
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
    var lastTranscript = ""
    var dictationHistory: [DictationResult] = []
    var clipboardStatusText: String?

    init() {
        refreshHistory()
    }

    func handleOpenURL(_ url: URL) {
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
        startRecording(for: request, source: "keyboard")
    }

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else if statusText != "Transcribing" {
            startRecording(for: DictationRequest(), source: "app")
        }
    }

    func refreshHistory() {
        do {
            dictationHistory = try store.resultsHistory()
            lastTranscript = dictationHistory.first?.text ?? lastTranscript
        } catch {
            statusText = error.localizedDescription
        }
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

    func startOnboardingTestDictation() {
        guard !isOnboardingTestRecording else { return }
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
        isOnboardingTestRecording = false
        isOnboardingTestTranscribing = true
        stopMetering()
        onboardingTestError = nil

        Task {
            do {
                let audioURL = try recorder.stop()
                let text = try await engine.transcribe(audioURL: audioURL)
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
        guard !isRecording, statusText != "Transcribing" else { return }
        activeRequest = request

        Task {
            do {
                try await recorder.requestPermission()
                try recorder.start()
                isRecording = true
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
            } catch {
                statusText = error.localizedDescription
                stopMetering()
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
        if let activeRequest, activeRequest.id == requestID {
            request = activeRequest
        } else if let pendingRequest = try? store.pendingRequest(), pendingRequest.id == requestID {
            request = pendingRequest
            activeRequest = pendingRequest
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

        beginTranscriptionBackgroundTask()
        Task {
            defer { endTranscriptionBackgroundTask() }

            do {
                let audioURL = try recorder.stop()
                let text = try await engine.transcribe(audioURL: audioURL)
                let result = DictationResult(requestID: request.id, text: text, engineIdentifier: engine.identifier)
                try store.saveResult(result)
                try store.clearPendingRequest()
                refreshHistory()
                lastTranscript = text
                activeRequest = nil
                isKeyboardHandoffActive = false
                statusText = "Ready"
                AppTelemetry.signal(
                    "dictation_completed",
                    parameters: [
                        "engine": engine.identifier,
                        "empty": text.isEmpty ? "true" : "false"
                    ]
                )
            } catch {
                activeRequest = nil
                isKeyboardHandoffActive = false
                statusText = error.localizedDescription
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
        activeRequest = nil
        isKeyboardHandoffActive = false
        statusText = "Ready"
        try? store.clearPendingCommand()
        try? store.clearPendingRequest()
        try? store.saveStatus(.idle)
    }
}
