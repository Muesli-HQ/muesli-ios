#if DEBUG
import Foundation
import AVFoundation
import UIKit
import SwiftUI
import Observation

/// Opt-in physical-device validation in the separate development app. It uses
/// the production background downloader and runtime, not a second download path.
@MainActor
final class ModelDownloadDeviceValidation: ModelBackgroundDownloadServiceDelegate {
    static let display = ModelValidationDisplay()
    private var finished = false
    private var failure: String?
    private var lastPercent = -1
    private static var started = false

    /// Exercises checksum rejection and the real background HF fallback on a
    /// development device. Never active in the production bundle or Release.
    nonisolated static func applyingFaultIfRequested(_ manifest: ModelDownloadManifest) -> ModelDownloadManifest {
        guard Bundle.main.bundleIdentifier == "com.phequals7.muesli.ios.dev",
              ProcessInfo.processInfo.arguments.contains("--muesli-validate-mirror-corruption") else { return manifest }
        let files = manifest.files.enumerated().map { index, file in
            ModelDownloadFile(remotePath: file.remotePath, localPath: file.localPath, remoteURL: file.remoteURL,
                              size: file.size, model: file.model,
                              sha256: index == 0 ? String(repeating: "0", count: 64) : file.sha256,
                              gitSHA1: file.gitSHA1)
        }
        return .init(source: manifest.source, version: manifest.version, files: files)
    }

    static func runIfRequested() async {
        let arguments = ProcessInfo.processInfo.arguments
        guard !started, Bundle.main.bundleIdentifier == "com.phequals7.muesli.ios.dev",
              let index = arguments.firstIndex(of: "--muesli-validate-models"), arguments.indices.contains(index + 1) else { return }
        started = true
        let previousIdleTimer = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = previousIdleTimer }
        let names = arguments[index + 1].split(separator: ",").map(String.init)
        let runner = ModelDownloadDeviceValidation()
        let service = ModelBackgroundDownloadService.shared
        let previous = service.delegate
        service.delegate = runner
        defer { service.delegate = previous }
        var results: [[String: String]] = []
        for name in names {
            guard let model = LocalTranscriptionModel(rawValue: name) else { continue }
            display.model = model
            display.state = .init(phase: .downloading, status: "Downloading", detail: "")
            runner.finished = false
            runner.failure = nil
            runner.lastPercent = -1
            var result = ["model": name, "status": "downloading", "startedAt": Date.now.ISO8601Format()]
            write(results + [result])
            do {
                let forceRefresh = arguments.contains("--muesli-validate-mirror-corruption") || arguments.contains("--muesli-validate-force-download")
                let pending = try await service.startDownload(for: model, forceRefresh: forceRefresh)
                let deadline = Date.now.addingTimeInterval(1800)
                var nextTaskReport = Date.distantPast
                while pending && !runner.finished && runner.failure == nil && Date.now < deadline {
                    if Date.now >= nextTaskReport {
                        print("MUESLI_DOWNLOAD_TASKS \(await service.validationTaskSummary())")
                        nextTaskReport = Date.now.addingTimeInterval(30)
                    }
                    try await Task.sleep(for: .seconds(1))
                }
                if let failure = runner.failure { throw ValidationFailure(message: failure) }
                guard !pending || runner.finished else { throw ValidationFailure(message: "Download timed out") }
                let directory = try modelDirectory(model)
                let manifest = try JSONDecoder().decode(ModelDownloadManifest.self,
                    from: Data(contentsOf: directory.appendingPathComponent(".muesli-verified-manifest.json")))
                result["source"] = manifest.source.rawValue
                result["version"] = manifest.version
                result["files"] = String(manifest.files.count)
                for file in manifest.files { try ModelDownloadManifest.validate(file, at: directory.appendingPathComponent(file.localPath)) }
                if arguments.contains("--muesli-validate-downloads-only") {
                    result["status"] = "download-verified"
                    result["finishedAt"] = Date.now.ISO8601Format()
                    results.append(result)
                    write(results)
                    continue
                }
                result["status"] = "loading-runtime"
                write(results + [result])
                display.state = .init(phase: .preparing, status: "Loading", detail: "")
                let engine = FluidAudioTranscriptionEngine()
                await engine.selectModel(model)
                try await engine.prepare { _, status in
                    print("MUESLI_MODEL_PREPARE \(name) \(status ?? "Preparing")")
                }
                guard await engine.isLoaded(for: model) else { throw ValidationFailure(message: "Runtime did not become ready") }
                if let audioIndex = arguments.firstIndex(of: "--muesli-validate-audio"),
                   arguments.indices.contains(audioIndex + 1) {
                    let name = arguments[audioIndex + 1]
                    guard URL(fileURLWithPath: name).lastPathComponent == name else {
                        throw ValidationFailure(message: "Expected a fixture filename")
                    }
                    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    let transcriptionStarted = Date.now
                    let output = try await engine.transcribeDetailed(audioURL: documents.appendingPathComponent(name))
                    result["transcriptionSeconds"] = String(Date.now.timeIntervalSince(transcriptionStarted))
                    guard !output.text.isEmpty else { throw ValidationFailure(message: "Empty fixture transcript") }
                    result["transcript"] = output.text
                    result["tokenCount"] = String(output.tokens.count)
                    if arguments.contains("--muesli-validate-streaming"), model.supportsRealtimeStreaming {
                        try await engine.startRealtimeSession(partialTranscript: { text in
                            print("MUESLI_STREAM_PARTIAL \(text)")
                        })
                        let file = try AVAudioFile(forReading: documents.appendingPathComponent(name))
                        while file.framePosition < file.length {
                            let frames = AVAudioFrameCount(min(4_000, file.length - file.framePosition))
                            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
                                throw ValidationFailure(message: "Cannot allocate streaming fixture buffer")
                            }
                            try file.read(into: buffer, frameCount: frames)
                            try await engine.processRealtimeAudioBuffer(buffer)
                        }
                        let text = try await engine.finishRealtimeSession()
                        guard !text.isEmpty else { throw ValidationFailure(message: "Empty streaming transcript") }
                        result["streamingTranscript"] = text
                    }
                    // Repeat prepare must keep the ready runtime reusable, with no new download.
                    try await engine.prepare()
                    guard await engine.isLoaded(for: model) else { throw ValidationFailure(message: "Lost prepared runtime") }
                }
                await engine.unloadModel(model)
                result["status"] = "passed"
            } catch { result["status"] = "failed"; result["error"] = error.localizedDescription }
            display.state = result["status"] == "passed" ? .init(phase: .ready, status: "Ready", detail: "") : .init(phase: .failed, status: "Failed", detail: result["error"] ?? "")
            result["finishedAt"] = Date.now.ISO8601Format()
            results.append(result)
            write(results)
        }
        print("MUESLI_MODEL_VALIDATION_DONE")
    }

    private static func modelDirectory(_ model: LocalTranscriptionModel) throws -> URL {
        guard let directory = ModelBackgroundDownloadService.storageDirectory(for: model) else {
            throw ValidationFailure(message: "No model directory")
        }
        return directory
    }
    private static func write(_ results: [[String: String]]) {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("model-validation.json")
        if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
            print("MUESLI_MODEL_VALIDATION \(String(decoding: data, as: UTF8.self))")
        }
    }
    func modelBackgroundDownloadDidUpdate(model: LocalTranscriptionModel, progress: Double, detail: String, transfer: ModelDownloadProgressSnapshot?) {
        Self.display.state = .init(phase: .downloading, progress: progress, status: "Downloading", detail: detail, transfer: transfer)
        let percent = Int(progress * 10) * 10
        if percent != lastPercent { lastPercent = percent; print("MUESLI_MODEL_DOWNLOAD \(model.rawValue) \(detail)") }
    }
    func modelBackgroundDownloadDidFinish(model: LocalTranscriptionModel) { finished = true }
    func modelBackgroundDownloadDidFail(model: LocalTranscriptionModel, message: String) { failure = message }
    private struct ValidationFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}

@MainActor @Observable
final class ModelValidationDisplay {
    var model: LocalTranscriptionModel = .defaultModel
    var state = ModelPreparationState()
}

struct ModelValidationProgressView: View {
    private var display: ModelValidationDisplay { ModelDownloadDeviceValidation.display }
    var body: some View {
        ModelReadinessView(state: display.state, modelName: display.model.displayName, retry: nil)
            .padding(.horizontal, MuesliTheme.spacing16)
            .padding(.vertical, MuesliTheme.spacing4)
    }
}
#endif
