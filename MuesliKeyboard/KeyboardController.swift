import Foundation
import Observation

@MainActor
@Observable
final class KeyboardController {
    private let store = SharedStore()
    private var pollingTask: Task<Void, Never>?
    private var latestResultID: UUID?
    private var activeRequestID: UUID?
    private var insertedRequestIDs = Set<UUID>()

    var statusText = "Record in Muesli first"
    var hasLatestDictation = false
    var dictationPhase: DictationPhase = .idle
    var textInserter: (@MainActor (String) -> Void)?
    var appOpener: (@MainActor (URL) -> Bool)?

    var primaryButtonTitle: String {
        switch dictationPhase {
        case .requested:
            "Open Muesli"
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
        case .recording:
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
        case .recording:
            .recording
        case .transcribing, .requested:
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

    func primaryAction() {
        switch dictationPhase {
        case .recording:
            stopActiveDictation()
        case .requested:
            reopenActiveDictation()
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

            textInserter?(result.text)
            latestResultID = result.id
            hasLatestDictation = true
            statusText = "Inserted"
        } catch {
            statusText = "Enable Full Access"
        }
    }

    func startDictation() {
        let request = DictationRequest()
        activeRequestID = request.id
        insertedRequestIDs.remove(request.id)
        dictationPhase = .requested
        statusText = "Opening Muesli"

        do {
            try store.clearPendingCommand()
            try store.saveRequest(request)
            try store.saveStatus(.init(requestID: request.id, phase: .requested, message: "Opening Muesli"))
        } catch {
            statusText = "Enable Full Access"
            activeRequestID = nil
            dictationPhase = .idle
            return
        }

        if openMuesli(for: request) {
            statusText = "Swipe back after recording starts"
        } else {
            statusText = "Could not open Muesli"
        }
    }

    private func stopActiveDictation() {
        guard let activeRequestID else {
            dictationPhase = .idle
            statusText = hasLatestDictation ? "Latest ready" : "Ready"
            return
        }

        do {
            try store.saveCommand(.init(requestID: activeRequestID, action: .stop))
            try store.saveStatus(.init(requestID: activeRequestID, phase: .transcribing, message: "Stopping"))
            dictationPhase = .transcribing
            statusText = "Transcribing"
        } catch {
            statusText = "Enable Full Access"
        }
    }

    private func reopenActiveDictation() {
        guard let activeRequestID else {
            startDictation()
            return
        }

        let request = DictationRequest(id: activeRequestID)
        if openMuesli(for: request) {
            statusText = "Swipe back after recording starts"
        } else {
            statusText = "Could not open Muesli"
        }
    }

    func insertSpace() {
        textInserter?(" ")
    }

    func insertReturn() {
        textInserter?("\n")
    }

    func startPolling() {
        markKeyboardVisible()
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

    private func apply(status: DictationStatus) {
        guard let requestID = status.requestID else {
            if activeRequestID != nil {
                activeRequestID = nil
                dictationPhase = .idle
            }
            return
        }

        let resumablePhases: [DictationPhase] = [.requested, .recording, .transcribing, .finished]
        let isRecentStatus = Date().timeIntervalSince(status.updatedAt) < 120
        if activeRequestID == nil, isRecentStatus, resumablePhases.contains(status.phase) {
            activeRequestID = requestID
        }

        guard activeRequestID == requestID else { return }
        dictationPhase = status.phase

        switch status.phase {
        case .requested:
            statusText = "Open Muesli to record"
        case .recording:
            statusText = "Recording in Muesli"
        case .transcribing:
            statusText = status.message ?? "Transcribing"
        case .failed:
            activeRequestID = nil
            statusText = status.message ?? "Dictation failed"
        case .finished:
            break
        case .idle:
            activeRequestID = nil
            statusText = hasLatestDictation ? "Latest ready" : "Ready"
        }
    }

    private func insertCompletedResult(_ result: DictationResult) {
        guard !insertedRequestIDs.contains(result.requestID) else { return }
        textInserter?(result.text)
        insertedRequestIDs.insert(result.requestID)
        latestResultID = result.id
        hasLatestDictation = true
        activeRequestID = nil
        dictationPhase = .finished
        statusText = "Inserted"
        try? store.clearPendingRequest()
        try? store.clearPendingCommand()

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard let self, self.dictationPhase == .finished else { return }
            self.dictationPhase = .idle
            self.statusText = "Latest ready"
        }
    }

    private func openMuesli(for request: DictationRequest) -> Bool {
        var components = URLComponents()
        components.scheme = MuesliAppConstants.urlScheme
        components.host = MuesliAppConstants.dictateHost
        components.queryItems = [
            URLQueryItem(name: MuesliAppConstants.requestQueryItem, value: request.id.uuidString),
            URLQueryItem(name: MuesliAppConstants.actionQueryItem, value: MuesliAppConstants.startAction)
        ]

        guard let url = components.url else { return false }
        return appOpener?(url) ?? false
    }
}

enum ColorToken {
    case accent
    case recording
    case transcribing
}
