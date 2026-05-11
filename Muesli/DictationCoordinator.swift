import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class DictationCoordinator {
    private let store = SharedStore()
    private let engine: TranscriptionEngine = FluidAudioTranscriptionEngine()
    private let recorder = AudioRecorder()

    private var activeRequest: DictationRequest?
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
        startRecording(for: request)
    }

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording(for: DictationRequest())
        }
    }

    private func startRecording(for request: DictationRequest) {
        activeRequest = request

        Task {
            do {
                try await recorder.requestPermission()
                try recorder.start()
                isRecording = true
                statusText = "Recording"
                try store.saveRequest(request)
                try store.saveStatus(.init(requestID: request.id, phase: .recording))
            } catch {
                statusText = error.localizedDescription
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
            } catch {
                statusText = error.localizedDescription
                try? store.saveStatus(.init(requestID: request.id, phase: .failed, message: error.localizedDescription))
            }
        }
    }
}
