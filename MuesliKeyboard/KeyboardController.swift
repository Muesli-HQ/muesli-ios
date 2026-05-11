import Foundation
import Observation

@MainActor
@Observable
final class KeyboardController {
    private let store = SharedStore()
    private var pollingTask: Task<Void, Never>?
    private var latestResultID: UUID?
    private var preparedRequest: DictationRequest?
    private var activeRequestID: UUID?
    private var insertedRequestIDs = Set<UUID>()

    var statusText = "Record in Muesli first"
    var hasLatestDictation = false
    var dictationPhase: DictationPhase = .idle
    var launchURL: URL?
    var textInserter: (@MainActor (String) -> Void)?
    var textDeleter: (@MainActor (Int) -> Void)?
    private var lastInsertedCharacterCount = 0
    private var canUseRuntimeStart = false

    var primaryButtonTitle: String {
        switch dictationPhase {
        case .requested:
            activeRequestID == nil ? "Open Muesli" : "Stop Dictation"
        case .recording:
            "Stop Dictation"
        case .transcribing:
            "Transcribing"
        case .finished:
            "Inserted"
        default:
            "Start Dictation"
        }
    }

    var primaryButtonIcon: String {
        switch dictationPhase {
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
        dictationPhase == .transcribing || dictationPhase == .finished
    }

    var canInsertLatest: Bool {
        hasLatestDictation && activeRequestID == nil
    }

    var opensMuesliFromPrimaryButton: Bool {
        !canUseRuntimeStart
            && (dictationPhase == .idle || dictationPhase == .failed || (dictationPhase == .requested && activeRequestID == nil))
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
                statusText = "Record in Muesli first"
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
        launchURL = makeLaunchURL(for: request)
        activeRequestID = request.id
        insertedRequestIDs.remove(request.id)
        dictationPhase = .recording
        statusText = "Opening Muesli"

        do {
            try store.clearPendingCommand()
            try store.saveRequest(request)
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
            try store.saveStatus(.init(requestID: activeRequestID, phase: .transcribing, message: "Stopping"))
            dictationPhase = .transcribing
            statusText = "Transcribing"
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
            apply(runtimeStatus: try store.keyboardRuntimeStatus())
            let status = try store.status()
            apply(status: status)

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

    private func apply(runtimeStatus: KeyboardRuntimeStatus?) {
        let isRecent = runtimeStatus.map { Date().timeIntervalSince($0.updatedAt) < 8 } ?? false
        canUseRuntimeStart = runtimeStatus?.isActive == true && isRecent

        guard activeRequestID == nil, canUseRuntimeStart else { return }
        if runtimeStatus?.phase == .idle, statusText == "Ready" || statusText == "Record in Muesli first" {
            statusText = "Runtime ready"
        }
    }

    private func apply(status: DictationStatus) {
        guard let requestID = status.requestID else {
            if activeRequestID != nil {
                activeRequestID = nil
                dictationPhase = .idle
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

        switch status.phase {
        case .requested:
            if activeRequestID == nil {
                dictationPhase = .requested
                statusText = "Open Muesli to record"
            } else {
                dictationPhase = .recording
                statusText = "Recording in Muesli"
            }
        case .recording:
            dictationPhase = .recording
            statusText = "Recording in Muesli"
        case .transcribing:
            dictationPhase = .transcribing
            statusText = status.message ?? "Transcribing"
        case .failed:
            dictationPhase = .failed
            activeRequestID = nil
            statusText = status.message ?? "Dictation failed"
        case .finished:
            dictationPhase = .finished
            break
        case .idle:
            dictationPhase = .idle
            activeRequestID = nil
            statusText = hasLatestDictation ? "Latest ready" : "Ready"
        }
    }

    private func insertCompletedResult(_ result: DictationResult) {
        guard !insertedRequestIDs.contains(result.requestID) else { return }
        insertText(result.text)
        insertedRequestIDs.insert(result.requestID)
        latestResultID = result.id
        hasLatestDictation = true
        activeRequestID = nil
        preparedRequest = nil
        launchURL = nil
        dictationPhase = .finished
        statusText = "Inserted"
        try? store.clearPendingRequest()
        try? store.clearPendingCommand()
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
        var components = URLComponents()
        components.scheme = MuesliAppConstants.urlScheme
        components.host = MuesliAppConstants.dictateHost
        components.queryItems = [
            URLQueryItem(name: MuesliAppConstants.requestQueryItem, value: request.id.uuidString),
            URLQueryItem(name: MuesliAppConstants.actionQueryItem, value: MuesliAppConstants.startAction)
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
