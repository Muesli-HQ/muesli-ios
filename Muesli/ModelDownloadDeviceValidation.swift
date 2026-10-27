#if DEBUG
import Foundation
import UIKit

/// Opt-in physical-device validation in the separate development app. It uses
/// the production background downloader and runtime, not a second download path.
@MainActor
final class ModelDownloadDeviceValidation: ModelBackgroundDownloadServiceDelegate {
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
            runner.finished = false
            runner.failure = nil
            runner.lastPercent = -1
            var result = ["model": name, "status": "downloading", "startedAt": Date.now.ISO8601Format()]
            write(results + [result])
            do {
                let receipt = ModelBackgroundDownloadService.storageDirectory(for: model)?
                    .appendingPathComponent(".muesli-verified-manifest.json")
                let cachedManifest = receipt.flatMap { try? Data(contentsOf: $0) }
                    .flatMap { try? JSONDecoder().decode(ModelDownloadManifest.self, from: $0) }
                let forceRefresh = arguments.contains("--muesli-validate-mirror-corruption") || cachedManifest?.source != .mirror
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
                    let output = try await engine.transcribeDetailed(audioURL: documents.appendingPathComponent(name))
                    guard !output.text.isEmpty else { throw ValidationFailure(message: "Empty fixture transcript") }
                    result["transcript"] = output.text
                    result["tokenCount"] = String(output.tokens.count)
                }
                await engine.unloadModel(model)
                result["status"] = "passed"
            } catch { result["status"] = "failed"; result["error"] = error.localizedDescription }
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
    func modelBackgroundDownloadDidUpdate(model: LocalTranscriptionModel, progress: Double, detail: String) {
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
#endif
