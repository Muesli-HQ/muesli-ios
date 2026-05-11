import Foundation
import Observation

@MainActor
@Observable
final class KeyboardController {
    private let store = SharedStore()
    private var pollingTask: Task<Void, Never>?
    private var latestResultID: UUID?

    var statusText = "Record in Muesli first"
    var hasLatestDictation = false
    var textInserter: (@MainActor (String) -> Void)?

    var primaryButtonTitle: String {
        hasLatestDictation ? "Insert Latest" : "Record in Muesli"
    }

    var primaryButtonIcon: String {
        hasLatestDictation ? "text.insert" : "waveform"
    }

    var primaryButtonColor: ColorToken {
        hasLatestDictation ? .accent : .transcribing
    }

    var isPrimaryButtonDisabled: Bool {
        !hasLatestDictation
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
            guard let result = try store.resultsHistory().first else {
                latestResultID = nil
                hasLatestDictation = false
                statusText = "Record in Muesli first"
                return
            }

            hasLatestDictation = true
            if latestResultID != result.id {
                latestResultID = result.id
                statusText = "Latest ready"
            } else if statusText != "Inserted" {
                statusText = "Latest ready"
            }
        } catch {
            statusText = "Waiting for Full Access"
        }
    }
}

enum ColorToken {
    case accent
    case recording
    case transcribing
}
