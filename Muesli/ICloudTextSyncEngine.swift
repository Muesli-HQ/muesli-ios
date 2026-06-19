import CloudKit
import Foundation

struct ICloudTextSyncResult: Equatable {
    let uploaded: Int
    let downloaded: Int
}

private struct ICloudTextZoneChangesPage {
    let records: [CKRecord]
    let serverChangeToken: CKServerChangeToken
    let moreComing: Bool
}

protocol ICloudTextChangeTokenStore {
    func loadToken() -> CKServerChangeToken?
    func saveToken(_ token: CKServerChangeToken)
    func clearToken()
}

final class UserDefaultsICloudTextChangeTokenStore: ICloudTextChangeTokenStore {
    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = "muesli.icloud.textRecords.MuesliSyncZone.serverChangeToken.v1"
    ) {
        self.defaults = defaults
        self.key = key
    }

    func loadToken() -> CKServerChangeToken? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: CKServerChangeToken.self,
            from: data
        )
    }

    func saveToken(_ token: CKServerChangeToken) {
        guard let data = try? NSKeyedArchiver.archivedData(
            withRootObject: token,
            requiringSecureCoding: true
        ) else { return }
        defaults.set(data, forKey: key)
    }

    func clearToken() {
        defaults.removeObject(forKey: key)
    }
}

final class ICloudTextSyncEngine {
    private enum Schema {
        static let containerIdentifier = "iCloud.com.mueslihq.muesli"
        static let syncZoneName = "MuesliSyncZone"
        static let textRecordType = "MuesliTextRecord"
        static let migratedDefaultZoneKey = "muesli.icloud.textRecords.defaultToSyncZoneMigrated.v1"

        static var syncZoneID: CKRecordZone.ID {
            CKRecordZone.ID(zoneName: syncZoneName, ownerName: CKCurrentUserDefaultName)
        }
    }

    private let container: CKContainer
    private let database: CKDatabase
    private let changeTokenStore: ICloudTextChangeTokenStore
    private let defaults: UserDefaults

    init(
        container: CKContainer = CKContainer(identifier: Schema.containerIdentifier),
        changeTokenStore: ICloudTextChangeTokenStore = UserDefaultsICloudTextChangeTokenStore(),
        defaults: UserDefaults = .standard
    ) {
        self.container = container
        self.database = container.privateCloudDatabase
        self.changeTokenStore = changeTokenStore
        self.defaults = defaults
    }

    func sync(store: SharedStore = SharedStore()) async throws -> ICloudTextSyncResult {
        try await ensureSyncZone()
        try await migrateDefaultZoneIfNeeded(store: store)

        let remoteRecords = try await fetchChangedTextRecords()
        var downloaded = 0
        for record in remoteRecords {
            guard let syncRecord = Self.syncTextRecord(from: record) else { continue }
            try store.upsertSyncedTextRecord(syncRecord)
            downloaded += 1
        }

        let dirtyRecords = try store.textRecordsNeedingSync()
        let savedRecords = try await save(records: dirtyRecords.map(Self.syncZoneCloudRecord(from:)))
        for savedRecord in savedRecords {
            guard let kind = Self.kind(from: savedRecord) else { continue }
            try store.markTextRecordSynced(
                kind: kind,
                recordName: savedRecord.recordID.recordName,
                changeTag: savedRecord.recordChangeTag
            )
        }

        return ICloudTextSyncResult(uploaded: savedRecords.count, downloaded: downloaded)
    }

    private func ensureSyncZone() async throws {
        do {
            _ = try await fetchZone(id: Schema.syncZoneID)
        } catch {
            guard Self.isSyncZoneMissing(error) else { throw error }
            _ = try await save(zone: CKRecordZone(zoneName: Schema.syncZoneName))
            changeTokenStore.clearToken()
            defaults.set(false, forKey: Schema.migratedDefaultZoneKey)
        }
    }

    private func migrateDefaultZoneIfNeeded(store: SharedStore) async throws {
        guard !defaults.bool(forKey: Schema.migratedDefaultZoneKey) else { return }

        let legacyDefaultZoneRecords = try await fetchDefaultZoneTextRecords()
        for record in legacyDefaultZoneRecords {
            guard let syncRecord = Self.syncTextRecord(from: record) else { continue }
            try store.upsertSyncedTextRecord(syncRecord)
        }

        changeTokenStore.clearToken()
        let existingSyncZoneRecords = try await fetchChangedTextRecords()
        for record in existingSyncZoneRecords {
            guard let syncRecord = Self.syncTextRecord(from: record) else { continue }
            try store.upsertSyncedTextRecord(syncRecord)
        }

        let migrationRecords = try store.textRecordsForSyncMigration()
        _ = try await saveInBatches(records: migrationRecords.map(Self.syncZoneCloudRecord(from:)))

        changeTokenStore.clearToken()
        let primedSyncZoneRecords = try await fetchChangedTextRecords()
        for record in primedSyncZoneRecords {
            guard let syncRecord = Self.syncTextRecord(from: record) else { continue }
            try store.upsertSyncedTextRecord(syncRecord)
        }

        defaults.set(true, forKey: Schema.migratedDefaultZoneKey)
    }

    private func fetchChangedTextRecords() async throws -> [CKRecord] {
        var previousToken = changeTokenStore.loadToken()
        var records: [CKRecord] = []

        while true {
            let page = try await fetchZoneChangesPage(previousServerChangeToken: previousToken)
            records.append(contentsOf: page.records)
            previousToken = page.serverChangeToken
            changeTokenStore.saveToken(page.serverChangeToken)
            if !page.moreComing {
                break
            }
        }

        return records
    }

    private func fetchDefaultZoneTextRecords() async throws -> [CKRecord] {
        let query = CKQuery(recordType: Schema.textRecordType, predicate: NSPredicate(value: true))
        var records: [CKRecord] = []
        let firstPage = try await fetch(query: query)
        records.append(contentsOf: firstPage.records)
        var cursor = firstPage.cursor
        while let nextCursor = cursor {
            let page = try await fetch(cursor: nextCursor)
            records.append(contentsOf: page.records)
            cursor = page.cursor
        }
        return records
    }

    private func fetchZoneChangesPage(previousServerChangeToken: CKServerChangeToken?) async throws -> ICloudTextZoneChangesPage {
        try await withCheckedThrowingContinuation { continuation in
            let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration(
                previousServerChangeToken: previousServerChangeToken,
                resultsLimit: nil,
                desiredKeys: Self.desiredTextRecordKeys
            )
            let operation = CKFetchRecordZoneChangesOperation(
                recordZoneIDs: [Schema.syncZoneID],
                configurationsByRecordZoneID: [Schema.syncZoneID: configuration]
            )
            let lock = NSLock()
            var records: [CKRecord] = []
            var zoneResult: Result<(serverChangeToken: CKServerChangeToken, moreComing: Bool), Error>?

            operation.recordWasChangedBlock = { _, result in
                if case .success(let record) = result,
                   record.recordType == Schema.textRecordType {
                    lock.lock()
                    records.append(record)
                    lock.unlock()
                }
            }
            operation.recordWithIDWasDeletedBlock = { _, _ in
                // Muesli currently soft-deletes synced text records with isDeleted.
            }
            operation.recordZoneFetchResultBlock = { _, result in
                lock.lock()
                defer { lock.unlock() }
                switch result {
                case .success(let page):
                    zoneResult = .success((page.serverChangeToken, page.moreComing))
                case .failure(let error):
                    zoneResult = .failure(error)
                }
            }
            operation.fetchRecordZoneChangesResultBlock = { result in
                switch result {
                case .success:
                    lock.lock()
                    let pageRecords = records
                    let pageResult = zoneResult
                    lock.unlock()
                    switch pageResult {
                    case .success(let page):
                        continuation.resume(returning: ICloudTextZoneChangesPage(
                            records: pageRecords,
                            serverChangeToken: page.serverChangeToken,
                            moreComing: page.moreComing
                        ))
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    case .none:
                        continuation.resume(throwing: CKError(.internalError))
                    }
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }
    }

    private func fetch(query: CKQuery) async throws -> (records: [CKRecord], cursor: CKQueryOperation.Cursor?) {
        try await withCheckedThrowingContinuation { continuation in
            let operation = CKQueryOperation(query: query)
            collect(operation: operation, continuation: continuation)
            database.add(operation)
        }
    }

    private func fetch(cursor: CKQueryOperation.Cursor) async throws -> (records: [CKRecord], cursor: CKQueryOperation.Cursor?) {
        try await withCheckedThrowingContinuation { continuation in
            let operation = CKQueryOperation(cursor: cursor)
            collect(operation: operation, continuation: continuation)
            database.add(operation)
        }
    }

    private func collect(
        operation: CKQueryOperation,
        continuation: CheckedContinuation<(records: [CKRecord], cursor: CKQueryOperation.Cursor?), Error>
    ) {
        let lock = NSLock()
        var records: [CKRecord] = []
        operation.recordMatchedBlock = { _, result in
            if case .success(let record) = result {
                lock.lock()
                records.append(record)
                lock.unlock()
            }
        }
        operation.queryResultBlock = { result in
            switch result {
            case .success(let cursor):
                lock.lock()
                let pageRecords = records
                lock.unlock()
                continuation.resume(returning: (pageRecords, cursor))
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }
    }

    private func fetchZone(id: CKRecordZone.ID) async throws -> CKRecordZone {
        try await withCheckedThrowingContinuation { continuation in
            database.fetch(withRecordZoneID: id) { zone, error in
                if let zone {
                    continuation.resume(returning: zone)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: CKError(.unknownItem))
                }
            }
        }
    }

    private func save(records: [CKRecord]) async throws -> [CKRecord] {
        guard !records.isEmpty else { return [] }
        return try await withCheckedThrowingContinuation { continuation in
            let operation = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: nil)
            operation.savePolicy = .changedKeys
            let lock = NSLock()
            var savedRecords: [CKRecord] = []
            operation.perRecordSaveBlock = { _, result in
                if case .success(let record) = result {
                    lock.lock()
                    savedRecords.append(record)
                    lock.unlock()
                }
            }
            operation.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    lock.lock()
                    let records = savedRecords
                    lock.unlock()
                    continuation.resume(returning: records)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }
    }

    private func saveInBatches(records: [CKRecord], batchSize: Int = 200) async throws -> [CKRecord] {
        guard !records.isEmpty else { return [] }
        var savedRecords: [CKRecord] = []
        var start = records.startIndex
        while start < records.endIndex {
            let end = records.index(start, offsetBy: batchSize, limitedBy: records.endIndex) ?? records.endIndex
            savedRecords.append(contentsOf: try await save(records: Array(records[start..<end])))
            start = end
        }
        return savedRecords
    }

    private func save(zone: CKRecordZone) async throws -> CKRecordZone {
        try await withCheckedThrowingContinuation { continuation in
            database.save(zone) { savedZone, error in
                if let savedZone {
                    continuation.resume(returning: savedZone)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: CKError(.internalError))
                }
            }
        }
    }

    private static func syncZoneCloudRecord(from record: SyncTextRecord) -> CKRecord {
        let cloud = CKRecord(
            recordType: Schema.textRecordType,
            recordID: CKRecord.ID(recordName: record.id, zoneID: Schema.syncZoneID)
        )
        cloud["kind"] = record.kind.rawValue as NSString
        cloud["title"] = record.title as NSString?
        cloud["text"] = record.text as NSString
        cloud["speakerTranscript"] = record.speakerTranscript as NSString?
        cloud["summaryText"] = record.summaryText as NSString?
        cloud["manualNotes"] = record.manualNotes as NSString?
        cloud["source"] = record.source as NSString?
        cloud["engineIdentifier"] = record.engineIdentifier as NSString?
        cloud["createdAt"] = record.createdAt as NSDate
        cloud["updatedAt"] = record.updatedAt as NSDate
        cloud["startedAt"] = record.startedAt as NSDate?
        cloud["endedAt"] = record.endedAt as NSDate?
        cloud["durationSeconds"] = record.durationSeconds as NSNumber
        cloud["wordCount"] = record.wordCount as NSNumber
        cloud["isDeleted"] = record.isDeleted as NSNumber
        cloud["schemaVersion"] = 1 as NSNumber
        return cloud
    }

    private static func syncTextRecord(from record: CKRecord) -> SyncTextRecord? {
        guard let kind = kind(from: record),
              let text = record["text"] as? String,
              let createdAt = record["createdAt"] as? Date,
              let updatedAt = record["updatedAt"] as? Date else {
            return nil
        }
        return SyncTextRecord(
            id: record.recordID.recordName,
            kind: kind,
            title: record["title"] as? String,
            text: text,
            speakerTranscript: record["speakerTranscript"] as? String,
            summaryText: record["summaryText"] as? String,
            manualNotes: record["manualNotes"] as? String,
            source: record["source"] as? String,
            engineIdentifier: record["engineIdentifier"] as? String,
            createdAt: createdAt,
            updatedAt: updatedAt,
            startedAt: record["startedAt"] as? Date,
            endedAt: record["endedAt"] as? Date,
            durationSeconds: (record["durationSeconds"] as? NSNumber)?.doubleValue ?? 0,
            wordCount: (record["wordCount"] as? NSNumber)?.intValue ?? 0,
            isDeleted: (record["isDeleted"] as? NSNumber)?.boolValue ?? false,
            cloudChangeTag: record.recordChangeTag
        )
    }

    private static func kind(from record: CKRecord) -> SyncTextRecordKind? {
        guard let raw = record["kind"] as? String else { return nil }
        return SyncTextRecordKind(rawValue: raw)
    }

    private static func isSyncZoneMissing(_ error: Error) -> Bool {
        if let ckError = error as? CKError {
            if ckError.code == .unknownItem {
                return true
            }
            if ckError.code == .partialFailure,
               ckError.partialErrorsByItemID?.values.contains(where: { partialError in
                   (partialError as? CKError)?.code == .unknownItem
               }) == true {
                return true
            }
        }

        let nsError = error as NSError
        let message = [
            nsError.localizedDescription,
            nsError.localizedFailureReason,
            nsError.localizedRecoverySuggestion,
            String(describing: nsError),
        ]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        return message.contains(Schema.syncZoneName.lowercased())
            && (message.contains("zone not found") || message.contains("zone does not exist"))
    }

    private static var desiredTextRecordKeys: [CKRecord.FieldKey] {
        [
            "kind",
            "title",
            "text",
            "speakerTranscript",
            "summaryText",
            "manualNotes",
            "source",
            "engineIdentifier",
            "createdAt",
            "updatedAt",
            "startedAt",
            "endedAt",
            "durationSeconds",
            "wordCount",
            "isDeleted",
            "schemaVersion",
        ]
    }
}
