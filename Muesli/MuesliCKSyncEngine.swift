import CloudKit
import CryptoKit
import Foundation
import OSLog

/// Minimal pending-state surface used by the engine and deterministic tests.
protocol MuesliCKSyncPendingState: AnyObject, Sendable {
    var pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange] { get }
    func add(pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange])
    func remove(pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange])
}

extension CKSyncEngine.State: MuesliCKSyncPendingState {}

struct MuesliCKSyncIntent: OptionSet, Equatable, Sendable {
    let rawValue: UInt8

    static let send = Self(rawValue: 1 << 0)
    static let fetch = Self(rawValue: 1 << 1)
    static let manual: Self = [.send, .fetch]
}

enum MuesliCKSyncOperation: Equatable, Sendable {
    case send
    case fetch
}

/// One cross-platform operation contract: outgoing first, incoming second.
enum MuesliCKSyncPlan {
    static func operations(for intent: MuesliCKSyncIntent) -> [MuesliCKSyncOperation] {
        var operations: [MuesliCKSyncOperation] = []
        if intent.contains(.send) { operations.append(.send) }
        if intent.contains(.fetch) { operations.append(.fetch) }
        return operations
    }
}

enum MuesliCKSyncLaunchPolicy {
    static func shouldPrepare(syncEnabled: Bool) -> Bool { syncEnabled }
}

struct MuesliCKSyncIntentAccumulator: Equatable, Sendable {
    private(set) var pending: MuesliCKSyncIntent = []

    mutating func insert(_ intent: MuesliCKSyncIntent) {
        pending.formUnion(intent)
    }

    mutating func take() -> MuesliCKSyncIntent {
        let value = pending
        pending = []
        return value
    }
}

/// Coalesces one-time/account/zone/migration preparation across concurrent triggers.
actor MuesliCKSyncPreparationGate {
    private var isPrepared = false
    private var inFlight: Task<Bool, Error>?
    private var generation = 0

    func prepare(
        using operation: @escaping @Sendable () async throws -> Bool
    ) async throws -> Bool {
        if isPrepared { return false }
        let observedGeneration = generation
        if let inFlight {
            let value = try await inFlight.value
            guard observedGeneration == generation else { throw CancellationError() }
            return value
        }

        let task = Task { try await operation() }
        inFlight = task
        do {
            let zoneWasRecreated = try await task.value
            guard observedGeneration == generation else { throw CancellationError() }
            isPrepared = true
            inFlight = nil
            return zoneWasRecreated
        } catch {
            if observedGeneration == generation {
                inFlight = nil
            }
            throw error
        }
    }

    func invalidate() {
        generation += 1
        inFlight?.cancel()
        inFlight = nil
        isPrepared = false
    }
}

/// Drains outgoing pages and stops when CloudKit makes no progress.
enum MuesliCKSyncCycle {
    static func sendLocalChanges(
        maximumUploadBatches: Int,
        isolation: isolated (any Actor)? = #isolation,
        registerNextBatch: () async throws -> Int,
        uploadedCount: () async -> Int,
        send: () async throws -> Void
    ) async throws {
        for _ in 0..<max(maximumUploadBatches, 0) {
            let registered = try await registerNextBatch()
            guard registered > 0 else { break }
            let uploadedBeforeSend = await uploadedCount()
            try await send()
            guard await uploadedCount() > uploadedBeforeSend else { break }
        }
    }
}

/// Applies one bounded zone-recreation retry and makes every preparation
/// invalidation explicit. Keeping the policy outside the CloudKit actor makes
/// second-attempt failures deterministic to exercise in tests.
enum MuesliCKSyncRecoveryRunner {
    static func run<Value>(
        isolation: isolated (any Actor)? = #isolation,
        operation: () async throws -> Value,
        isZoneMissing: (any Error) -> Bool,
        invalidatesPreparation: (any Error) -> Bool,
        invalidate: (any Error) async -> Void
    ) async throws -> Value {
        do {
            return try await operation()
        } catch {
            guard isZoneMissing(error) else {
                if invalidatesPreparation(error) {
                    await invalidate(error)
                }
                throw error
            }

            await invalidate(error)
            do {
                return try await operation()
            } catch {
                // A successful retry may prepare a fresh engine before its
                // send/fetch discovers another zone or account-context error.
                // Retire that preparation too instead of publishing it as ready.
                if invalidatesPreparation(error) {
                    await invalidate(error)
                }
                throw error
            }
        }
    }
}

/// Send failure normalized away from CKSyncEngine event wrappers.
struct MuesliCKSyncFailedRecordSave: Sendable {
    let record: CKRecord
    let error: CKError
}

/// Locally materialized records and obsolete pending saves found in one read.
struct MuesliCKSyncRecordBatch: Sendable {
    let recordsToSave: [CKRecord]
    let staleChanges: [CKSyncEngine.PendingRecordZoneChange]
}

/// Safety errors that require an account or user action before sync resumes.
enum MuesliCKSyncError: LocalizedError {
    case accountChanged

    var errorDescription: String? {
        switch self {
        case .accountChanged:
            "iCloud sync is paused because this Muesli library belongs to a different iCloud account."
        }
    }
}

/// Privacy-safe progress phases exposed to diagnostics and the settings UI.
enum MuesliCKSyncProgress: Equatable, Sendable {
    case preparing
    case fetching
    case downloading(Int)
    case uploading(Int)

    var diagnosticValue: String {
        switch self {
        case .preparing:
            "preparing"
        case .fetching:
            "fetching"
        case .downloading:
            "downloading"
        case .uploading:
            "uploading"
        }
    }
}

extension Notification.Name {
    static let muesliCKSyncRemoteChanges = Notification.Name("muesli.cksync.remote-changes")
    static let muesliCKSyncProgress = Notification.Name("muesli.cksync.progress")
}

enum MuesliCKSyncNotificationKey {
    static let progress = "progress"
}

/// Process-wide owner for the persistent engine and merged trigger intent.
///
/// App launch, foregrounding, APNs, local commits, and manual refresh can race.
/// The runtime unions their requested directions and drains them through one
/// engine so no trigger overwrites another while a network operation is active.
actor MuesliCKSyncRuntime {
    static let shared = MuesliCKSyncRuntime()

    typealias ExecuteIntent = @Sendable (
        MuesliCKSyncIntent
    ) async throws -> ICloudTextSyncResult

    private let prepareEngine: @Sendable () async throws -> Void
    private let executeIntent: ExecuteIntent
    private let refreshBridge: @Sendable (Bool) async -> Void
    private let cancelEngine: @Sendable () async -> Void
    private struct Waiter {
        let generation: Int
        let continuation: CheckedContinuation<ICloudTextSyncResult, any Error>
    }
    private var intents = MuesliCKSyncIntentAccumulator()
    private var waiters: [Waiter] = []
    private var isRunning = false
    private var generation = 0

    init(engine: MuesliCKSyncEngine? = nil) {
        let resolvedEngine = engine ?? MuesliCKSyncEngine(
            onRemoteChanges: {
                await MainActor.run {
                    NotificationCenter.default.post(name: .muesliCKSyncRemoteChanges, object: nil)
                }
            },
            onProgress: { progress in
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .muesliCKSyncProgress,
                        object: nil,
                        userInfo: [MuesliCKSyncNotificationKey.progress: progress]
                    )
                }
            }
        )
        prepareEngine = { _ = try await resolvedEngine.prepare() }
        executeIntent = { intent in
            if intent == .manual {
                return try await resolvedEngine.syncManually()
            } else if intent == .send {
                return try await resolvedEngine.sendLocalChanges()
            } else {
                return try await resolvedEngine.fetchRemoteChanges()
            }
        }
        refreshBridge = { forceRefresh in
            await resolvedEngine.refreshBridgeDevice(forceRefresh: forceRefresh)
        }
        cancelEngine = { await resolvedEngine.cancel() }
    }

    /// Test seam for request ownership and cancellation without CloudKit I/O.
    init(
        prepare: @escaping @Sendable () async throws -> Void = {},
        execute: @escaping ExecuteIntent,
        refreshBridge: @escaping @Sendable (Bool) async -> Void = { _ in },
        cancel: @escaping @Sendable () async -> Void = {}
    ) {
        prepareEngine = prepare
        executeIntent = execute
        self.refreshBridge = refreshBridge
        cancelEngine = cancel
    }

    func prepare() async throws {
        try await prepareEngine()
    }

    func sendLocalChanges() async throws -> ICloudTextSyncResult {
        try await enqueue(.send)
    }

    func fetchRemoteChanges() async throws -> ICloudTextSyncResult {
        try await enqueue(.fetch)
    }

    func syncManually() async throws -> ICloudTextSyncResult {
        try await enqueue(.manual)
    }

    func refreshBridgeDevice(forceRefresh: Bool) async {
        await refreshBridge(forceRefresh)
    }

    func cancel() async {
        generation += 1
        _ = intents.take()
        let cancelledWaiters = waiters
        waiters.removeAll()
        isRunning = false
        // Release APNs/UI callers before CloudKit cancellation. This guarantees
        // the background fetch completion path cannot wait on cancellation I/O.
        cancelledWaiters.forEach { $0.continuation.resume(throwing: CancellationError()) }
        await cancelEngine()
    }

    private func enqueue(
        _ intent: MuesliCKSyncIntent
    ) async throws -> ICloudTextSyncResult {
        try await withCheckedThrowingContinuation { continuation in
            intents.insert(intent)
            waiters.append(Waiter(generation: generation, continuation: continuation))
            guard !isRunning else { return }
            isRunning = true
            let drainGeneration = generation
            Task { await self.drain(generation: drainGeneration) }
        }
    }

    private func drain(generation drainGeneration: Int) async {
        var totalUploaded = 0
        var totalDownloaded = 0
        do {
            while drainGeneration == generation, !intents.pending.isEmpty {
                let intent = intents.take()
                let result = try await executeIntent(intent)
                totalUploaded += result.uploaded
                totalDownloaded += result.downloaded
            }
            guard drainGeneration == generation else { return }
            completeWaiters(generation: drainGeneration, with: .success(ICloudTextSyncResult(
                uploaded: totalUploaded,
                downloaded: totalDownloaded
            )))
        } catch {
            guard drainGeneration == generation else { return }
            // Every current-generation waiter receives this failure, so discard
            // their merged intent too. A later trigger must not replay stale work
            // after the callers that requested it have already been released.
            _ = intents.take()
            completeWaiters(generation: drainGeneration, with: .failure(error))
        }
    }

    func pendingIntentForTesting() -> MuesliCKSyncIntent {
        intents.pending
    }

    private func completeWaiters(
        generation completedGeneration: Int,
        with result: Result<ICloudTextSyncResult, any Error>
    ) {
        let completedWaiters = waiters.filter { $0.generation == completedGeneration }
        waiters.removeAll { $0.generation == completedGeneration }
        guard completedGeneration == generation else { return }
        isRunning = false
        for waiter in completedWaiters {
            switch result {
            case .success(let value): waiter.continuation.resume(returning: value)
            case .failure(let error): waiter.continuation.resume(throwing: error)
            }
        }
    }
}

/// Owns the one CKSyncEngine instance for the private text-record zone.
///
/// SQLite's `sync_dirty` flags remain the durable outbox. Before every send,
/// dirty rows are rediscovered and registered by stable CloudKit record ID, so
/// a crash between a local edit and CKSyncEngine state serialization loses no work.
actor MuesliCKSyncEngine: CKSyncEngineDelegate {
    static var stateKey: String {
        "cksyncengine.private.MuesliSyncZone.\(ICloudTextSyncEngine.cloudSyncStateKeyComponent).v1"
    }

    static var accountScopeKey: String {
        "cksyncengine.private.MuesliSyncZone.\(ICloudTextSyncEngine.cloudSyncStateKeyComponent).account-owner.v1"
    }

    private static let subscriptionID = "muesli-ios-cksyncengine-private-v1"
    private static let uploadBatchSize = 200
    private static let maximumUploadBatchesPerSync = 50
    private static let logger = Logger(
        subsystem: "com.mueslihq.muesli",
        category: "cksyncengine"
    )
    private static var dictationTimingRepairKey: String {
        "cksyncengine.dictation-timing-repair.\(ICloudTextSyncEngine.cloudSyncStateKeyComponent).v1"
    }

    private let store: SharedStore
    private let onRemoteChanges: @Sendable () async -> Void
    private let onProgress: @Sendable (MuesliCKSyncProgress) async -> Void
    private let legacyAccountRecordVerifier: (@Sendable (Set<String>) async throws -> Bool)?
    private let preparationGate = MuesliCKSyncPreparationGate()
    private var container: CKContainer?
    private var preflight: ICloudTextSyncEngine?
    private var engine: CKSyncEngine?
    private var conflictBaseRecords: [CKRecord.ID: CKRecord] = [:]
    private var uploaded = 0
    private var downloaded = 0
    private var accountBoundaryBlocked = true

    init(
        store: SharedStore = SharedStore(),
        container: CKContainer? = nil,
        onRemoteChanges: @escaping @Sendable () async -> Void = {},
        onProgress: @escaping @Sendable (MuesliCKSyncProgress) async -> Void = { _ in },
        legacyAccountRecordVerifier: (@Sendable (Set<String>) async throws -> Bool)? = nil
    ) {
        self.store = store
        self.container = container
        self.onRemoteChanges = onRemoteChanges
        self.onProgress = onProgress
        self.legacyAccountRecordVerifier = legacyAccountRecordVerifier
    }

    /// Initializes the persistent engine and performs account/zone/migration work once.
    @discardableResult
    func prepare() async throws -> Bool {
        let zoneWasRecreated = try await preparationGate.prepare { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.performPreparation()
        }
        _ = try makeEngineIfNeeded()
        return zoneWasRecreated
    }

    /// Registers SQLite's durable outbox and sends it without a fetch-first round trip.
    func sendLocalChanges() async throws -> ICloudTextSyncResult {
        try await runWithZoneRecovery(intent: .send)
    }

    /// Fetches incoming zone changes without scanning or sending the local outbox.
    func fetchRemoteChanges() async throws -> ICloudTextSyncResult {
        try await runWithZoneRecovery(intent: .fetch)
    }

    /// User-requested convergence: flush outgoing work first, then fetch incoming work.
    func syncManually() async throws -> ICloudTextSyncResult {
        try await runWithZoneRecovery(intent: .manual)
    }

    private func runWithZoneRecovery(
        intent: MuesliCKSyncIntent
    ) async throws -> ICloudTextSyncResult {
        try await MuesliCKSyncRecoveryRunner.run(
            operation: { try await self.run(intent: intent) },
            isZoneMissing: ICloudTextSyncEngine.isSyncZoneMissing,
            invalidatesPreparation: Self.invalidatesPreparation,
            invalidate: { error in
                let zoneIsMissing = ICloudTextSyncEngine.isSyncZoneMissing(error)
                // Zone loss must also retire serialized CKSyncEngine state;
                // account-context failures only retire cached preparation so
                // the next attempt proves the account boundary again.
                await self.invalidatePreparation(
                    cancelEngine: zoneIsMissing,
                    clearEngineState: zoneIsMissing
                )
            }
        )
    }

    private func run(intent: MuesliCKSyncIntent) async throws -> ICloudTextSyncResult {
        uploaded = 0
        downloaded = 0

        await reportProgress(.preparing)
        _ = try await prepare()
        let syncEngine = try makeEngineIfNeeded()

        for operation in MuesliCKSyncPlan.operations(for: intent) {
            switch operation {
            case .send:
                await reportProgress(.uploading(uploaded))
                try await MuesliCKSyncCycle.sendLocalChanges(
                    maximumUploadBatches: Self.maximumUploadBatchesPerSync,
                    registerNextBatch: {
                        try self.registerNextDirtyBatch(state: syncEngine.state)
                    },
                    uploadedCount: { self.uploaded },
                    send: {
                        let options = CKSyncEngine.SendChangesOptions(
                            scope: .zoneIDs([ICloudTextSyncEngine.Schema.syncZoneID])
                        )
                        try await syncEngine.sendChanges(options)
                    }
                )

            case .fetch:
                await reportProgress(.fetching)
                let options = CKSyncEngine.FetchChangesOptions(
                    scope: .zoneIDs([ICloudTextSyncEngine.Schema.syncZoneID])
                )
                try await syncEngine.fetchChanges(options)
            }
        }

        return ICloudTextSyncResult(uploaded: uploaded, downloaded: downloaded)
    }

    private func reportProgress(_ progress: MuesliCKSyncProgress) async {
        // Phase and count only: never include record IDs or authored text.
        let count: Int?
        switch progress {
        case .downloading(let value), .uploading(let value):
            count = value
        case .preparing, .fetching:
            count = nil
        }
        if let count {
            Self.logger.debug(
                "phase=\(progress.diagnosticValue, privacy: .public) count=\(count, privacy: .public)"
            )
        } else {
            Self.logger.debug("phase=\(progress.diagnosticValue, privacy: .public)")
        }
        await onProgress(progress)
    }

    /// Cancels outstanding CloudKit operations and discards the live engine.
    func cancel() async {
        await invalidatePreparation(cancelEngine: true, clearEngineState: false)
    }

    /// Companion presence is ancillary UI state and never blocks text transport.
    func refreshBridgeDevice(forceRefresh: Bool = false) async {
        await resolvedPreflight().refreshBridgeDeviceLinkIfNeeded(forceRefresh: forceRefresh)
    }

    private func performPreparation() async throws -> Bool {
        let preflight = resolvedPreflight()
        let currentUser = try await resolvedContainer().userRecordID()
        guard try await authorizeAccount(currentUser, preflight: preflight) else {
            if let engine {
                engine.state.remove(
                    pendingRecordZoneChanges: engine.state.pendingRecordZoneChanges
                )
            }
            try store.clearCloudSyncStateData(forKey: Self.stateKey)
            throw MuesliCKSyncError.accountChanged
        }

        let syncZoneWasRecreated = try await preflight.prepareForCKSyncEngine(store: store)
        if syncZoneWasRecreated {
            let engineToCancel = engine
            engine = nil
            await engineToCancel?.cancelOperations()
            try store.clearCloudSyncStateData(forKey: Self.stateKey)
        }
        let syncEngine = try makeEngineIfNeeded()
        let repaired = try store.requeueDictationsWithRecoverableTimingIfNeeded(
            repairKey: Self.dictationTimingRepairKey
        )
        if repaired > 0 {
            _ = try registerNextDirtyBatch(state: syncEngine.state)
        }
        return syncZoneWasRecreated
    }

    private func invalidatePreparation(
        cancelEngine: Bool,
        clearEngineState: Bool
    ) async {
        await preparationGate.invalidate()
        guard cancelEngine else { return }
        let engineToCancel = engine
        engine = nil
        await engineToCancel?.cancelOperations()
        if clearEngineState {
            try? store.clearCloudSyncStateData(forKey: Self.stateKey)
        }
    }

    static func invalidatesPreparation(_ error: Error) -> Bool {
        ICloudTextSyncEngine.isSyncZoneMissing(error)
            || ICloudTextSyncEngine.containsCloudKitError(
                error,
                codes: [.notAuthenticated, .permissionFailure]
            )
    }

    private func makeEngineIfNeeded() throws -> CKSyncEngine {
        if let engine { return engine }

        let serialization: CKSyncEngine.State.Serialization?
        if let data = try store.cloudSyncStateData(forKey: Self.stateKey) {
            do {
                serialization = try PropertyListDecoder().decode(
                    CKSyncEngine.State.Serialization.self,
                    from: data
                )
            } catch {
                // A corrupt cursor is recoverable. Starting with nil performs a
                // full private-database replay while every local row stays intact.
                try store.clearCloudSyncStateData(forKey: Self.stateKey)
                serialization = nil
            }
        } else {
            serialization = nil
        }

        var configuration = CKSyncEngine.Configuration(
            database: resolvedContainer().privateCloudDatabase,
            stateSerialization: serialization,
            delegate: self
        )
        configuration.automaticallySync = true
        configuration.subscriptionID = Self.subscriptionID
        let created = CKSyncEngine(configuration)
        engine = created
        return created
    }

    private func resolvedContainer() -> CKContainer {
        if let container { return container }
        let created = CKContainer(identifier: ICloudTextSyncEngine.Schema.containerIdentifier)
        container = created
        return created
    }

    private func resolvedPreflight() -> ICloudTextSyncEngine {
        if let preflight { return preflight }
        let created = ICloudTextSyncEngine(container: resolvedContainer())
        preflight = created
        return created
    }

    /// Registers one bounded page of SQLite outbox rows with CKSyncEngine.
    func registerNextDirtyBatch(state: any MuesliCKSyncPendingState) throws -> Int {
        guard !accountBoundaryBlocked else { return 0 }
        let dirtyRecords = try store.textRecordsNeedingSync(limit: Self.uploadBatchSize)
        guard !dirtyRecords.isEmpty else { return 0 }

        let alreadyPending = Set(state.pendingRecordZoneChanges.compactMap { change -> CKRecord.ID? in
            guard case .saveRecord(let recordID) = change else { return nil }
            return recordID
        })
        let additions = dirtyRecords.compactMap { record -> CKSyncEngine.PendingRecordZoneChange? in
            let recordID = CKRecord.ID(
                recordName: record.id,
                zoneID: ICloudTextSyncEngine.Schema.syncZoneID
            )
            guard !alreadyPending.contains(recordID) else { return nil }
            return .saveRecord(recordID)
        }
        state.add(pendingRecordZoneChanges: additions)
        return dirtyRecords.count
    }

    /// Supplies CloudKit with a size-aware batch backed by one SQLite page read.
    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard !accountBoundaryBlocked else { return nil }
        let pending = syncEngine.state.pendingRecordZoneChanges.filter {
            context.options.scope.contains($0)
        }
        let batch = makeRecordBatch(pendingChanges: pending)
        if !batch.staleChanges.isEmpty {
            syncEngine.state.remove(pendingRecordZoneChanges: batch.staleChanges)
        }
        guard !batch.recordsToSave.isEmpty else { return nil }
        let recordsByID = Dictionary(
            uniqueKeysWithValues: batch.recordsToSave.map { ($0.recordID, $0) }
        )
        let saveChanges = batch.recordsToSave.map {
            CKSyncEngine.PendingRecordZoneChange.saveRecord($0.recordID)
        }
        return await CKSyncEngine.RecordZoneChangeBatch(
            pendingChanges: saveChanges,
            recordProvider: { recordsByID[$0] }
        )
    }

    /// Materializes the latest local version for each pending record save.
    func makeRecordBatch(
        pendingChanges: [CKSyncEngine.PendingRecordZoneChange]
    ) -> MuesliCKSyncRecordBatch {
        makeRecordBatch(
            pendingChanges: pendingChanges,
            loadRecords: { try store.textRecordsForSync(recordNames: $0) }
        )
    }

    func makeRecordBatch(
        pendingChanges: [CKSyncEngine.PendingRecordZoneChange],
        loadRecords: ([String]) throws -> [String: SyncTextRecord]
    ) -> MuesliCKSyncRecordBatch {
        let relevantChanges: [(CKSyncEngine.PendingRecordZoneChange, CKRecord.ID)] =
            pendingChanges.compactMap { change in
                guard case .saveRecord(let recordID) = change,
                      recordID.zoneID == ICloudTextSyncEngine.Schema.syncZoneID else {
                    return nil
                }
                return (change, recordID)
            }

        let localRecords: [String: SyncTextRecord]
        do {
            localRecords = try loadRecords(relevantChanges.map { $0.1.recordName })
        } catch {
            // Keep pending saves intact on transient SQLite failures. Diagnostics
            // contain only the error category, never record IDs or authored text.
            Self.logger.error(
                "local_batch_read_failed error_type=\(String(describing: type(of: error)), privacy: .public)"
            )
            return MuesliCKSyncRecordBatch(recordsToSave: [], staleChanges: [])
        }

        var recordsToSave: [CKRecord] = []
        var staleChanges: [CKSyncEngine.PendingRecordZoneChange] = []
        for (change, recordID) in relevantChanges {
            guard let localRecord = localRecords[recordID.recordName] else {
                staleChanges.append(change)
                continue
            }
            recordsToSave.append(ICloudTextSyncEngine.syncZoneCloudRecord(
                from: localRecord,
                baseRecord: conflictBaseRecords[recordID]
            ))
        }
        return MuesliCKSyncRecordBatch(
            recordsToSave: recordsToSave,
            staleChanges: staleChanges
        )
    }

    /// Persists engine state and reconciles CloudKit events with SQLite.
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        do {
            switch event {
            case .stateUpdate(let update):
                let data = try PropertyListEncoder().encode(update.stateSerialization)
                try store.saveCloudSyncStateData(data, forKey: Self.stateKey)

            case .fetchedRecordZoneChanges(let changes):
                guard !accountBoundaryBlocked else { break }
                let applied = try handleFetchedRecords(
                    changes.modifications.map(\.record),
                    state: syncEngine.state
                )
                if applied > 0 {
                    await reportProgress(.downloading(downloaded))
                    await onRemoteChanges()
                }
                // Muesli represents deletion as a saved tombstone. Hard-delete
                // notifications are intentionally ignored by this record contract.

            case .sentRecordZoneChanges(let changes):
                guard !accountBoundaryBlocked else { break }
                try handleSentRecordChanges(
                    savedRecords: changes.savedRecords,
                    failedRecordSaves: changes.failedRecordSaves.map {
                        MuesliCKSyncFailedRecordSave(record: $0.record, error: $0.error)
                    },
                    state: syncEngine.state
                )
                await reportProgress(.uploading(uploaded))

            case .accountChange(let change):
                conflictBaseRecords.removeAll()
                switch change.changeType {
                case .signIn(let currentUser):
                    _ = try await handleAccountChange(
                        currentUser: currentUser,
                        state: syncEngine.state
                    )
                case .switchAccounts(_, let currentUser):
                    _ = try await handleAccountChange(
                        currentUser: currentUser,
                        state: syncEngine.state
                    )
                case .signOut:
                    _ = try await handleAccountChange(
                        currentUser: nil,
                        state: syncEngine.state
                    )
                @unknown default:
                    break
                }

            case .fetchedDatabaseChanges,
                 .sentDatabaseChanges,
                 .willFetchChanges,
                 .willFetchRecordZoneChanges,
                 .didFetchRecordZoneChanges,
                 .didFetchChanges,
                 .willSendChanges,
                 .didSendChanges:
                break

            @unknown default:
                break
            }
        } catch {
            Self.logger.error(
                "event_failed error_type=\(String(describing: type(of: error)), privacy: .public)"
            )
        }
    }

    @discardableResult
    /// Applies fetched text records while preserving newer dirty local edits.
    func handleFetchedRecords(
        _ cloudRecords: [CKRecord],
        state: any MuesliCKSyncPendingState
    ) throws -> Int {
        let records = cloudRecords
            .filter {
                $0.recordID.zoneID == ICloudTextSyncEngine.Schema.syncZoneID
                    && $0.recordType == ICloudTextSyncEngine.Schema.textRecordType
            }
            .compactMap(ICloudTextSyncEngine.syncTextRecord(from:))
        let appliedRecordIDs = Set(try store.upsertSyncedTextRecords(records).map(\.id))
        for record in records {
            if !appliedRecordIDs.contains(record.id) {
                try store.updateTextRecordCloudMetadata(
                    kind: record.kind,
                    recordName: record.id,
                    changeTag: record.cloudChangeTag,
                    systemFields: record.cloudSystemFields
                )
                continue
            }
            downloaded += 1
            state.remove(pendingRecordZoneChanges: [
                .saveRecord(CKRecord.ID(
                    recordName: record.id,
                    zoneID: ICloudTextSyncEngine.Schema.syncZoneID
                )),
            ])
        }
        return appliedRecordIDs.count
    }

    /// Acknowledges exact uploaded versions and retains retryable failures.
    func handleSentRecordChanges(
        savedRecords: [CKRecord],
        failedRecordSaves: [MuesliCKSyncFailedRecordSave],
        state: any MuesliCKSyncPendingState
    ) throws {
        for savedRecord in savedRecords {
            guard let syncRecord = ICloudTextSyncEngine.syncTextRecord(from: savedRecord) else { continue }
            if try store.markTextRecordSynced(
                kind: syncRecord.kind,
                recordName: syncRecord.id,
                changeTag: savedRecord.recordChangeTag,
                systemFields: ICloudTextSyncEngine.encodedSystemFields(for: savedRecord),
                recordUpdatedAt: syncRecord.updatedAt
            ) {
                uploaded += 1
            }
            state.remove(pendingRecordZoneChanges: [.saveRecord(savedRecord.recordID)])
            conflictBaseRecords[savedRecord.recordID] = nil
        }

        for failure in failedRecordSaves {
            let recordID = failure.record.recordID
            guard recordID.zoneID == ICloudTextSyncEngine.Schema.syncZoneID else { continue }
            let pending = CKSyncEngine.PendingRecordZoneChange.saveRecord(recordID)

            if failure.error.code == .serverRecordChanged,
               let serverRecord = failure.error.serverRecord,
               let remote = ICloudTextSyncEngine.syncTextRecord(from: serverRecord),
               let local = try store.textRecordsForSync(recordNames: [recordID.recordName])[recordID.recordName] {
                if remote.updatedAt > local.updatedAt {
                    _ = try store.upsertSyncedTextRecord(remote)
                    state.remove(pendingRecordZoneChanges: [pending])
                } else {
                    conflictBaseRecords[recordID] = serverRecord
                    state.add(pendingRecordZoneChanges: [pending])
                }
            } else {
                // CKSyncEngine owns retry timing/backoff; SQLite keeps the save
                // discoverable even if engine state is later reconstructed.
                state.add(pendingRecordZoneChanges: [pending])
            }
        }
    }

    /// Applies an account event without ever migrating local text across accounts.
    @discardableResult
    func handleAccountChange(
        currentUser: CKRecord.ID?,
        state: any MuesliCKSyncPendingState
    ) async throws -> Bool {
        // This runs inside CKSyncEngine's own delegate callback. Cancelling the
        // same engine here is re-entrant and CloudKit deliberately traps. Keep
        // live engine inert; discard account-specific pending work and state.
        state.remove(pendingRecordZoneChanges: state.pendingRecordZoneChanges)
        try store.clearCloudSyncStateData(forKey: Self.stateKey)
        conflictBaseRecords.removeAll()
        await preparationGate.invalidate()
        guard let currentUser else {
            accountBoundaryBlocked = true
            return false
        }

        guard try await authorizeAccount(currentUser) else { return false }
        _ = try registerNextDirtyBatch(state: state)
        return true
    }

    /// Hashes the per-container user ID before it reaches local persistence.
    static func accountScope(for userRecordID: CKRecord.ID) -> String {
        let digest = SHA256.hash(data: Data(userRecordID.recordName.utf8))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private func authorizeAccount(
        _ userRecordID: CKRecord.ID,
        preflight: ICloudTextSyncEngine? = nil
    ) async throws -> Bool {
        accountBoundaryBlocked = true
        let requestedScope = Self.accountScope(for: userRecordID)

        if let persistedScope = try store.cloudSyncStateData(forKey: Self.accountScopeKey) {
            let matches = persistedScope == Data(requestedScope.utf8)
            accountBoundaryBlocked = !matches
            if !matches {
                Self.logger.error("account_boundary_blocked")
            }
            return matches
        }

        let legacyRecordNames = try store.textRecordNamesRequiringAccountVerification()
        if !legacyRecordNames.isEmpty {
            let verified: Bool
            if let legacyAccountRecordVerifier {
                verified = try await legacyAccountRecordVerifier(legacyRecordNames)
            } else {
                verified = try await (preflight ?? resolvedPreflight()).syncZoneContainsAnyTextRecord(
                    named: legacyRecordNames
                )
            }
            guard verified else {
                Self.logger.error("account_provenance_unverified")
                return false
            }
        }

        let matches = try store.claimCloudSyncAccountScope(
            requestedScope,
            forKey: Self.accountScopeKey
        )
        accountBoundaryBlocked = !matches
        if !matches {
            Self.logger.error("account_boundary_blocked")
        }
        return matches
    }
}
