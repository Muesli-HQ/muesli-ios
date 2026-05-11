import Foundation
import Observation

@MainActor
@Observable
final class KeyboardController {
    private let store = SharedStore()
    private var pollingTask: Task<Void, Never>?
    private var activeRequestID: UUID?
    private var hasStopBeenRequested = false

    var statusText = "Tap to dictate"
    var isWaitingForResult = false
    var currentPhase: DictationPhase = .idle
    var textInserter: (@MainActor (String) -> Void)?
    var appOpener: (@MainActor (URL) -> Void)?

    var primaryButtonTitle: String {
        if hasStopBeenRequested {
            return currentPhase == .transcribing ? "Transcribing..." : "Stopping..."
        }
        if currentPhase == .recording || currentPhase == .requested {
            return "Stop Dictation"
        }
        if currentPhase == .transcribing {
            return "Transcribing..."
        }
        return isWaitingForResult ? "Waiting..." : "Start Dictation"
    }

    var primaryButtonIcon: String {
        if hasStopBeenRequested {
            return "waveform"
        }
        if currentPhase == .recording || currentPhase == .requested {
            return "stop.fill"
        }
        if currentPhase == .transcribing {
            return "waveform"
        }
        return "mic.fill"
    }

    var primaryButtonColor: ColorToken {
        if hasStopBeenRequested {
            return .transcribing
        }
        if currentPhase == .recording || currentPhase == .requested {
            return .recording
        }
        if currentPhase == .transcribing || isWaitingForResult {
            return .transcribing
        }
        return .accent
    }

    var isPrimaryButtonDisabled: Bool {
        if hasStopBeenRequested {
            return true
        }
        return isWaitingForResult && currentPhase != .recording && currentPhase != .requested
    }

    func toggleDictation() {
        guard !hasStopBeenRequested else { return }

        if currentPhase == .recording || currentPhase == .requested {
            stopDictation()
        } else {
            beginDictation()
        }
    }

    private func beginDictation() {
        guard !isWaitingForResult else { return }

        let request = DictationRequest()
        activeRequestID = request.id
        isWaitingForResult = true
        hasStopBeenRequested = false
        currentPhase = .requested
        statusText = "Opening Muesli"

        do {
            try store.saveRequest(request)
            appOpener?(dictationURL(for: request, action: MuesliAppConstants.startAction))
            startPolling()
        } catch {
            isWaitingForResult = false
            hasStopBeenRequested = false
            currentPhase = .failed
            statusText = "Enable Full Access"
        }
    }

    private func stopDictation() {
        guard let activeRequestID else { return }
        hasStopBeenRequested = true
        currentPhase = .transcribing
        statusText = "Stopping"
        try? store.saveStatus(.init(requestID: activeRequestID, phase: .transcribing, message: "Stopping"))
        appOpener?(dictationURL(requestID: activeRequestID, action: MuesliAppConstants.stopAction))
    }

    func insertSpace() {
        textInserter?(" ")
    }

    func insertReturn() {
        textInserter?("\n")
    }

    func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.pollOnce()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func pollOnce() {
        guard let activeRequestID else {
            if let status = try? store.status(), status.phase != .idle {
                statusText = status.message ?? label(for: status.phase)
            }
            return
        }

        do {
            if let result = try store.result(for: activeRequestID) {
                textInserter?(result.text)
                try store.clearResult(for: activeRequestID)
                self.activeRequestID = nil
                isWaitingForResult = false
                hasStopBeenRequested = false
                currentPhase = .idle
                statusText = "Inserted"
                return
            }

            let status = try store.status()
            if status.requestID == activeRequestID {
                if hasStopBeenRequested && (status.phase == .requested || status.phase == .recording) {
                    statusText = "Stopping"
                    return
                }

                currentPhase = status.phase
                if status.phase == .failed {
                    self.activeRequestID = nil
                    isWaitingForResult = false
                    hasStopBeenRequested = false
                }
            }
            statusText = status.message ?? label(for: status.phase)
        } catch {
            statusText = "Waiting for Full Access"
        }
    }

    private func dictationURL(for request: DictationRequest, action: String) -> URL {
        dictationURL(requestID: request.id, action: action)
    }

    private func dictationURL(requestID: UUID, action: String) -> URL {
        var components = URLComponents()
        components.scheme = MuesliAppConstants.urlScheme
        components.host = MuesliAppConstants.dictateHost
        components.queryItems = [
            URLQueryItem(name: MuesliAppConstants.requestQueryItem, value: requestID.uuidString),
            URLQueryItem(name: MuesliAppConstants.actionQueryItem, value: action)
        ]
        return components.url!
    }

    private func label(for phase: DictationPhase) -> String {
        switch phase {
        case .idle:
            "Tap to dictate"
        case .requested:
            "Starting"
        case .recording:
            "Recording in Muesli"
        case .transcribing:
            "Transcribing"
        case .finished:
            "Ready"
        case .failed:
            "Failed"
        }
    }
}

enum ColorToken {
    case accent
    case recording
    case transcribing
}
