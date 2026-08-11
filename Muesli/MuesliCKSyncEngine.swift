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

/// Runs fetch-first sync and stops upload paging when CloudKit makes no progress.
enum MuesliCKSyncCycle {
    static func run(
        maximumUploadBatches: Int,
        isolation: isolated (any Actor)? = #isolation,
        fetch: () async throws -> Void,
        registerNextBatch: () async throws -> Int,
        uploadedCount: () async -> Int,
        send: () async throws -> Void
    ) async throws {
        try await fetch()

        for _ in 0..<max(maximumUploadBatches, 0) {
            let registered = try await registerNextBatch()
            guard registered > 0 else { break }
            let uploadedBeforeSend = await uploadedCount()
            try await send()
            guard await uploadedCount() > uploadedBeforeSend else { break }
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
        onProgress: @escaping @Sendable (MuesliCKSyncProgress) async -> Void = { _ in }
    ) {
        self.store = store
        self.container = container
        self.onRemoteChanges = onRemoteChanges
        self.onProgress = onProgress
    }

    /// Fetches private-zone changes, then drains the durable local outbox.
    func sync(forceBridgeDeviceRefresh: Bool = false) async throws -> ICloudTextSyncResult {
        uploaded = 0
        downloaded = 0

        await reportProgress(.preparing)
        let (_, syncEngine) = try await prepareEngine(
            forceBridgeDeviceRefresh: forceBridgeDeviceRefresh
        )
        await reportProgress(.fetching)
        try await MuesliCKSyncCycle.run(
            maximumUploadBatches: Self.maximumUploadBatchesPerSync,
            fetch: {
                let options = CKSyncEngine.FetchChangesOptions(
                    scope: .zoneIDs([ICloudTextSyncEngine.Schema.syncZoneID])
                )
                try await syncEngine.fetchChanges(options)
            },
            registerNextBatch: {
                let registered = try self.registerNextDirtyBatch(state: syncEngine.state)
                if registered > 0 {
                    await self.reportProgress(.uploading(self.uploaded))
                }
                return registered
            },
            uploadedCount: { self.uploaded },
            send: {
                let options = CKSyncEngine.SendChangesOptions(
                    scope: .zoneIDs([ICloudTextSyncEngine.Schema.syncZoneID])
                )
                try await syncEngine.sendChanges(options)
            }
        )

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

    /// Prepares the account boundary, custom zone, migration, and engine state.
    @discardableResult
    func prepare(forceBridgeDeviceRefresh: Bool = false) async throws -> Bool {
        let (syncZoneWasRecreated, _) = try await prepareEngine(
            forceBridgeDeviceRefresh: forceBridgeDeviceRefresh
        )
        return syncZoneWasRecreated
    }

    /// Cancels outstanding CloudKit operations and discards the live engine.
    func cancel() async {
        let engineToCancel = engine
        engine = nil
        await engineToCancel?.cancelOperations()
    }

    private func prepareEngine(
        forceBridgeDeviceRefresh: Bool
    ) async throws -> (syncZoneWasRecreated: Bool, engine: CKSyncEngine) {
        let currentUser = try await resolvedContainer().userRecordID()
        guard try authorizeAccount(currentUser) else {
            if let engine {
                engine.state.remove(
                    pendingRecordZoneChanges: engine.state.pendingRecordZoneChanges
                )
            }
            try store.clearCloudSyncStateData(forKey: Self.stateKey)
            throw MuesliCKSyncError.accountChanged
        }

        let preflight: ICloudTextSyncEngine
        if let existing = self.preflight {
            preflight = existing
        } else {
            let created = ICloudTextSyncEngine(container: resolvedContainer())
            self.preflight = created
            preflight = created
        }

        let syncZoneWasRecreated = try await preflight.prepareForCKSyncEngine(
            store: store,
            forceBridgeDeviceRefresh: forceBridgeDeviceRefresh
        )
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
        return (syncZoneWasRecreated, syncEngine)
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
                    _ = try handleAccountChange(
                        currentUser: currentUser,
                        state: syncEngine.state
                    )
                case .switchAccounts(_, let currentUser):
                    _ = try handleAccountChange(
                        currentUser: currentUser,
                        state: syncEngine.state
                    )
                case .signOut:
                    _ = try handleAccountChange(
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
    ) throws -> Bool {
        // This runs inside CKSyncEngine's own delegate callback. Cancelling the
        // same engine here is re-entrant and CloudKit deliberately traps. Keep
        // live engine inert; discard account-specific pending work and state.
        state.remove(pendingRecordZoneChanges: state.pendingRecordZoneChanges)
        try store.clearCloudSyncStateData(forKey: Self.stateKey)
        conflictBaseRecords.removeAll()
        guard let currentUser else {
            accountBoundaryBlocked = true
            return false
        }

        guard try authorizeAccount(currentUser) else { return false }
        _ = try registerNextDirtyBatch(state: state)
        return true
    }

    /// Hashes the per-container user ID before it reaches local persistence.
    static func accountScope(for userRecordID: CKRecord.ID) -> String {
        let digest = SHA256.hash(data: Data(userRecordID.recordName.utf8))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private func authorizeAccount(_ userRecordID: CKRecord.ID) throws -> Bool {
        let matches = try store.claimCloudSyncAccountScope(
            Self.accountScope(for: userRecordID),
            forKey: Self.accountScopeKey
        )
        accountBoundaryBlocked = !matches
        if !matches {
            Self.logger.error("account_boundary_blocked")
        }
        return matches
    }
}
