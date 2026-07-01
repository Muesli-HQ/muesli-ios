import Foundation
@preconcurrency import FluidAudio

@MainActor
protocol ModelBackgroundDownloadServiceDelegate: AnyObject {
    func modelBackgroundDownloadDidUpdate(model: LocalTranscriptionModel, progress: Double, detail: String)
    func modelBackgroundDownloadDidFinish(model: LocalTranscriptionModel)
    func modelBackgroundDownloadDidFail(model: LocalTranscriptionModel, message: String)
}

final class ModelBackgroundDownloadService: NSObject, @unchecked Sendable {
    static let shared = ModelBackgroundDownloadService()

    private static let sessionIdentifier = "com.phequals7.muesli.ios.model-downloads"

    @MainActor weak var delegate: ModelBackgroundDownloadServiceDelegate?

    private let stateQueue = DispatchQueue(label: "com.phequals7.muesli.model-background-download")
    private var activePlan: DownloadPlan?
    private var taskBytes: [Int: Int64] = [:]
    private var backgroundCompletionHandler: SendableCompletionHandler?
    private var completedModelsDuringBackgroundEvents = Set<String>()

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.allowsCellularAccess = true
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForResource = 60 * 60
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        super.init()
    }

    func setBackgroundCompletionHandler(_ handler: @escaping () -> Void) {
        let handler = SendableCompletionHandler(handler)
        _ = session
        stateQueue.async {
            self.backgroundCompletionHandler = handler
        }
    }

    func startDownload(for model: LocalTranscriptionModel) async throws -> Bool {
        guard let spec = ModelDownloadSpec(model: model) else {
            return false
        }

        if spec.requiredModelsExist {
            return false
        }

        let files = try await Self.listFiles(for: spec)
        let missingFiles = files.filter { file in
            !FileManager.default.fileExists(atPath: spec.destinationURL(for: file.localPath).path)
        }

        guard !missingFiles.isEmpty else {
            return false
        }

        let totalBytes = missingFiles.reduce(Int64(0)) { partial, file in
            partial + max(0, file.size)
        }
        let plan = DownloadPlan(modelRawValue: model.rawValue, totalBytes: max(totalBytes, 1), pendingCount: missingFiles.count)

        await MainActor.run {
            delegate?.modelBackgroundDownloadDidUpdate(
                model: model,
                progress: 0,
                detail: "Downloading model files..."
            )
        }

        stateQueue.sync {
            activePlan = plan
            taskBytes = [:]
        }

        for file in missingFiles {
            try Task.checkCancellation()
            let destination = spec.destinationURL(for: file.localPath)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            if file.size == 0 {
                FileManager.default.createFile(atPath: destination.path, contents: Data())
                stateQueue.async {
                    self.activePlan?.pendingCount -= 1
                    self.completeIfNeeded()
                }
                continue
            }

            var request = URLRequest(url: file.remoteURL)
            request.timeoutInterval = 60 * 30
            let task = session.downloadTask(with: request)
            task.taskDescription = file.taskDescription(model: model)
            stateQueue.sync {
                taskBytes[task.taskIdentifier] = 0
            }
            task.resume()
        }

        return true
    }

    private static func listFiles(for spec: ModelDownloadSpec) async throws -> [ModelDownloadFile] {
        var files: [ModelDownloadFile] = []

        func listDirectory(path: String) async throws {
            let apiPath = path.isEmpty ? "tree/main" : "tree/main/\(path)"
            let urlString = "https://huggingface.co/api/models/\(spec.remotePath)/\(apiPath)"
            guard let url = URL(string: urlString) else { return }
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw URLError(.cannotParseResponse)
            }

            for item in items {
                guard let itemPath = item["path"] as? String,
                      let itemType = item["type"] as? String
                else { continue }

                if itemType == "directory" {
                    if spec.shouldProcessDirectory(itemPath) {
                        try await listDirectory(path: itemPath)
                    }
                } else if itemType == "file", spec.shouldDownloadFile(itemPath) {
                    let localPath = spec.localPath(forRemotePath: itemPath)
                    guard let encodedPath = itemPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                          let remoteURL = URL(string: "https://huggingface.co/\(spec.remotePath)/resolve/main/\(encodedPath)")
                    else { continue }
                    files.append(
                        ModelDownloadFile(
                            remotePath: itemPath,
                            localPath: localPath,
                            remoteURL: remoteURL,
                            size: Int64(item["size"] as? Int ?? 0)
                        )
                    )
                }
            }
        }

        try await listDirectory(path: spec.subPath ?? "")
        return files
    }

    private func updateProgress(taskIdentifier: Int, bytesWritten: Int64) {
        var snapshot: (LocalTranscriptionModel, Double)?
        stateQueue.sync {
            guard let plan = activePlan,
                  let model = LocalTranscriptionModel(rawValue: plan.modelRawValue)
            else {
                snapshot = nil
                return
            }
            taskBytes[taskIdentifier] = bytesWritten
            let completed = taskBytes.values.reduce(Int64(0), +)
            snapshot = (model, min(max(Double(completed) / Double(plan.totalBytes), 0), 0.98))
        }

        guard let snapshot else { return }
        Task { @MainActor in
            delegate?.modelBackgroundDownloadDidUpdate(
                model: snapshot.0,
                progress: snapshot.1,
                detail: "\(Int((snapshot.1 * 100).rounded()))% downloaded"
            )
        }
    }

    private func completeTask(_ task: URLSessionTask, location: URL) throws {
        guard let description = task.taskDescription,
              let file = ModelDownloadFile(taskDescription: description),
              let spec = ModelDownloadSpec(model: file.model)
        else {
            throw URLError(.badURL)
        }

        let destination = spec.destinationURL(for: file.localPath)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: location, to: destination)

        stateQueue.async {
            if self.activePlan == nil {
                self.completedModelsDuringBackgroundEvents.insert(file.model.rawValue)
            } else {
                self.activePlan?.pendingCount -= 1
                self.taskBytes[task.taskIdentifier] = max(self.taskBytes[task.taskIdentifier] ?? 0, file.size)
            }
            self.completeIfNeeded()
        }
    }

    private func completeIfNeeded() {
        guard let plan = activePlan, plan.pendingCount <= 0 else { return }
        activePlan = nil
        taskBytes = [:]
        let handler = backgroundCompletionHandler
        backgroundCompletionHandler = nil

        guard let model = LocalTranscriptionModel(rawValue: plan.modelRawValue) else {
            handler?()
            return
        }

        Task { @MainActor in
            delegate?.modelBackgroundDownloadDidFinish(model: model)
            handler?()
        }
    }

    private func fail(_ task: URLSessionTask?, error: Error) {
        let model = task?.taskDescription.flatMap { ModelDownloadFile(taskDescription: $0)?.model }
            ?? activePlan.flatMap { LocalTranscriptionModel(rawValue: $0.modelRawValue) }
        let handler: SendableCompletionHandler? = stateQueue.sync {
            activePlan = nil
            taskBytes = [:]
            let handler = backgroundCompletionHandler
            backgroundCompletionHandler = nil
            return handler
        }

        guard let model else {
            handler?()
            return
        }

        Task { @MainActor in
            delegate?.modelBackgroundDownloadDidFail(
                model: model,
                message: "Download paused. Check your connection and try again."
            )
            handler?()
        }
    }
}

extension ModelBackgroundDownloadService: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        updateProgress(taskIdentifier: downloadTask.taskIdentifier, bytesWritten: totalBytesWritten)
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            try completeTask(downloadTask, location: location)
        } catch {
            fail(downloadTask, error: error)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            fail(task, error: error)
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        stateQueue.async {
            guard self.activePlan == nil else { return }
            let handler = self.backgroundCompletionHandler
            let completedModels = self.completedModelsDuringBackgroundEvents.compactMap(LocalTranscriptionModel.init(rawValue:))
            self.completedModelsDuringBackgroundEvents = []
            self.backgroundCompletionHandler = nil
            DispatchQueue.main.async {
                completedModels.forEach { model in
                    self.delegate?.modelBackgroundDownloadDidFinish(model: model)
                }
                handler?()
            }
        }
    }
}

private final class SendableCompletionHandler: @unchecked Sendable {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    func callAsFunction() {
        handler()
    }
}

private struct DownloadPlan {
    let modelRawValue: String
    let totalBytes: Int64
    var pendingCount: Int
}

private struct ModelDownloadFile {
    let remotePath: String
    let localPath: String
    let remoteURL: URL
    let size: Int64
    let model: LocalTranscriptionModel

    init(remotePath: String, localPath: String, remoteURL: URL, size: Int64, model: LocalTranscriptionModel? = nil) {
        self.remotePath = remotePath
        self.localPath = localPath
        self.remoteURL = remoteURL
        self.size = size
        self.model = model ?? .defaultModel
    }

    init?(taskDescription: String) {
        let parts = taskDescription.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 5,
              let model = LocalTranscriptionModel(rawValue: parts[0]),
              let remoteURL = URL(string: parts[3]),
              let size = Int64(parts[4])
        else {
            return nil
        }
        self.model = model
        remotePath = parts[1]
        localPath = parts[2]
        self.remoteURL = remoteURL
        self.size = size
    }

    func taskDescription(model: LocalTranscriptionModel) -> String {
        [model.rawValue, remotePath, localPath, remoteURL.absoluteString, String(size)].joined(separator: "\n")
    }
}

private struct ModelDownloadSpec {
    let model: LocalTranscriptionModel
    let repoFolderName: String
    let remotePath: String
    let subPath: String?
    let requiredModels: Set<String>

    init?(model: LocalTranscriptionModel) {
        self.model = model
        switch model {
        case .parakeetTdtCtc110m:
            repoFolderName = "parakeet-tdt-ctc-110m"
            remotePath = "FluidInference/parakeet-tdt-ctc-110m-coreml"
            subPath = nil
            requiredModels = [
                "Preprocessor.mlmodelc",
                "Decoder.mlmodelc",
                "JointDecision.mlmodelc"
            ]
        case .parakeetV3:
            repoFolderName = "parakeet-tdt-0.6b-v3-coreml"
            remotePath = "FluidInference/parakeet-tdt-0.6b-v3-coreml"
            subPath = nil
            requiredModels = [
                "Preprocessor.mlmodelc",
                "Encoder.mlmodelc",
                "Decoder.mlmodelc",
                "JointDecisionv3.mlmodelc"
            ]
        case .parakeetRealtimeEou120m:
            return nil
        }
    }

    var modelsRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    var repoRoot: URL {
        modelsRoot.appendingPathComponent(repoFolderName, isDirectory: true)
    }

    var requiredModelsExist: Bool {
        requiredModels.allSatisfy {
            FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent($0).path)
        }
    }

    func destinationURL(for localPath: String) -> URL {
        repoRoot.appendingPathComponent(localPath)
    }

    func localPath(forRemotePath remotePath: String) -> String {
        guard let subPath, remotePath.hasPrefix("\(subPath)/") else {
            return remotePath
        }
        return String(remotePath.dropFirst(subPath.count + 1))
    }

    func shouldProcessDirectory(_ path: String) -> Bool {
        if let subPath {
            return path == subPath
                || path.hasPrefix("\(subPath)/")
                || requiredModels.contains { "\($0)/".hasPrefix(path + "/") }
        }
        return requiredModels.contains { path == $0 || $0.hasPrefix(path + "/") || path.hasPrefix("\($0)/") }
    }

    func shouldDownloadFile(_ path: String) -> Bool {
        let local = localPath(forRemotePath: path)
        return requiredModels.contains { local.hasPrefix("\($0)/") }
            || local.hasSuffix(".json")
            || local.hasSuffix(".txt")
    }
}
