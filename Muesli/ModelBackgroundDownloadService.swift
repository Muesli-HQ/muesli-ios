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
    private static let sessionIdentifier = "\(Bundle.main.bundleIdentifier ?? "com.phequals7.muesli.ios").model-downloads"
    @MainActor weak var delegate: ModelBackgroundDownloadServiceDelegate?
    private let stateQueue = DispatchQueue(label: "com.phequals7.muesli.model-background-download")
    private var transaction: ModelDownloadTransaction?
    private var discoveryID: UUID?
    private var discoveryModel: LocalTranscriptionModel?
    private var running: [String: Int] = [:]
    private var taskBytes: [String: Int64] = [:]
    private var recoveryTask: Task<Void, Never>?
    private var isRestoring = true
    private var backgroundCompletionHandler: SendableCompletionHandler?
    private var backgroundEventsFinished = false
    private let journalURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ModelDownloads/active.json")
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.allowsCellularAccess = true
        configuration.waitsForConnectivity = true
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        super.init()
        if let data = try? Data(contentsOf: journalURL),
           let saved = try? JSONDecoder().decode(ModelDownloadTransaction.self, from: data),
           let model = saved.model, let spec = ModelDownloadSpec(model: model),
           (try? ModelDownloadManifest.validateCoverage(saved.manifest.files, spec: spec)) != nil {
            transaction = saved
        }
        _ = session
        recoveryTask = Task { await restoreBackgroundTasks() }
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let transaction {
            try JSONEncoder().encode(transaction).write(to: journalURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } else if FileManager.default.fileExists(atPath: journalURL.path) {
            try FileManager.default.removeItem(at: journalURL)
        }
    }

    private func restoreBackgroundTasks() async {
        let tasks = await session.allTasks
        stateQueue.sync {
            isRestoring = false
            running = [:]
            defer { finishSystemEventsIfNeeded() }
            for task in tasks {
                guard let file = task.taskDescription.flatMap(ModelDownloadFile.init(taskDescription:)),
                      let tx = transaction, tx.accepts(file),
                      task.state == .running || task.state == .suspended else {
                    task.cancel() // Obsolete or pre-journal tasks cannot certify a new installation.
                    continue
                }
                running[file.localPath] = task.taskIdentifier
                if task.state == .suspended { task.resume() }
            }
            guard let tx = transaction, let model = tx.model, let spec = ModelDownloadSpec(model: model) else { return }
            do {
                try ModelDownloadTransaction.recoverInstallation(at: spec.repoRoot)
                if tx.phase == .installing {
                    let stage = tx.stagingDirectory(for: spec.repoRoot)
                    if !FileManager.default.fileExists(atPath: stage.path) {
                        try finishInstalledModel(tx, spec: spec)
                        return
                    }
                    transaction?.phase = .downloading
                }
                if tx.phase == .needsFallback { beginFallback(); return }
                guard transaction?.phase == .downloading else { return }
                // A journal entry alone is not proof that the file survived a crash.
                transaction?.completed = Set(tx.completed.filter { path in
                    guard let file = tx.manifest.files.first(where: { $0.localPath == path }) else { return false }
                    return (try? ModelDownloadManifest.validate(file, at: tx.stagingDirectory(for: spec.repoRoot).appendingPathComponent(path))) != nil
                })
                try persist()
                try schedule()
            } catch {
                if tx.phase == .installing {
                    try? ModelDownloadTransaction.rollbackInstallation(staging: tx.stagingDirectory(for: spec.repoRoot), destination: spec.repoRoot)
                }
                finishFailure(error)
            }
        }
    }

    #if DEBUG
    func validationTaskSummary() async -> String {
        let tasks = await session.allTasks
        return tasks.map { "\($0.taskIdentifier):\($0.state.rawValue):\($0.countOfBytesReceived)/\($0.countOfBytesExpectedToReceive)" }.joined(separator: ",")
    }
    #endif

    func setBackgroundCompletionHandler(_ handler: @escaping () -> Void) {
        let wrapper = SendableCompletionHandler(handler)
        stateQueue.async {
            self.backgroundEventsFinished = false
            self.backgroundCompletionHandler = wrapper
        }
    }

    private func finishSystemEventsIfNeeded() {
        guard !isRestoring, backgroundEventsFinished, discoveryID == nil, let handler = backgroundCompletionHandler else { return }
        backgroundCompletionHandler = nil
        backgroundEventsFinished = false
        Task { @MainActor in handler() }
    }

    func startDownload(for model: LocalTranscriptionModel, forceRefresh: Bool = false) async throws -> Bool {
        await recoveryTask?.value
        let token = UUID()
        let needsDiscovery: Bool = try stateQueue.sync {
            if discoveryID != nil, discoveryModel == model { return false }
            if discoveryID != nil { discoveryID = nil }
            if let tx = transaction, tx.model == model {
                if tx.phase == .needsFallback { beginFallback(); return false }
                if tx.phase == .failed {
                    // Retried tasks need a new generation so cancellation/error
                    // callbacks from the old attempt cannot cancel the retry.
                    let freshID = UUID()
                    if let spec = ModelDownloadSpec(model: model) {
                        let verified = tx.verifiedCompletedFiles(at: spec.repoRoot)
                        try checkStorage(tx.manifest, spec: spec, verifiedFiles: verified)
                        let oldStage = tx.stagingDirectory(for: spec.repoRoot)
                        let newStage = ModelDownloadTransaction.stagingDirectory(id: freshID, destination: spec.repoRoot)
                        if FileManager.default.fileExists(atPath: oldStage.path) {
                            try FileManager.default.moveItem(at: oldStage, to: newStage)
                        }
                        transaction?.completed = verified
                    }
                    transaction?.id = freshID
                    transaction?.phase = .downloading
                    transaction?.failureMessage = nil
                    transaction?.retries = [:]
                    try persist()
                    try schedule()
                    return false
                }
                return false
            }
            discoveryID = token
            discoveryModel = model
            transaction?.phase = .failed
            try persist()
            return true
        }
        guard needsDiscovery else { return true }
        var newAttemptID: UUID?
        do {
            let tasks = await session.allTasks
            try stateQueue.sync {
                guard discoveryID == token else { throw CancellationError() }
                tasks.forEach { $0.cancel() }
                // Callbacks cannot accept the failed old generation. Delete its
                // staged files before forgetting the journal, even when the new
                // selection is already installed or discovery later fails.
                if let old = transaction, let oldModel = old.model,
                   let oldSpec = ModelDownloadSpec(model: oldModel) {
                    try old.removeStagingDirectories(at: oldSpec.repoRoot)
                }
                transaction = nil
                running = [:]
                taskBytes = [:]
                try persist()
            }
            guard let spec = ModelDownloadSpec(model: model) else {
                stateQueue.sync { discoveryID = nil }
                return false
            }
            if !forceRefresh, Self.isModelDownloaded(model) {
                try stateQueue.sync {
                    guard discoveryID == token else { throw CancellationError() }
                    transaction = nil
                    running = [:]
                    taskBytes = [:]
                    discoveryID = nil
                    try persist()
                }
                return false
            }
            let manifest = try await Self.resolveManifest(spec: spec)
            try Task.checkCancellation()
            try stateQueue.sync {
                guard discoveryID == token else { throw CancellationError() }
                transaction = ModelDownloadTransaction(id: UUID(), modelRawValue: model.rawValue, manifest: manifest)
                newAttemptID = transaction?.id
                running = [:]
                taskBytes = [:]
                discoveryID = nil
                try checkStorage(manifest, spec: spec)
                try persist()
                try schedule()
            }
            return true
        } catch {
            stateQueue.sync {
                guard discoveryID == token || (newAttemptID != nil && transaction?.id == newAttemptID) else { return }
                if discoveryID == token { discoveryID = nil }
                if transaction?.model == model { finishFailure(error) }
                finishSystemEventsIfNeeded()
            }
            throw error
        }
    }

    private func checkStorage(_ manifest: ModelDownloadManifest, spec: ModelDownloadSpec,
                              verifiedFiles: Set<String> = []) throws {
        let budget = try ModelDownloadStorageBudget(manifest: manifest, verifiedFiles: verifiedFiles)
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try ModelSetupStorage.check(at: root, downloadBytes: budget.missingBytes,
            modelBytes: spec.model.whisperVariant == nil ? 0 : budget.totalBytes)
    }

    /// Queue the complete manifest before suspension. Feeding a background
    /// session in tiny batches triggers iOS's relaunch rate limiter; connection
    /// scheduling belongs to URLSession (configured for two per host).
    private func schedule() throws {
        guard !isRestoring, let tx = transaction, tx.phase == .downloading,
              let model = tx.model, let spec = ModelDownloadSpec(model: model) else { return }
        if tx.completed.count == tx.manifest.files.count {
            try installCompletedModel(tx, spec: spec)
            return
        }
        let stage = tx.stagingDirectory(for: spec.repoRoot)
        for file in tx.manifest.files where !tx.completed.contains(file.localPath) && running[file.localPath] == nil {
            let destination = stage.appendingPathComponent(file.localPath)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            // Completed files from an interrupted callback can be reused after validation.
            if (try? ModelDownloadManifest.validate(file, at: destination)) != nil {
                transaction?.completed.insert(file.localPath)
                continue
            }
            var request = URLRequest(url: file.remoteURL)
            request.timeoutInterval = 60
            let task = session.downloadTask(with: request)
            if let retry = tx.retries[file.localPath], retry > 0 {
                task.earliestBeginDate = Date().addingTimeInterval(pow(2, Double(retry - 1)))
            }
            task.taskDescription = file.taskDescription(model: model, attemptID: tx.id)
            running[file.localPath] = task.taskIdentifier
            task.resume()
        }
        try persist()
        if running.isEmpty, transaction?.completed.count == tx.manifest.files.count {
            try installCompletedModel(transaction!, spec: spec)
        }
        publishProgress()
    }

    private func installCompletedModel(_ tx: ModelDownloadTransaction, spec: ModelDownloadSpec) throws {
        let stage = tx.stagingDirectory(for: spec.repoRoot)
        for file in tx.manifest.files { try ModelDownloadManifest.validate(file, at: stage.appendingPathComponent(file.localPath)) }
        transaction?.phase = .installing
        do {
            try persist()
            try ModelDownloadTransaction.install(staging: stage, destination: spec.repoRoot)
            try finishInstalledModel(tx, spec: spec)
        } catch {
            try? ModelDownloadTransaction.rollbackInstallation(staging: stage, destination: spec.repoRoot)
            transaction = tx
            finishFailure(error)
        }
    }

    private func finishInstalledModel(_ tx: ModelDownloadTransaction, spec: ModelDownloadSpec) throws {
        for file in tx.manifest.files { try ModelDownloadManifest.validate(file, at: spec.destinationURL(for: file.localPath)) }
        try JSONEncoder().encode(tx.manifest).write(to: spec.repoRoot.appendingPathComponent(".muesli-verified-manifest.json"), options: .atomic)
        try Self.finalizeDownloadedModel(spec.model)
        transaction = nil
        running = [:]
        taskBytes = [:]
        try persist()
        try? FileManager.default.removeItem(at: ModelDownloadTransaction.backupDirectory(for: spec.repoRoot))
        for id in tx.retiredStages {
            try? FileManager.default.removeItem(at: ModelDownloadTransaction.stagingDirectory(id: id, destination: spec.repoRoot))
        }
        Task { @MainActor in self.delegate?.modelBackgroundDownloadDidFinish(model: spec.model) }
    }

    private func publishProgress() {
        guard let tx = transaction, let model = tx.model else { return }
        let total = tx.manifest.files.reduce(Int64(0)) { $0 + $1.size }
        let bytes = tx.manifest.files.reduce(Int64(0)) { $0 + (tx.completed.contains($1.localPath) ? $1.size : min($1.size, taskBytes[$1.localPath] ?? 0)) }
        let fraction = min(0.98, Double(bytes) / Double(max(1, total)))
        let source = tx.manifest.source == .mirror ? "Muesli mirror" : "Hugging Face"
        Task { @MainActor in
            self.delegate?.modelBackgroundDownloadDidUpdate(model: model, progress: fraction,
                detail: "\(Int(fraction * 100))% downloaded · \(source)")
        }
    }

    private func completeTask(_ task: URLSessionDownloadTask, location: URL) throws {
        try stateQueue.sync {
            guard let metadata = task.taskDescription.flatMap(ModelDownloadFile.init(taskDescription:)),
                  let tx = transaction, tx.accepts(metadata),
                  let file = tx.manifest.files.first(where: { $0.localPath == metadata.localPath }),
                  let spec = ModelDownloadSpec(model: metadata.model) else { return }
            guard let response = task.response as? HTTPURLResponse else { throw ModelDownloadValidationError.badResponse }
            if response.statusCode >= 500 || response.statusCode == 429 { throw URLError(.badServerResponse) }
            guard (200..<300).contains(response.statusCode),
                  tx.manifest.source != .mirror || response.url == file.remoteURL else { throw ModelDownloadValidationError.badResponse }
            try ModelDownloadManifest.validate(file, at: location)
            let destination = tx.stagingDirectory(for: spec.repoRoot).appendingPathComponent(file.localPath)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: location, to: destination)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
            transaction?.completed.insert(file.localPath)
            running[file.localPath] = nil
            taskBytes[file.localPath] = nil
            try persist()
            try schedule()
        }
    }

    private func fail(_ task: URLSessionTask, error: Error) {
        stateQueue.async {
            guard let metadata = task.taskDescription.flatMap(ModelDownloadFile.init(taskDescription:)),
                  let tx = self.transaction, tx.accepts(metadata) else { return }
            self.running[metadata.localPath] = nil
            self.taskBytes[metadata.localPath] = nil
            let count = tx.retries[metadata.localPath, default: 0]
            do {
                if ModelSetupFailure.describe(error).status == "More storage needed" {
                    self.finishFailure(error)
                } else if count < 2, !(error is ModelDownloadValidationError), (error as NSError).code != NSURLErrorCancelled {
                    self.transaction?.retries[metadata.localPath] = count + 1
                    try self.persist()
                    try self.schedule()
                } else if tx.manifest.source == .mirror, (error as NSError).code != NSURLErrorCancelled,
                          ModelSetupFailure.describe(error).status != "More storage needed" {
                    self.transaction?.phase = .needsFallback
                    try self.persist()
                    self.beginFallback()
                } else { self.finishFailure(error) }
            } catch { self.finishFailure(error) }
        }
    }

    private func beginFallback() {
        guard !isRestoring, let tx = transaction, tx.phase == .needsFallback, discoveryID == nil,
              let model = tx.model, let spec = ModelDownloadSpec(model: model) else { return }
        let token = UUID()
        discoveryID = token
        discoveryModel = model
        Task {
            do {
                let tasks = await session.allTasks
                for task in tasks where task.taskDescription.flatMap(ModelDownloadFile.init(taskDescription:))?.attemptID == tx.id { task.cancel() }
                let manifest = try await Self.resolveHuggingFace(spec: spec)
                try stateQueue.sync {
                    guard discoveryID == token, transaction?.id == tx.id else { throw CancellationError() }
                    try checkStorage(manifest, spec: spec)
                    transaction?.useFallback(manifest)
                    running = [:]
                    taskBytes = [:]
                    try persist()
                    discoveryID = nil
                    do { try schedule() } catch { finishFailure(error) }
                    finishSystemEventsIfNeeded()
                }
            } catch {
                stateQueue.sync {
                    guard discoveryID == token else { return }
                    discoveryID = nil
                    // Keep needsFallback durable: the next foreground retry must
                    // resolve HF again, never resume mirror files as HF bytes.
                    if transaction?.manifest.source == .huggingFace {
                        finishFailure(error)
                    } else {
                        transaction?.failureMessage = ModelSetupFailure.describe(error).detail
                        try? persist()
                        notifyFailure(model: model, error: error)
                    }
                    finishSystemEventsIfNeeded()
                }
            }
        }
    }

    private func finishFailure(_ error: Error) {
        guard let tx = transaction, let model = tx.model else { return }
        transaction?.phase = .failed
        transaction?.failureMessage = ModelSetupFailure.describe(error).detail
        try? persist()
        running = [:]
        session.getAllTasks { tasks in
            for task in tasks where task.taskDescription.flatMap(ModelDownloadFile.init(taskDescription:))?.attemptID == tx.id { task.cancel() }
        }
        notifyFailure(model: model, error: error)
    }

    private func notifyFailure(model: LocalTranscriptionModel, error: Error) {
        let detail = error is ModelDownloadValidationError ? error.localizedDescription : ModelSetupFailure.describe(error).detail
        Task { @MainActor in self.delegate?.modelBackgroundDownloadDidFail(model: model, message: detail) }
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
        if let directory = storageDirectory(for: model) {
            let receipt = directory.appendingPathComponent(".muesli-verified-manifest.json")
            if FileManager.default.fileExists(atPath: receipt.path) {
                guard let data = try? Data(contentsOf: receipt),
                      let manifest = try? JSONDecoder().decode(ModelDownloadManifest.self, from: data),
                      let spec = ModelDownloadSpec(model: model),
                      (try? ModelDownloadManifest.validateCoverage(manifest.files, spec: spec)) != nil,
                      manifest.files.allSatisfy({ file in
                          let values = try? directory.appendingPathComponent(file.localPath).resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                          return values?.isRegularFile == true && Int64(values?.fileSize ?? -1) == file.size
                      }) else { return false }
            }
        }
        if let whisperVariant = model.whisperVariant {
            return WhisperKitTranscriptionRuntime.isModelDownloaded(whisperVariant)
        }

        guard let spec = ModelDownloadSpec(model: model) else { return false }
        return containsCompleteFluidAudioArtifacts(
            at: spec.repoRoot,
            modelNames: spec.requiredModels,
            supportingFiles: spec.requiredSupportingFiles
        )
    }

    static func supportsBackgroundDownload(_ model: LocalTranscriptionModel) -> Bool {
        ModelDownloadSpec(model: model) != nil
    }

    static func containsCompleteFluidAudioArtifacts(
        at root: URL,
        modelNames: Set<String>,
        supportingFiles: Set<String>
    ) -> Bool {
        let fileManager = FileManager.default
        let modelsAreComplete = modelNames.allSatisfy { modelName in
            let modelDirectory = root.appendingPathComponent(modelName, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: modelDirectory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else { return false }

            let coreMLData = modelDirectory.appendingPathComponent("coremldata.bin")
            guard let values = try? coreMLData.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else {
                return false
            }
            return values.isRegularFile == true && (values.fileSize ?? 0) > 0
        }
        guard modelsAreComplete else { return false }

        return supportingFiles.allSatisfy { fileName in
            let file = root.appendingPathComponent(fileName)
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else {
                return false
            }
            return values.isRegularFile == true && (values.fileSize ?? 0) > 0
        }
    }

    static func removeDownloadedModel(_ model: LocalTranscriptionModel) throws {
        guard let directory = storageDirectory(for: model) else { return }
        try shared.stateQueue.sync {
            guard shared.discoveryID == nil || shared.discoveryModel != model,
                  shared.transaction?.model != model || shared.transaction?.phase == .failed else {
                throw ModelDownloadValidationError.modelInUse
            }
            try removeDownloadedModel(at: directory)
            if shared.transaction?.model == model {
                shared.transaction = nil
                try shared.persist()
            }
        }
    }

    static func removeDownloadedModel(at directory: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.path) { try fm.removeItem(at: directory) }
        let prefix = ".\(directory.lastPathComponent).download-"
        let siblings = (try? fm.contentsOfDirectory(at: directory.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
        for sibling in siblings where sibling.lastPathComponent.hasPrefix(prefix)
            && UUID(uuidString: String(sibling.lastPathComponent.dropFirst(prefix.count))) != nil {
            try fm.removeItem(at: sibling)
        }
        let backup = ModelDownloadTransaction.backupDirectory(for: directory)
        if fm.fileExists(atPath: backup.path) { try fm.removeItem(at: backup) }
    }


    private static func finalizeDownloadedModel(_ model: LocalTranscriptionModel) throws {
        if let whisperVariant = model.whisperVariant {
            try WhisperKitTranscriptionRuntime.markDownloadComplete(
                at: WhisperKitTranscriptionRuntime.modelDirectory(for: whisperVariant)
            )
        }
        guard isModelDownloaded(model) else {
            throw ModelBackgroundDownloadError.incompleteDownload
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

struct ModelDownloadFile: Codable, Sendable {
    let remotePath: String
    let localPath: String
    let remoteURL: URL
    let size: Int64
    let model: LocalTranscriptionModel
    let attemptID: UUID?
    let sha256: String?
    let gitSHA1: String?

    init(
        remotePath: String,
        localPath: String,
        remoteURL: URL,
        size: Int64,
        model: LocalTranscriptionModel? = nil,
        attemptID: UUID? = nil,
        sha256: String? = nil,
        gitSHA1: String? = nil
    ) {
        self.remotePath = remotePath
        self.localPath = localPath
        self.remoteURL = remoteURL
        self.size = size
        self.model = model ?? .defaultModel
        self.attemptID = attemptID
        self.sha256 = sha256
        self.gitSHA1 = gitSHA1
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
        sha256 = nil
        gitSHA1 = nil
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

struct ModelDownloadSpec: Sendable {
    let model: LocalTranscriptionModel
    let remotePath: String
    let subPath: String?
    let requiredModels: Set<String>
    let requiredSupportingFiles: Set<String>
    let repoRoot: URL

    init?(model: LocalTranscriptionModel) {
        self.model = model
        let fluidAudioModelsRoot = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)

        switch model {
        case .parakeetUnified:
            remotePath = "FluidInference/parakeet-unified-en-0.6b-coreml"
            subPath = nil
            requiredModels = [
                "parakeet_unified_encoder_int8.mlmodelc",
                "parakeet_unified_decoder.mlmodelc",
                "parakeet_unified_joint_decision_single_step.mlmodelc",
            ]
            requiredSupportingFiles = ["vocab.json", "metadata.json"]
            repoRoot = fluidAudioModelsRoot.appendingPathComponent("parakeet-unified-en-0.6b-coreml", isDirectory: true)
        case .parakeetTdtCtc110m:
            remotePath = "FluidInference/parakeet-tdt-ctc-110m-coreml"
            subPath = nil
            requiredModels = [
                "Preprocessor.mlmodelc",
                "Decoder.mlmodelc",
                "JointDecision.mlmodelc"
            ]
            requiredSupportingFiles = ["parakeet_vocab.json"]
            repoRoot = fluidAudioModelsRoot.appendingPathComponent(
                "parakeet-tdt-ctc-110m",
                isDirectory: true
            )
        case .parakeetV3:
            remotePath = "FluidInference/parakeet-tdt-0.6b-v3-coreml"
            subPath = nil
            requiredModels = [
                "Preprocessor.mlmodelc",
                "Encoder.mlmodelc",
                "Decoder.mlmodelc",
                "JointDecisionv3.mlmodelc"
            ]
            requiredSupportingFiles = ["parakeet_vocab.json"]
            repoRoot = fluidAudioModelsRoot.appendingPathComponent(
                "parakeet-tdt-0.6b-v3-coreml",
                isDirectory: true
            )
        case .parakeetRealtimeEou120m:
            remotePath = "FluidInference/parakeet-realtime-eou-120m-coreml"
            subPath = "320ms"
            requiredModels = ModelNames.ParakeetEOU.requiredModels.filter { $0.hasSuffix(".mlmodelc") }
            requiredSupportingFiles = [ModelNames.ParakeetEOU.vocab]
            repoRoot = fluidAudioModelsRoot
                .appendingPathComponent("parakeet-eou-streaming", isDirectory: true)
                .appendingPathComponent("320ms", isDirectory: true)
        case .whisperTinyEnglish, .whisperSmallEnglish, .whisperMediumEnglish, .whisperLargeTurbo:
            guard let whisperVariant = model.whisperVariant else { return nil }
            let modelFolderName = whisperVariant.hasPrefix("openai_whisper-")
                ? whisperVariant
                : "openai_whisper-\(whisperVariant)"
            remotePath = "argmaxinc/whisperkit-coreml"
            subPath = modelFolderName
            requiredModels = [
                "MelSpectrogram.mlmodelc",
                "AudioEncoder.mlmodelc",
                "TextDecoder.mlmodelc",
            ]
            requiredSupportingFiles = ["config.json", "generation_config.json"]
            repoRoot = WhisperKitTranscriptionRuntime.modelDirectory(for: whisperVariant)
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
            || requiredSupportingFiles.contains(local)
            || local.hasSuffix(".json")
            || local.hasSuffix(".txt")
    }
}

private enum ModelBackgroundDownloadError: Error {
    case incompleteDownload
}
extension ModelBackgroundDownloadService: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        stateQueue.async {
            guard let file = downloadTask.taskDescription.flatMap(ModelDownloadFile.init(taskDescription:)),
                  self.transaction?.accepts(file) == true else { return }
            self.taskBytes[file.localPath] = totalBytesWritten
            self.publishProgress()
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do { try completeTask(downloadTask, location: location) }
        catch { fail(downloadTask, error: error) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { fail(task, error: error) }
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        stateQueue.async {
            self.backgroundEventsFinished = true
            self.finishSystemEventsIfNeeded()
        }
    }
}

extension ModelBackgroundDownloadService {
    private static func resolveManifest(spec: ModelDownloadSpec) async throws -> ModelDownloadManifest {
        if let url = ModelDownloadManifest.mirrorURL(for: spec.model) {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                try Task.checkCancellation()
                guard let response = response as? HTTPURLResponse,
                      (200..<300).contains(response.statusCode), response.url == url else { throw ModelDownloadValidationError.badResponse }
                let manifest = try ModelDownloadManifest.decodeMirror(data, url: url, spec: spec)
                #if DEBUG
                return ModelDownloadDeviceValidation.applyingFaultIfRequested(manifest)
                #else
                return manifest
                #endif
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
            }
        }
        return try await resolveHuggingFace(spec: spec)
    }

    private static func resolveHuggingFace(spec: ModelDownloadSpec) async throws -> ModelDownloadManifest {
        // Pin discovery and file downloads to the same immutable HF revision.
        let infoURL = URL(string: "https://huggingface.co/api/models/\(spec.remotePath)/revision/main")!
        let (infoData, infoResponse) = try await URLSession.shared.data(from: infoURL)
        try Task.checkCancellation()
        guard let http = infoResponse as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let info = try JSONSerialization.jsonObject(with: infoData) as? [String: Any],
              let revision = info["sha"] as? String,
              revision.count == 40, revision.allSatisfy(\.isHexDigit) else { throw ModelDownloadValidationError.invalidManifest }
        let subpath = spec.subPath.map { "/" + $0 } ?? ""
        var next: URL? = URL(string: "https://huggingface.co/api/models/\(spec.remotePath)/tree/\(revision)\(subpath)?recursive=true&expand=false")
        var visited = Set<URL>()
        var files: [ModelDownloadFile] = []
        while let url = next {
            guard url.scheme == "https", url.host == "huggingface.co",
                  url.path.hasPrefix("/api/models/\(spec.remotePath)/tree/\(revision)"),
                  visited.insert(url).inserted else { throw ModelDownloadValidationError.invalidManifest }
            let (data, response) = try await URLSession.shared.data(from: url)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw ModelDownloadValidationError.badResponse }
            for item in items {
                guard item["type"] as? String == "file", let path = item["path"] as? String,
                      spec.shouldDownloadFile(path) else { continue }
                let local = spec.localPath(forRemotePath: path)
                guard ModelDownloadManifest.safePath(local), ModelDownloadManifest.safePath(path),
                      let size = (item["size"] as? NSNumber)?.int64Value, size >= 0 else { throw ModelDownloadValidationError.invalidManifest }
                let lfs = item["lfs"] as? [String: Any]
                let sha256 = lfs?["oid"] as? String
                let gitSHA1 = lfs == nil ? item["oid"] as? String : nil
                guard sha256.map(ModelDownloadManifest.validSHA256) == true
                    || (gitSHA1?.count == 40 && gitSHA1?.allSatisfy(\.isHexDigit) == true) else { throw ModelDownloadValidationError.invalidManifest }
                var components = URLComponents(string: "https://huggingface.co")!
                components.path = "/\(spec.remotePath)/resolve/\(revision)/\(path)"
                guard let remoteURL = components.url else { throw ModelDownloadValidationError.invalidManifest }
                files.append(ModelDownloadFile(remotePath: path, localPath: local, remoteURL: remoteURL,
                    size: size, model: spec.model, sha256: sha256, gitSHA1: gitSHA1))
            }
            next = nil
            if let links = http.value(forHTTPHeaderField: "Link") {
                for link in links.components(separatedBy: ",") where link.contains("rel=\"next\"") {
                    guard let start = link.firstIndex(of: "<"), let end = link.firstIndex(of: ">"), start < end,
                          let url = URL(string: String(link[link.index(after: start)..<end])) else { throw ModelDownloadValidationError.invalidManifest }
                    next = url
                }
            }
        }
        try ModelDownloadManifest.validateCoverage(files, spec: spec)
        return .init(source: .huggingFace, version: revision, files: files)
    }
}
