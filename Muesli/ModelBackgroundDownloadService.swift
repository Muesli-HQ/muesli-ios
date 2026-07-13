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
    private var requestedAttempt: ModelDownloadAttempt?
    private var activePlan: DownloadPlan?
    private var taskBytes: [Int: Int64] = [:]
    private var activeTaskIDs = Set<Int>()
    private var failedTaskIDs = Set<Int>()
    private var failedAttemptIDs = Set<UUID>()
    private var failedModelRawValues = Set<String>()
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

    static func storageDirectory(for model: LocalTranscriptionModel) -> URL? {
        if let whisperVariant = model.whisperVariant {
            return WhisperKitTranscriptionRuntime.modelDirectory(for: whisperVariant)
        }

        if model == .parakeetRealtimeEou120m {
            return FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
                .appendingPathComponent("FluidAudio", isDirectory: true)
                .appendingPathComponent("Models", isDirectory: true)
                .appendingPathComponent("parakeet-eou-streaming", isDirectory: true)
                .appendingPathComponent("320ms", isDirectory: true)
        }

        return ModelDownloadSpec(model: model)?.repoRoot
    }

    static func isModelDownloaded(_ model: LocalTranscriptionModel) -> Bool {
        if let whisperVariant = model.whisperVariant {
            return WhisperKitTranscriptionRuntime.isModelDownloaded(whisperVariant)
        }

        if model == .parakeetRealtimeEou120m {
            guard let modelDirectory = storageDirectory(for: model) else { return false }
            return ModelNames.ParakeetEOU.requiredModels.allSatisfy { modelName in
                FileManager.default.fileExists(
                    atPath: modelDirectory.appendingPathComponent(modelName).path
                )
            }
        }

        guard let spec = ModelDownloadSpec(model: model) else { return false }
        return spec.requiredModels.allSatisfy { modelName in
            FileManager.default.fileExists(
                atPath: spec.repoRoot.appendingPathComponent(modelName).path
            )
        }
    }

    static func removeDownloadedModel(_ model: LocalTranscriptionModel) throws {
        guard let directory = storageDirectory(for: model) else { return }
        try removeDownloadedModel(at: directory)
    }

    static func removeDownloadedModel(at directory: URL) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    func setBackgroundCompletionHandler(_ handler: @escaping () -> Void) {
        let handler = SendableCompletionHandler(handler)
        _ = session
        stateQueue.async {
            self.backgroundCompletionHandler = handler
        }
    }

    func startDownload(for model: LocalTranscriptionModel) async throws -> Bool {
        let attemptID = UUID()
        let attempt = ModelDownloadAttempt(modelRawValue: model.rawValue, id: attemptID)
        let startDecision: (shouldStart: Bool, previousAttempt: ModelDownloadAttempt?) = stateQueue.sync {
            if requestedAttempt?.modelRawValue == model.rawValue
                || activePlan?.modelRawValue == model.rawValue {
                return (false, nil)
            }

            let previousAttempt = requestedAttempt ?? activePlan?.attempt
            requestedAttempt = attempt
            activePlan = nil
            taskBytes = [:]
            activeTaskIDs = []
            failedTaskIDs = []
            return (true, previousAttempt)
        }
        guard startDecision.shouldStart else { return true }

        if let previousAttempt = startDecision.previousAttempt {
            await cancelTasks(for: previousAttempt)
        }

        guard let spec = ModelDownloadSpec(model: model) else {
            clearRequestedAttempt(ifMatching: attempt)
            return false
        }

        let files: [ModelDownloadFile]
        do {
            files = try await Self.listFiles(for: spec)
        } catch {
            clearRequestedAttempt(ifMatching: attempt)
            throw error
        }
        let missingFiles = files.filter { file in
            !FileManager.default.fileExists(atPath: spec.destinationURL(for: file.localPath).path)
        }

        guard !missingFiles.isEmpty else {
            clearRequestedAttempt(ifMatching: attempt)
            return false
        }

        let totalBytes = missingFiles.reduce(Int64(0)) { partial, file in
            partial + max(0, file.size)
        }
        let plan = DownloadPlan(
            attempt: attempt,
            totalBytes: max(totalBytes, 1),
            pendingCount: missingFiles.count
        )

        let shouldStart: Bool = stateQueue.sync {
            guard requestedAttempt == attempt else { return false }
            activePlan = plan
            taskBytes = [:]
            activeTaskIDs = []
            failedTaskIDs = []
            failedAttemptIDs.remove(attemptID)
            failedModelRawValues.remove(model.rawValue)
            return true
        }
        guard shouldStart else { return false }

        await MainActor.run {
            delegate?.modelBackgroundDownloadDidUpdate(
                model: model,
                progress: 0,
                detail: "Downloading model files..."
            )
        }

        do {
            for file in missingFiles {
                try Task.checkCancellation()
                guard stateQueue.sync(execute: { activePlan?.attempt == attempt }) else {
                    return false
                }
                let destination = spec.destinationURL(for: file.localPath)
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )

                if file.size == 0 {
                    FileManager.default.createFile(atPath: destination.path, contents: Data())
                    stateQueue.async {
                        guard self.activePlan?.attempt == attempt else { return }
                        self.activePlan?.pendingCount -= 1
                        self.completeIfNeeded()
                    }
                    continue
                }

                var request = URLRequest(url: file.remoteURL)
                request.timeoutInterval = 60 * 30
                let task = session.downloadTask(with: request)
                task.taskDescription = file.taskDescription(model: model, attemptID: attemptID)
                let shouldResume: Bool = stateQueue.sync {
                    guard activePlan?.attempt == attempt else { return false }
                    taskBytes[task.taskIdentifier] = 0
                    activeTaskIDs.insert(task.taskIdentifier)
                    return true
                }
                guard shouldResume else {
                    task.cancel()
                    return false
                }
                task.resume()
            }
        } catch {
            clearRequestedAttempt(ifMatching: attempt)
            await cancelTasks(for: attempt)
            throw error
        }

        return true
    }

    private func clearRequestedAttempt(ifMatching attempt: ModelDownloadAttempt) {
        stateQueue.sync {
            guard requestedAttempt == attempt else { return }
            requestedAttempt = nil
            if activePlan?.attempt == attempt {
                activePlan = nil
                taskBytes = [:]
                activeTaskIDs = []
                failedTaskIDs = []
            }
        }
    }

    private func cancelTasks(for attempt: ModelDownloadAttempt) async {
        let tasks = await session.allTasks
        tasks.filter { task in
            guard let description = task.taskDescription,
                  let file = ModelDownloadFile(taskDescription: description)
            else { return false }
            return attempt.matches(file)
        }
        .forEach { $0.cancel() }
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

    private func updateProgress(task: URLSessionTask, bytesWritten: Int64) {
        var snapshot: (LocalTranscriptionModel, Double)?
        stateQueue.sync {
            guard let plan = activePlan,
                  let description = task.taskDescription,
                  let file = ModelDownloadFile(taskDescription: description),
                  plan.matches(file),
                  activeTaskIDs.contains(task.taskIdentifier),
                  let model = LocalTranscriptionModel(rawValue: plan.modelRawValue)
            else {
                snapshot = nil
                return
            }
            taskBytes[task.taskIdentifier] = bytesWritten
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

        let shouldProcess = stateQueue.sync {
            if let plan = activePlan {
                return plan.matches(file) && activeTaskIDs.contains(task.taskIdentifier)
            }
            if let requestedAttempt {
                return requestedAttempt.matches(file)
            }
            if let attemptID = file.attemptID {
                return !failedAttemptIDs.contains(attemptID)
            }
            return !failedModelRawValues.contains(file.model.rawValue)
        }
        guard shouldProcess else { return }

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
                if let requestedAttempt = self.requestedAttempt,
                   !requestedAttempt.matches(file) {
                    return
                }
                if let attemptID = file.attemptID {
                    guard !self.failedAttemptIDs.contains(attemptID) else { return }
                } else {
                    guard !self.failedModelRawValues.contains(file.model.rawValue) else { return }
                }
                self.completedModelsDuringBackgroundEvents.insert(file.model.rawValue)
                return
            }

            guard self.activeTaskIDs.remove(task.taskIdentifier) != nil,
                  self.failedTaskIDs.remove(task.taskIdentifier) == nil,
                  self.activePlan?.matches(file) == true
            else { return }

            self.activePlan?.pendingCount -= 1
            self.taskBytes[task.taskIdentifier] = max(self.taskBytes[task.taskIdentifier] ?? 0, file.size)
            self.completeIfNeeded()
        }
    }

    private func completeIfNeeded() {
        guard let plan = activePlan, plan.pendingCount <= 0 else { return }
        activePlan = nil
        if requestedAttempt == plan.attempt {
            requestedAttempt = nil
        }
        taskBytes = [:]
        activeTaskIDs = []
        failedTaskIDs = []
        let handler = backgroundCompletionHandler
        backgroundCompletionHandler = nil

        guard let model = LocalTranscriptionModel(rawValue: plan.modelRawValue) else {
            Task { @MainActor in
                handler?()
            }
            return
        }

        Task { @MainActor in
            delegate?.modelBackgroundDownloadDidFinish(model: model)
            handler?()
        }
    }

    private func fail(_ task: URLSessionTask?, error: Error) {
        let taskFile = task?.taskDescription.flatMap(ModelDownloadFile.init(taskDescription:))
        let result: DownloadFailureResult = stateQueue.sync {
            let attempt: ModelDownloadAttempt
            if let taskFile {
                attempt = ModelDownloadAttempt(
                    modelRawValue: taskFile.model.rawValue,
                    id: taskFile.attemptID
                )
                if let activePlan, !activePlan.matches(taskFile) {
                    return .ignored
                }
                if activePlan == nil,
                   let requestedAttempt,
                   !requestedAttempt.matches(attempt) {
                    return .ignored
                }
            } else if let activePlan {
                attempt = activePlan.attempt
            } else {
                return .ignored
            }

            if let attemptID = attempt.id {
                guard !failedAttemptIDs.contains(attemptID) else { return .ignored }
                failedAttemptIDs.insert(attemptID)
            } else {
                guard !failedModelRawValues.contains(attempt.modelRawValue) else { return .ignored }
                failedModelRawValues.insert(attempt.modelRawValue)
            }

            if let task {
                failedTaskIDs.insert(task.taskIdentifier)
            }
            if activePlan?.attempt.matches(attempt) == true {
                activePlan = nil
                taskBytes = [:]
                activeTaskIDs = []
            }
            if requestedAttempt?.matches(attempt) == true {
                requestedAttempt = nil
            }
            let handler = backgroundCompletionHandler
            backgroundCompletionHandler = nil
            return DownloadFailureResult(
                model: LocalTranscriptionModel(rawValue: attempt.modelRawValue),
                attempt: attempt,
                handler: handler
            )
        }

        guard let attempt = result.attempt else { return }
        session.getAllTasks { tasks in
            let tasksToCancel = tasks.filter { task in
                guard let description = task.taskDescription,
                      let file = ModelDownloadFile(taskDescription: description)
                else { return false }
                return attempt.matches(file)
            }
            tasksToCancel.forEach { $0.cancel() }
        }

        guard let model = result.model else {
            Task { @MainActor in
                result.handler?()
            }
            return
        }

        Task { @MainActor in
            delegate?.modelBackgroundDownloadDidFail(
                model: model,
                message: "Download paused. Check your connection and try again."
            )
            result.handler?()
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
        updateProgress(task: downloadTask, bytesWritten: totalBytesWritten)
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
            completedModels.forEach { self.failedModelRawValues.remove($0.rawValue) }
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

struct ModelDownloadAttempt: Equatable, Sendable {
    let modelRawValue: String
    let id: UUID?

    init(modelRawValue: String, id: UUID?) {
        self.modelRawValue = modelRawValue
        self.id = id
    }

    func matches(_ other: ModelDownloadAttempt) -> Bool {
        modelRawValue == other.modelRawValue && id == other.id
    }

    func matches(_ file: ModelDownloadFile) -> Bool {
        modelRawValue == file.model.rawValue && id == file.attemptID
    }
}

struct DownloadPlan {
    let attempt: ModelDownloadAttempt
    let totalBytes: Int64
    var pendingCount: Int

    var modelRawValue: String { attempt.modelRawValue }

    func matches(_ file: ModelDownloadFile) -> Bool {
        attempt.matches(file)
    }
}

struct ModelDownloadFile {
    let remotePath: String
    let localPath: String
    let remoteURL: URL
    let size: Int64
    let model: LocalTranscriptionModel
    let attemptID: UUID?

    init(
        remotePath: String,
        localPath: String,
        remoteURL: URL,
        size: Int64,
        model: LocalTranscriptionModel? = nil,
        attemptID: UUID? = nil
    ) {
        self.remotePath = remotePath
        self.localPath = localPath
        self.remoteURL = remoteURL
        self.size = size
        self.model = model ?? .defaultModel
        self.attemptID = attemptID
    }

    init?(taskDescription: String) {
        let parts = taskDescription.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 5 || parts.count == 6,
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
        if parts.count == 6 {
            guard let attemptID = UUID(uuidString: parts[5]) else { return nil }
            self.attemptID = attemptID
        } else {
            attemptID = nil
        }
    }

    func taskDescription(model: LocalTranscriptionModel, attemptID: UUID) -> String {
        [
            model.rawValue,
            remotePath,
            localPath,
            remoteURL.absoluteString,
            String(size),
            attemptID.uuidString,
        ].joined(separator: "\n")
    }
}

private struct DownloadFailureResult {
    let model: LocalTranscriptionModel?
    let attempt: ModelDownloadAttempt?
    let handler: SendableCompletionHandler?

    static let ignored = DownloadFailureResult(model: nil, attempt: nil, handler: nil)
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
        case .parakeetRealtimeEou120m,
             .whisperTinyEnglish, .whisperSmallEnglish, .whisperMediumEnglish, .whisperLargeTurbo:
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
