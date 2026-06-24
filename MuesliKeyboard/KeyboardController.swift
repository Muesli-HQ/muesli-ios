import Foundation
import Observation

@MainActor
@Observable
final class KeyboardController {
    private static let staleRecordingInterval: TimeInterval = 45
    private static let staleStoppingInterval: TimeInterval = 10
    private static let staleTranscribingInterval: TimeInterval = 120

    private let store = SharedStore()
    private let handoffRecoveryPolicy = KeyboardHandoffRecoveryPolicy.keyboardDefaults
    private var pollingTask: Task<Void, Never>?
    private var latestResultID: UUID?
    private var preparedRequest: DictationRequest?
    private var activeRequestID: UUID?
    private var recoveryRequestID: UUID?
    private var latestHandoffState: KeyboardHandoffState?
    private var latestRuntimeStatus: KeyboardRuntimeStatus?
    private var insertedRequestIDs = Set<UUID>()

    var statusText = "Record a voice note first"
    var hasLatestDictation = false
    var dictationPhase: DictationPhase = .idle
    var launchURL: URL?
    var textInserter: (@MainActor (String) -> Void)?
    var textDeleter: (@MainActor (Int) -> Void)?
    var liveTranscript = ""
    private var lastInsertedCharacterCount = 0
    private var canUseRuntimeStart = false

    var showsLiveTranscript: Bool {
        activeRequestID != nil
            && !liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && [.recording, .transcribing].contains(dictationPhase)
    }

    var primaryButtonTitle: String {
        if recoveryRequestID != nil {
            return "Open Muesli"
        }

        if latestHandoffState?.phase == .stopRequested {
            return "Waiting for Muesli"
        }

        return switch dictationPhase {
        case .requested:
            activeRequestID == nil ? "Open Muesli" : "Stop"
        case .recording:
            "Stop"
        case .transcribing:
            "Transcribing"
        case .finished:
            "Inserted"
        default:
            "Record"
        }
    }

    var primaryButtonIcon: String {
        if recoveryRequestID != nil {
            return "arrow.up.forward.app"
        }

        if latestHandoffState?.phase == .stopRequested {
            return "hourglass"
        }

        return switch dictationPhase {
        case .requested, .recording:
            "stop.fill"
        case .transcribing:
            "waveform"
        case .finished:
            "checkmark"
        default:
            "mic.fill"
        }
    }

    var primaryButtonColor: ColorToken {
        switch dictationPhase {
        case .requested, .recording:
            .recording
        case .transcribing:
            .transcribing
        default:
            .accent
        }
    }

    var isPrimaryButtonDisabled: Bool {
        recoveryRequestID == nil && (
            dictationPhase == .transcribing
            || dictationPhase == .finished
            || latestHandoffState?.phase == .stopRequested
        )
    }

    var canInsertLatest: Bool {
        hasLatestDictation && activeRequestID == nil
    }

    var isRecoveryRequested: Bool {
        recoveryRequestID != nil
    }

    var opensMuesliFromPrimaryButton: Bool {
        recoveryRequestID != nil
            || !canUseRuntimeStart
            && (dictationPhase == .idle || dictationPhase == .failed || (dictationPhase == .requested && activeRequestID == nil))
    }

    func primaryLaunchAction() {
        if recoveryRequestID != nil {
            statusText = "Opening Muesli"
            return
        }

        startDictation()
    }

    func primaryAction() {
        switch dictationPhase {
        case .requested, .recording:
            stopActiveDictation()
        case .transcribing, .finished:
            break
        default:
            startDictation()
        }
    }

    func insertLatestDictation() {
        do {
            guard let result = try store.resultsHistory().first else {
                latestResultID = nil
                hasLatestDictation = false
                statusText = "Record a voice note first"
                return
            }

            insertText(result.text)
            latestResultID = result.id
            hasLatestDictation = true
            statusText = "Inserted"
        } catch {
            statusText = "Enable Full Access"
        }
    }

    func prepareLaunchRequestIfNeeded() {
        guard preparedRequest == nil, activeRequestID == nil else { return }
        let request = DictationRequest()
        preparedRequest = request
        launchURL = makeLaunchURL(for: request)

        do {
            try store.clearPendingCommand()
            try store.saveRequest(request)
        } catch {
            statusText = "Enable Full Access"
        }
    }

    func startDictation() {
        MuesliHaptics.dictationStart()
        let request = preparedRequest ?? DictationRequest()
        preparedRequest = nil
        recoveryRequestID = nil
        launchURL = makeLaunchURL(for: request)
        activeRequestID = request.id
        liveTranscript = ""
        insertedRequestIDs.remove(request.id)
        dictationPhase = .recording
        statusText = "Opening Muesli"

        do {
            try store.clearPendingCommand()
            try store.clearKeyboardLiveTranscript()
            try store.saveRequest(request)
            try store.saveKeyboardHandoffState(.init(
                requestID: request.id,
                phase: .startRequested,
                message: canUseRuntimeStart ? "Starting" : "Opening Muesli"
            ))
            if canUseRuntimeStart {
                try store.saveCommand(.init(requestID: request.id, action: .start))
                try store.saveStatus(.init(requestID: request.id, phase: .requested, message: "Starting"))
            } else {
                try store.saveStatus(.init(requestID: request.id, phase: .requested, message: "Opening Muesli"))
            }
        } catch {
            statusText = "Enable Full Access"
            activeRequestID = nil
            dictationPhase = .idle
            return
        }

        statusText = canUseRuntimeStart ? "Starting" : "Recording in Muesli"
    }

    private func stopActiveDictation() {
        guard let activeRequestID else {
            dictationPhase = .idle
            statusText = hasLatestDictation ? "Latest ready" : "Ready"
            prepareLaunchRequestIfNeeded()
            return
        }

        MuesliHaptics.dictationStop()
        do {
            try store.saveCommand(.init(requestID: activeRequestID, action: .stop))
            try store.saveKeyboardHandoffState(.init(
                requestID: activeRequestID,
                phase: .stopRequested,
                message: "Stopping"
            ))
            try store.saveStatus(.init(requestID: activeRequestID, phase: .recording, message: "Stopping"))
            dictationPhase = .recording
            statusText = "Stopping"
        } catch {
            statusText = "Enable Full Access"
        }
    }

    func insertSpace() {
        insertText(" ")
    }

    func insertReturn() {
        insertText("\n")
    }

    func clearInsertedText() {
        let deleteCount = max(lastInsertedCharacterCount, 1)
        textDeleter?(deleteCount)
        lastInsertedCharacterCount = 0
        statusText = deleteCount > 1 ? "Cleared" : "Deleted"
    }

    func startPolling() {
        markKeyboardVisible()
        refreshLatestDictation()
        prepareLaunchRequestIfNeeded()
        pollingTask?.cancel()
        pollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.refreshLatestDictation()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func markKeyboardVisible() {
        do {
            try store.saveKeyboardExtensionStatus(.init(lastSeenAt: .now, hasOpenAccess: true))
        } catch {
            statusText = "Enable Full Access"
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func refreshLatestDictation() {
        do {
            let runtimeStatus = try store.keyboardRuntimeStatus()
            latestRuntimeStatus = runtimeStatus
            apply(runtimeStatus: runtimeStatus)

            let handoffState = try store.keyboardHandoffState()
            latestHandoffState = handoffState
            apply(handoffState: handoffState)
            apply(liveTranscript: try store.keyboardLiveTranscript())

            guard let result = try store.resultsHistory().first else {
                latestResultID = nil
                hasLatestDictation = false
                if activeRequestID == nil {
                    statusText = "Ready"
                }
                return
            }

            hasLatestDictation = true
            if let activeRequestID, let activeResult = try store.result(for: activeRequestID) {
                insertCompletedResult(activeResult)
                return
            }

            if handoffState.requestID == nil || handoffState.phase == .idle {
                let status = try store.status()
                apply(status: status)
            }

            if latestResultID != result.id {
                latestResultID = result.id
                if activeRequestID == nil {
                    statusText = "Latest ready"
                }
            } else if activeRequestID == nil && statusText != "Inserted" {
                statusText = "Latest ready"
            }
        } catch {
            statusText = "Waiting for Full Access"
        }
    }

    private func apply(handoffState: KeyboardHandoffState) {
        guard let requestID = handoffState.requestID else { return }

        let resumablePhases: [KeyboardHandoffPhase] = [
            .startRequested,
            .startAcknowledged,
            .recordingStarted,
            .stopRequested,
            .stopAcknowledged,
            .audioSaved,
            .transcribingStarted,
            .resultReady,
            .recoveryRequested
        ]
        if activeRequestID == nil, resumablePhases.contains(handoffState.phase) {
            activeRequestID = requestID
        }

        guard activeRequestID == requestID else { return }

        if markHandoffForRecoveryIfStale(handoffState) {
            return
        }

        recoveryRequestID = handoffState.phase == .recoveryRequested ? requestID : nil

        switch handoffState.phase {
        case .idle:
            dictationPhase = .idle
            activeRequestID = nil
            liveTranscript = ""
            statusText = hasLatestDictation ? "Latest ready" : "Ready"
        case .startRequested:
            dictationPhase = .requested
            statusText = handoffState.message ?? "Starting"
        case .startAcknowledged:
            dictationPhase = .requested
            statusText = handoffState.message ?? "Starting"
        case .recordingStarted:
            dictationPhase = .recording
            statusText = handoffState.message ?? "Listening"
        case .stopRequested:
            dictationPhase = .recording
            statusText = handoffState.message ?? "Stopping"
        case .stopAcknowledged:
            dictationPhase = .transcribing
            statusText = handoffState.message ?? "Finalizing audio"
        case .audioSaved:
            dictationPhase = .transcribing
            statusText = handoffState.message ?? "Audio saved"
        case .transcribingStarted:
            dictationPhase = .transcribing
            statusText = handoffState.message ?? "Transcribing"
        case .resultReady:
            dictationPhase = .transcribing
            statusText = handoffState.message ?? "Inserting"
        case .inserted:
            dictationPhase = .finished
            activeRequestID = nil
            liveTranscript = ""
            statusText = "Inserted"
        case .recoveryRequested:
            dictationPhase = .failed
            recoveryRequestID = requestID
            launchURL = makeLaunchURL(for: requestID, action: MuesliAppConstants.startAction)
            statusText = handoffState.message ?? "Open Muesli to finish"
        case .failed:
            dictationPhase = .failed
            activeRequestID = nil
            recoveryRequestID = nil
            liveTranscript = ""
            statusText = handoffState.message ?? "Voice note failed"
        case .cancelled:
            dictationPhase = .idle
            activeRequestID = nil
            recoveryRequestID = nil
            liveTranscript = ""
            statusText = hasLatestDictation ? "Latest ready" : "Ready"
        }
    }

    private func apply(runtimeStatus: KeyboardRuntimeStatus?) {
        let isRecent = runtimeStatus.map { Date().timeIntervalSince($0.updatedAt) < 8 } ?? false
        canUseRuntimeStart = runtimeStatus?.isActive == true
            && isRecent
            && runtimeStatus?.supportsBackgroundStart == true

        guard activeRequestID == nil, canUseRuntimeStart else { return }
        activeRequestID = runtimeStatus?.activeRequestID
        if runtimeStatus?.phase == .idle {
            statusText = runtimeStatus?.message ?? "Session ready"
        }
    }

    private func apply(status: DictationStatus) {
        guard let requestID = status.requestID else {
            if activeRequestID != nil {
                activeRequestID = nil
                dictationPhase = .idle
                liveTranscript = ""
            }
            return
        }

        if activeRequestID == nil, preparedRequest?.id == requestID, status.phase == .requested {
            return
        }

        let resumablePhases: [DictationPhase] = [.requested, .recording, .transcribing, .finished]
        let isRecentStatus = Date().timeIntervalSince(status.updatedAt) < 120
        if activeRequestID == nil, isRecentStatus, resumablePhases.contains(status.phase) {
            activeRequestID = requestID
        }

        guard activeRequestID == requestID else { return }

        if markForRecoveryIfStale(status, requestID: requestID) {
            return
        }

        switch status.phase {
        case .requested:
            recoveryRequestID = nil
            if activeRequestID == nil {
                dictationPhase = .requested
                statusText = "Open Muesli to record"
            } else {
                dictationPhase = .recording
                statusText = "Recording in Muesli"
            }
        case .recording:
            recoveryRequestID = nil
            dictationPhase = .recording
            statusText = "Recording in Muesli"
        case .transcribing:
            recoveryRequestID = nil
            dictationPhase = .transcribing
            statusText = status.message ?? "Transcribing"
        case .failed:
            recoveryRequestID = nil
            dictationPhase = .failed
            activeRequestID = nil
            liveTranscript = ""
            statusText = status.message ?? "Voice note failed"
        case .finished:
            recoveryRequestID = nil
            dictationPhase = .finished
            break
        case .idle:
            recoveryRequestID = nil
            dictationPhase = .idle
            activeRequestID = nil
            liveTranscript = ""
            statusText = hasLatestDictation ? "Latest ready" : "Ready"
        }
    }

    private func apply(liveTranscript transcript: KeyboardLiveTranscript?) {
        guard let activeRequestID else {
            liveTranscript = ""
            return
        }

        guard let transcript,
              transcript.requestID == activeRequestID,
              Date().timeIntervalSince(transcript.updatedAt) < 120
        else {
            return
        }

        liveTranscript = transcript.text
    }

    private func markForRecoveryIfStale(_ status: DictationStatus, requestID: UUID) -> Bool {
        if let latestRuntimeStatus,
           latestRuntimeStatus.activeRequestID == requestID,
           Date().timeIntervalSince(latestRuntimeStatus.updatedAt) < 8,
           [.recording, .transcribing].contains(latestRuntimeStatus.phase)
        {
            recoveryRequestID = nil
            dictationPhase = latestRuntimeStatus.phase
            statusText = latestRuntimeStatus.message ?? status.message ?? latestRuntimeStatus.phase.rawValue.capitalized
            return true
        }

        let age = Date().timeIntervalSince(status.updatedAt)
        let threshold: TimeInterval
        let message: String

        switch status.phase {
        case .requested, .recording:
            threshold = Self.staleRecordingInterval
            message = "Open Muesli to continue"
        case .transcribing:
            threshold = status.message == "Stopping" ? Self.staleStoppingInterval : Self.staleTranscribingInterval
            message = "Open Muesli to finish"
        default:
            return false
        }

        guard age > threshold else { return false }

        recoveryRequestID = requestID
        launchURL = makeLaunchURL(for: requestID, action: MuesliAppConstants.startAction)
        dictationPhase = .failed
        activeRequestID = nil
        liveTranscript = ""
        statusText = message
        return true
    }

    private func markHandoffForRecoveryIfStale(_ state: KeyboardHandoffState) -> Bool {
        guard let requestID = state.requestID else { return false }

        let action = handoffRecoveryPolicy.action(
            for: state,
            latestRuntimeStatus: latestRuntimeStatus,
            canUseRuntimeStart: canUseRuntimeStart
        )

        switch action {
        case .none:
            return false

        case let .retry(retryAction, retrying):
            try? store.saveCommand(.init(requestID: requestID, action: retryAction))
            try? store.saveKeyboardHandoffState(retrying)
            latestHandoffState = retrying
            dictationPhase = retrying.phase.dictationPhase
            statusText = retrying.message ?? "Retrying"
            return true

        case let .recover(recovery):
            try? store.saveKeyboardHandoffState(recovery)
            latestHandoffState = recovery
            recoveryRequestID = requestID
            launchURL = makeLaunchURL(for: requestID, action: MuesliAppConstants.startAction)
            dictationPhase = .failed
            activeRequestID = nil
            liveTranscript = ""
            statusText = recovery.message ?? "Open Muesli to finish"
            return true
        }
    }

    private func insertCompletedResult(_ result: DictationResult) {
        guard !insertedRequestIDs.contains(result.requestID) else { return }
        insertText(result.text)
        insertedRequestIDs.insert(result.requestID)
        latestResultID = result.id
        hasLatestDictation = true
        activeRequestID = nil
        liveTranscript = ""
        preparedRequest = nil
        recoveryRequestID = nil
        launchURL = nil
        dictationPhase = .finished
        statusText = "Inserted"
        try? store.clearPendingRequest()
        try? store.clearPendingCommand()
        try? store.clearKeyboardLiveTranscript()
        try? store.saveKeyboardHandoffState(.init(
            requestID: result.requestID,
            phase: .inserted,
            message: "Inserted"
        ))
        try? store.saveStatus(.idle)
        prepareLaunchRequestIfNeeded()

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard let self, self.dictationPhase == .finished else { return }
            self.dictationPhase = .idle
            self.statusText = "Latest ready"
        }
    }

    private func makeLaunchURL(for request: DictationRequest) -> URL? {
        makeLaunchURL(for: request.id, action: MuesliAppConstants.startAction)
    }

    private func makeLaunchURL(for requestID: UUID, action: String) -> URL? {
        var components = URLComponents()
        components.scheme = MuesliAppConstants.urlScheme
        components.host = MuesliAppConstants.dictateHost
        components.queryItems = [
            URLQueryItem(name: MuesliAppConstants.requestQueryItem, value: requestID.uuidString),
            URLQueryItem(name: MuesliAppConstants.actionQueryItem, value: action)
        ]

        return components.url
    }

    private func insertText(_ text: String) {
        textInserter?(text)
        lastInsertedCharacterCount = text.count
    }
}

enum ColorToken {
    case accent
    case recording
    case transcribing
}
