import CloudKit
import Foundation

protocol MuesliCKSyncPendingState: AnyObject, Sendable {
    var pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange] { get }
    func add(pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange])
    func remove(pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange])
}

extension CKSyncEngine.State: MuesliCKSyncPendingState {}

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

struct MuesliCKSyncFailedRecordSave: Sendable {
    let record: CKRecord
    let error: CKError
}

struct MuesliCKSyncRecordBatch: Sendable {
    let recordsToSave: [CKRecord]
    let staleChanges: [CKSyncEngine.PendingRecordZoneChange]
}

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

    private static let subscriptionID = "muesli-ios-cksyncengine-private-v1"
    private static let uploadBatchSize = 200
    private static let maximumUploadBatchesPerSync = 50

    private let store: SharedStore
    private let onRemoteChanges: @Sendable () async -> Void
    private let onProgress: @Sendable (MuesliCKSyncProgress) async -> Void
    private var container: CKContainer?
    private var preflight: ICloudTextSyncEngine?
    private var engine: CKSyncEngine?
    private var conflictBaseRecords: [CKRecord.ID: CKRecord] = [:]
    private var uploaded = 0
    private var downloaded = 0

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
        let countSuffix = count.map { " count=\($0)" } ?? ""
        fputs(
            "[muesli-ios] CKSyncEngine phase=\(progress.diagnosticValue)\(countSuffix)\n",
            stderr
        )
        await onProgress(progress)
    }

    @discardableResult
    func prepare(forceBridgeDeviceRefresh: Bool = false) async throws -> Bool {
        let (syncZoneWasRecreated, _) = try await prepareEngine(
            forceBridgeDeviceRefresh: forceBridgeDeviceRefresh
        )
        return syncZoneWasRecreated
    }

    func cancel() async {
        let engineToCancel = engine
        engine = nil
        await engineToCancel?.cancelOperations()
    }

    private func prepareEngine(
        forceBridgeDeviceRefresh: Bool
    ) async throws -> (syncZoneWasRecreated: Bool, engine: CKSyncEngine) {
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
        return (syncZoneWasRecreated, try makeEngineIfNeeded())
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

    func registerNextDirtyBatch(state: any MuesliCKSyncPendingState) throws -> Int {
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

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter {
            context.options.scope.contains($0)
        }
        let batch = makeRecordBatch(pendingChanges: pending)
        if !batch.staleChanges.isEmpty {
            syncEngine.state.remove(pendingRecordZoneChanges: batch.staleChanges)
        }
        guard !batch.recordsToSave.isEmpty else { return nil }
        return CKSyncEngine.RecordZoneChangeBatch(recordsToSave: batch.recordsToSave)
    }

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
            fputs(
                "[muesli-ios] CKSyncEngine local batch read failed: \(String(describing: type(of: error)))\n",
                stderr
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

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        do {
            switch event {
            case .stateUpdate(let update):
                let data = try PropertyListEncoder().encode(update.stateSerialization)
                try store.saveCloudSyncStateData(data, forKey: Self.stateKey)

            case .fetchedRecordZoneChanges(let changes):
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
                case .signIn, .switchAccounts:
                    try await handleAccountChange(requiresMetadataReset: true)
                case .signOut:
                    try await handleAccountChange(requiresMetadataReset: false)
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
            fputs(
                "[muesli-ios] CKSyncEngine event failed: \(String(describing: type(of: error)))\n",
                stderr
            )
        }
    }

    @discardableResult
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

    func handleAccountChange(requiresMetadataReset: Bool) async throws {
        let engineToCancel = engine
        engine = nil
        await engineToCancel?.cancelOperations()
        try store.clearCloudSyncStateData(forKey: Self.stateKey)
        conflictBaseRecords.removeAll()
        if requiresMetadataReset {
            try store.resetTextRecordCloudMetadataForAccountChange()
        }
    }
}
