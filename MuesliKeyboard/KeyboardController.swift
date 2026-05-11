import Foundation
import Observation

@MainActor
@Observable
final class KeyboardController {
    private let store = SharedStore()
    private var pollingTask: Task<Void, Never>?
    private var activeRequestID: UUID?

    var statusText = "Tap to dictate"
    var isWaitingForResult = false
    var textInserter: (@MainActor (String) -> Void)?
    var appOpener: (@MainActor (URL) -> Void)?

    func beginDictation() {
        guard !isWaitingForResult else { return }

        let request = DictationRequest()
        activeRequestID = request.id
        isWaitingForResult = true
        statusText = "Opening Muesli"

        do {
            try store.saveRequest(request)
            appOpener?(dictationURL(for: request))
            startPolling()
        } catch {
            isWaitingForResult = false
            statusText = "Enable Full Access"
        }
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
                statusText = "Inserted"
                return
            }

            let status = try store.status()
            statusText = status.message ?? label(for: status.phase)
        } catch {
            statusText = "Waiting for Full Access"
        }
    }

    private func dictationURL(for request: DictationRequest) -> URL {
        var components = URLComponents()
        components.scheme = MuesliAppConstants.urlScheme
        components.host = MuesliAppConstants.dictateHost
        components.queryItems = [
            URLQueryItem(name: MuesliAppConstants.requestQueryItem, value: request.id.uuidString)
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
