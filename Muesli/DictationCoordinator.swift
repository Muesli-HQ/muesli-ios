import AVFoundation
import Foundation
import Observation

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

    private var activeRequest: DictationRequest?
    var hasCompletedOnboarding = UserDefaults.standard.bool(forKey: onboardingCompletedKey)
    var userName = UserDefaults.standard.string(forKey: userNameKey) ?? ""
    var selectedUseCase = OnboardingUseCase(
        rawValue: UserDefaults.standard.string(forKey: useCaseKey) ?? ""
    ) ?? .keyboardDictation
    var modelPreparation = ModelPreparationState()
    var isOnboardingTestRecording = false
    var onboardingTestTranscript = ""
    var onboardingTestError: String?
    var isRecording = false
    var statusText = "Ready"
    var lastTranscript = ""

    func handleOpenURL(_ url: URL) {
        guard url.scheme == MuesliAppConstants.urlScheme,
              url.host == MuesliAppConstants.dictateHost,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let value = components.queryItems?.first(where: { $0.name == MuesliAppConstants.requestQueryItem })?.value,
              let requestID = UUID(uuidString: value)
        else { return }

        let request = DictationRequest(id: requestID)
        activeRequest = request
        startRecording(for: request, source: "keyboard")
    }

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording(for: DictationRequest(), source: "app")
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

        Task {
            do {
                try await recorder.requestPermission()
                try recorder.start()
                isOnboardingTestRecording = true
                AppTelemetry.signal("onboarding_test_started")
            } catch {
                onboardingTestError = error.localizedDescription
                AppTelemetry.signal("onboarding_test_failed", parameters: ["stage": "recording"])
            }
        }
    }

    func stopOnboardingTestDictation() {
        guard isOnboardingTestRecording else { return }
        isOnboardingTestRecording = false
        onboardingTestError = nil

        Task {
            do {
                let audioURL = try recorder.stop()
                let text = try await engine.transcribe(audioURL: audioURL)
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
        activeRequest = request

        Task {
            do {
                try await recorder.requestPermission()
                try recorder.start()
                isRecording = true
                statusText = "Recording"
                AppTelemetry.signal("dictation_started", parameters: ["source": source])
                try store.saveRequest(request)
                try store.saveStatus(.init(requestID: request.id, phase: .recording))
            } catch {
                statusText = error.localizedDescription
                AppTelemetry.signal("dictation_failed", parameters: ["stage": "recording"])
                try? store.saveStatus(.init(requestID: request.id, phase: .failed, message: error.localizedDescription))
            }
        }
    }

    private func stopRecording() {
        guard let request = activeRequest else { return }
        isRecording = false
        statusText = "Transcribing"

        Task {
            do {
                let audioURL = try recorder.stop()
                try store.saveStatus(.init(requestID: request.id, phase: .transcribing))
                let text = try await engine.transcribe(audioURL: audioURL)
                let result = DictationResult(requestID: request.id, text: text, engineIdentifier: engine.identifier)
                try store.saveResult(result)
                try store.clearPendingRequest()
                lastTranscript = text
                statusText = "Ready"
                AppTelemetry.signal(
                    "dictation_completed",
                    parameters: [
                        "engine": engine.identifier,
                        "empty": text.isEmpty ? "true" : "false"
                    ]
                )
            } catch {
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
}
