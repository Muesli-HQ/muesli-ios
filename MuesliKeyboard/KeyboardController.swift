import Foundation
import Observation

@MainActor
@Observable
final class KeyboardController {
    private static let startHandoffTimeout: TimeInterval = 8
    private static let stopHandoffTimeout: TimeInterval = 8
    private static let transcriptionTimeout: TimeInterval = 90

    private let store = SharedStore()
    private var pollingTask: Task<Void, Never>?
    private var activeRequestID: UUID?
    private var requestStartedAt: Date?
    private var hasStopBeenRequested = false
    private var stopRequestedAt: Date?

    var statusText = "Tap to dictate"
    var isWaitingForResult = false
    var currentPhase: DictationPhase = .idle
    var textInserter: (@MainActor (String) -> Void)?
    var appOpener: (@MainActor (URL, @escaping @MainActor (Bool) -> Void) -> Void)?

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
        requestStartedAt = .now
        isWaitingForResult = true
        hasStopBeenRequested = false
        currentPhase = .requested
        statusText = "Opening Muesli"

        do {
            guard let appOpener else {
                failActiveRequest(message: "Could not open Muesli")
                return
            }

            try store.saveRequest(request)
            appOpener(dictationURL(for: request, action: MuesliAppConstants.startAction)) { [weak self] opened in
                guard let self else { return }
                if !opened {
                    self.failActiveRequest(message: "Could not open Muesli")
                }
            }
            startPolling()
        } catch {
            activeRequestID = nil
            requestStartedAt = nil
            isWaitingForResult = false
            hasStopBeenRequested = false
            currentPhase = .failed
            statusText = "Enable Full Access"
        }
    }

    private func stopDictation() {
        guard let activeRequestID else { return }
        hasStopBeenRequested = true
        stopRequestedAt = .now
        currentPhase = .recording
        statusText = "Stopping"
        appOpener?(dictationURL(requestID: activeRequestID, action: MuesliAppConstants.stopAction)) { [weak self] opened in
            guard let self else { return }
            if !opened {
                self.failActiveRequest(message: "Could not open Muesli")
            }
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
                self?.pollOnce()
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

    private func pollOnce() {
        guard let activeRequestID else {
            if currentPhase != .failed {
                currentPhase = .idle
                statusText = "Tap to dictate"
            }
            return
        }

        do {
            if let result = try store.result(for: activeRequestID) {
                textInserter?(result.text)
                try store.clearResult(for: activeRequestID)
                self.activeRequestID = nil
                requestStartedAt = nil
                isWaitingForResult = false
                hasStopBeenRequested = false
                stopRequestedAt = nil
                currentPhase = .idle
                statusText = "Inserted"
                return
            }

            let status = try store.status()
            if status.requestID == activeRequestID {
                if hasStartHandoffTimedOut(status: status) {
                    failActiveRequest(message: "Muesli did not start")
                    return
                }

                if hasStopHandoffTimedOut(status: status) {
                    failActiveRequest(message: "Muesli did not receive stop")
                    return
                }

                if hasTranscriptionTimedOut(status: status) {
                    failActiveRequest(message: "Transcription timed out")
                    return
                }

                if hasStopBeenRequested && (status.phase == .requested || status.phase == .recording) {
                    statusText = "Stopping"
                    return
                }

                currentPhase = status.phase
                if status.phase == .failed {
                    self.activeRequestID = nil
                    requestStartedAt = nil
                    isWaitingForResult = false
                    hasStopBeenRequested = false
                    stopRequestedAt = nil
                }
            }
            statusText = status.message ?? label(for: status.phase)
        } catch {
            statusText = "Waiting for Full Access"
        }
    }

    private func failActiveRequest(message: String) {
        guard let activeRequestID else {
            statusText = message
            currentPhase = .failed
            return
        }

        self.activeRequestID = nil
        requestStartedAt = nil
        isWaitingForResult = false
        hasStopBeenRequested = false
        stopRequestedAt = nil
        currentPhase = .failed
        statusText = message
        try? store.saveStatus(.init(requestID: activeRequestID, phase: .failed, message: message))
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

    private func hasStopHandoffTimedOut(status: DictationStatus) -> Bool {
        guard let stopRequestedAt else { return false }
        guard status.phase == .requested || status.phase == .recording else { return false }
        return Date().timeIntervalSince(stopRequestedAt) > Self.stopHandoffTimeout
    }

    private func hasStartHandoffTimedOut(status: DictationStatus) -> Bool {
        guard !hasStopBeenRequested, let requestStartedAt else { return false }
        guard status.phase == .requested else { return false }
        return Date().timeIntervalSince(requestStartedAt) > Self.startHandoffTimeout
    }

    private func hasTranscriptionTimedOut(status: DictationStatus) -> Bool {
        guard let stopRequestedAt else { return false }
        guard status.phase == .transcribing else { return false }
        return Date().timeIntervalSince(stopRequestedAt) > Self.transcriptionTimeout
    }
}

enum ColorToken {
    case accent
    case recording
    case transcribing
}
