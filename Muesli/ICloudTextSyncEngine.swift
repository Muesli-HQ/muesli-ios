import CloudKit
import Foundation

struct ICloudTextSyncResult: Equatable {
    let uploaded: Int
    let downloaded: Int
}

/// Counts records handed over by a CKQueryOperation. `recordMatchedBlock` runs
/// off the calling thread, so the count is guarded.
private final class DeliveredRecordCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return count == 0
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
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

struct MuesliBridgeDeviceSnapshot: Equatable {
    let deviceID: String
    let platform: String
    let deviceName: String
    let appVersion: String
    let lastSeenAt: Date
}

enum MuesliBridgeDeviceIdentity {
    private static let localDeviceIDKey = "muesli.sync.bridge.localDeviceID.v1"
    private static let localDeviceNameKey = "muesli.sync.bridge.localDeviceName.v1"
    private static let remoteDeviceIDKey = "muesli.sync.bridge.remoteDeviceID.v1"
    private static let remoteDeviceNameKey = "muesli.sync.bridge.remoteDeviceName.v1"
    private static let remoteDevicePlatformKey = "muesli.sync.bridge.remoteDevicePlatform.v1"
    private static let remoteDeviceLastSeenAtKey = "muesli.sync.bridge.remoteDeviceLastSeenAt.v1"
    private static let lastRefreshKey = "muesli.sync.bridge.lastDeviceRefreshAttemptAt.v1"
    private static let lastRefreshFailureKey = "muesli.sync.bridge.lastDeviceRefreshFailureAt.v1"
    private static let linkedRefreshInterval: TimeInterval = 60 * 60
    private static let unlinkedRefreshInterval: TimeInterval = 60
    private static let failureRetryInterval: TimeInterval = 15

    static func local(defaults: UserDefaults = .standard) -> MuesliBridgeDeviceSnapshot {
        let deviceID: String
        if let persisted = defaults.string(forKey: localDeviceIDKey), !persisted.isEmpty {
            deviceID = persisted
        } else {
            deviceID = UUID().uuidString
            defaults.set(deviceID, forKey: localDeviceIDKey)
        }

        let deviceName = currentDeviceName()
        defaults.set(deviceName, forKey: localDeviceNameKey)
        return MuesliBridgeDeviceSnapshot(
            deviceID: deviceID,
            platform: "iOS",
            deviceName: deviceName,
            appVersion: appVersion(),
            lastSeenAt: Date()
        )
    }

    static var remoteDeviceDisplayName: String? {
        UserDefaults.standard.string(forKey: remoteDeviceNameKey)
    }

    static var remoteDevicePlatform: String? {
        UserDefaults.standard.string(forKey: remoteDevicePlatformKey)
    }

    static func hasKnownRemoteDevice(defaults: UserDefaults = .standard) -> Bool {
        guard let deviceID = defaults.string(forKey: remoteDeviceIDKey) else { return false }
        return !deviceID.isEmpty
    }

    static func shouldRefresh(
        defaults: UserDefaults = .standard,
        now: Date = Date(),
        forceRefresh: Bool = false
    ) -> Bool {
        if forceRefresh {
            return true
        }
        if let lastFailure = defaults.object(forKey: lastRefreshFailureKey) as? Date {
            let lastSuccess = defaults.object(forKey: lastRefreshKey) as? Date
            if lastSuccess.map({ lastFailure > $0 }) ?? true {
                return now.timeIntervalSince(lastFailure) >= failureRetryInterval
            }
        }
        guard let lastRefresh = defaults.object(forKey: lastRefreshKey) as? Date else {
            return true
        }
        let interval = hasKnownRemoteDevice(defaults: defaults) ? linkedRefreshInterval : unlinkedRefreshInterval
        return now.timeIntervalSince(lastRefresh) >= interval
    }

    static func markRefreshed(defaults: UserDefaults = .standard, at date: Date = Date()) {
        defaults.set(date, forKey: lastRefreshKey)
        defaults.removeObject(forKey: lastRefreshFailureKey)
    }

    static func markRefreshFailed(defaults: UserDefaults = .standard, at date: Date = Date()) {
        defaults.set(date, forKey: lastRefreshFailureKey)
    }

    static func updateRemoteDevices(from records: [CKRecord], defaults: UserDefaults = .standard) {
        let localID = defaults.string(forKey: localDeviceIDKey) ?? ""
        let latestRemote = records
            .compactMap(Self.snapshot(from:))
            .filter { $0.deviceID != localID }
            .max { $0.lastSeenAt < $1.lastSeenAt }

        guard let latestRemote else {
            defaults.removeObject(forKey: remoteDeviceIDKey)
            defaults.removeObject(forKey: remoteDeviceNameKey)
            defaults.removeObject(forKey: remoteDevicePlatformKey)
            defaults.removeObject(forKey: remoteDeviceLastSeenAtKey)
            return
        }

        defaults.set(latestRemote.deviceID, forKey: remoteDeviceIDKey)
        defaults.set(latestRemote.deviceName, forKey: remoteDeviceNameKey)
        defaults.set(latestRemote.platform, forKey: remoteDevicePlatformKey)
        defaults.set(latestRemote.lastSeenAt, forKey: remoteDeviceLastSeenAtKey)
    }

    static func snapshot(from record: CKRecord) -> MuesliBridgeDeviceSnapshot? {
        guard let deviceID = record["deviceID"] as? String,
              let platform = record["platform"] as? String,
              let deviceName = record["deviceName"] as? String,
              let lastSeenAt = record["lastSeenAt"] as? Date else {
            return nil
        }
        return MuesliBridgeDeviceSnapshot(
            deviceID: deviceID,
            platform: platform,
            deviceName: deviceName,
            appVersion: record["appVersion"] as? String ?? "unknown",
            lastSeenAt: lastSeenAt
        )
    }

    private static func currentDeviceName() -> String {
        let name = ProcessInfo.processInfo.hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "This iPhone" : name
    }

    private static func appVersion() -> String {
        let info = Bundle.main.infoDictionary
        return (info?["CFBundleShortVersionString"] as? String)
            ?? (info?["CFBundleVersion"] as? String)
            ?? "unknown"
    }
}


final class ICloudTextSyncEngine {
    static let containerIdentifier = "iCloud.com.mueslihq.muesli"

    private enum Schema {
        static let containerIdentifier = ICloudTextSyncEngine.containerIdentifier
        static let syncZoneName = "MuesliSyncZone"
        static let textRecordType = "MuesliTextRecord"
        static let bridgeDeviceRecordType = "MuesliBridgeDevice"
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

    /// A one-line summary of why sync may not be moving anything.
    ///
    /// Sync reports "All text is up to date." whenever a pass downloads and
    /// uploads nothing, which looks identical whether there was genuinely
    /// nothing to do or the device is queued behind something invisible. These
    /// are the values that tell those apart, and every one of them is currently
    /// unobservable from the outside.
    @MainActor
    static func diagnosticsSummary(store: SharedStore = SharedStore()) -> String {
        let defaults = UserDefaults.standard
        let migrated = defaults.bool(forKey: Schema.migratedDefaultZoneKey)
        let hasToken = defaults.data(
            forKey: "muesli.icloud.textRecords.MuesliSyncZone.serverChangeToken.v1"
        ) != nil
        let enabled = MuesliPreferences.iCloudSyncEnabled

        let pending = (try? store.textRecordsNeedingSync(limit: 500))?.count
        let sessions = (try? store.recordingSessions())?.count
        let results = (try? store.resultsHistory())?.count
        let remoteDevice = defaults.string(forKey: "muesli.sync.bridge.remoteDeviceName.v1")
        let remotePlatform = defaults.string(forKey: "muesli.sync.bridge.remoteDevicePlatform.v1")

        return [
            "sync: enabled=\(enabled)",
            "migrated=\(migrated)",
            "changeToken=\(hasToken ? "present" : "none")",
            "pendingUpload=\(pending.map(String.init) ?? "?")",
            "localNotes=\(results.map(String.init) ?? "?")",
            "localSessions=\(sessions.map(String.init) ?? "?")",
            "linkedDevice=\(remoteDevice ?? "none")\(remotePlatform.map { " (\($0))" } ?? "")"
        ].joined(separator: " ")
    }

    func sync(
        store: SharedStore = SharedStore(),
        forceBridgeDeviceRefresh: Bool = false
    ) async throws -> ICloudTextSyncResult {
        try await ensureSyncZone()
        await refreshBridgeDeviceLink(forceRefresh: forceBridgeDeviceRefresh)
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

    private func refreshBridgeDeviceLink(forceRefresh: Bool = false) async {
        guard MuesliBridgeDeviceIdentity.shouldRefresh(
            defaults: defaults,
            forceRefresh: forceRefresh
        ) else { return }

        do {
            try await upsertLocalBridgeDeviceRecord()
            let records = try await fetchBridgeDeviceRecords()
            MuesliBridgeDeviceIdentity.updateRemoteDevices(from: records, defaults: defaults)
            MuesliBridgeDeviceIdentity.markRefreshed(defaults: defaults)
        } catch {
            print("Failed to refresh iCloud bridge device identity: \(error)")
            MuesliBridgeDeviceIdentity.markRefreshFailed(defaults: defaults)
        }
    }

    private func upsertLocalBridgeDeviceRecord() async throws {
        let snapshot = MuesliBridgeDeviceIdentity.local(defaults: defaults)
        let recordID = CKRecord.ID(
            recordName: "bridge-device-\(snapshot.deviceID)",
            zoneID: Schema.syncZoneID
        )
        let record = (try? await fetchRecord(id: recordID))
            ?? CKRecord(recordType: Schema.bridgeDeviceRecordType, recordID: recordID)
        if record["createdAt"] == nil {
            record["createdAt"] = Date() as NSDate
        }
        record["deviceID"] = snapshot.deviceID as NSString
        record["platform"] = snapshot.platform as NSString
        record["deviceName"] = snapshot.deviceName as NSString
        record["appVersion"] = snapshot.appVersion as NSString
        record["lastSeenAt"] = snapshot.lastSeenAt as NSDate
        _ = try await save(records: [record])
    }

    private func fetchBridgeDeviceRecords() async throws -> [CKRecord] {
        let query = CKQuery(recordType: Schema.bridgeDeviceRecordType, predicate: NSPredicate(value: true))
        var records: [CKRecord] = []
        let firstPage = try await fetch(query: query, zoneID: Schema.syncZoneID)
        records.append(contentsOf: firstPage.records)
        var cursor = firstPage.cursor
        while let nextCursor = cursor {
            let page = try await fetch(cursor: nextCursor)
            records.append(contentsOf: page.records)
            cursor = page.cursor
        }
        return records
    }

    private func migrateDefaultZoneIfNeeded(store: SharedStore) async throws {
        guard !defaults.bool(forKey: Schema.migratedDefaultZoneKey) else { return }

        // This migration is why a TestFlight user's sync failed on every pass,
        // and it only fails against a container whose legacy schema is not
        // queryable -- which no development build reproduces. Report what it
        // actually did, so the fix can be confirmed from the field rather than
        // inferred.
        let legacyDefaultZoneRecords: [CKRecord]
        do {
            legacyDefaultZoneRecords = try await fetchDefaultZoneTextRecords()
            let readCount = legacyDefaultZoneRecords.count
            await MainActor.run {
                AppTelemetry.signal(
                    "icloud_legacy_migration_read",
                    parameters: [
                        "outcome": readCount == 0 ? "empty" : "records_found",
                        "record_count": String(readCount)
                    ]
                )
            }
        } catch {
            // Reached only for errors the tolerance deliberately does not
            // cover, or an interrupted read of a set that does exist. Either
            // way the migration stays unfinished and retries next sync.
            await MainActor.run {
                AppTelemetry.failure(
                    "icloud_legacy_migration_failed",
                    domain: .cloudSync,
                    stage: "legacy_default_zone_read",
                    error: error
                )
            }
            throw error
        }
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
        let importedCount = legacyDefaultZoneRecords.count
        await MainActor.run {
            AppTelemetry.signal(
                "icloud_legacy_migration_completed",
                parameters: ["imported": String(importedCount)]
            )
        }
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

    /// Reads text records left in the default zone by builds that predate
    /// `MuesliSyncZone`.
    ///
    /// This is a query, and CloudKit queries require the record type to carry a
    /// queryable index. That index is not guaranteed to exist -- notably in the
    /// Production environment, where schema cannot be created by the app -- so
    /// a container that has never been indexed answers with
    /// "Type is not marked indexable: MuesliTextRecord".
    ///
    /// A container with no legacy records to migrate is indistinguishable from
    /// one that cannot answer the question, and neither is a reason to fail:
    /// steady-state sync uses `CKFetchRecordZoneChangesOperation` on the custom
    /// zone, which needs no index. Treat those errors as "no legacy records".
    ///
    /// macOS has carried this tolerance since June (`MuesliICloudSyncEngine`,
    /// `isMissingLegacyDefaultZoneRecords`); iOS shipped the same migration
    /// without it, so a TestFlight user saw every sync fail with that message.
    private func fetchDefaultZoneTextRecords() async throws -> [CKRecord] {
        var records: [CKRecord] = []
        var cursor: CKQueryOperation.Cursor?
        let delivered = DeliveredRecordCounter()

        // Tolerance applies to the opening query only. An unindexed or absent
        // legacy schema fails here, before any page is read, and means there is
        // nothing to migrate.
        do {
            let query = CKQuery(recordType: Schema.textRecordType, predicate: NSPredicate(value: true))
            let firstPage = try await fetch(query: query) {
                delivered.increment()
            }
            records.append(contentsOf: firstPage.records)
            cursor = firstPage.cursor
        } catch {
            // Records having arrived proves the type is queryable, so a
            // tolerated code after that is not "no legacy records" -- it is a
            // real failure over a set that exists. Propagate it unaltered so
            // the caller retries and telemetry still sees a CloudKit error.
            guard delivered.isEmpty else { throw error }
            guard Self.isMissingLegacyDefaultZoneRecords(error) else { throw error }
            return []
        }

        // Past this point the type is demonstrably queryable, so the same error
        // codes no longer mean "no legacy records" -- they mean a real failure
        // partway through a set that does exist. Let it propagate: the caller
        // leaves the migration flag unset and retries on the next sync, which
        // is safe because importing is an idempotent upsert. Returning the
        // pages read so far would instead mark the migration complete and
        // strand every record after the failure.
        while let nextCursor = cursor {
            let page = try await fetch(cursor: nextCursor)
            records.append(contentsOf: page.records)
            cursor = page.cursor
        }

        return records
    }

    /// Whether an error means the legacy default-zone records cannot be read,
    /// as opposed to a genuine sync failure.
    ///
    /// Mirrors the macOS classifier so the two platforms tolerate the same
    /// conditions. `invalidArguments` is the one that matters in practice: it
    /// is what a missing queryable index reports.
    static func isMissingLegacyDefaultZoneRecords(_ error: Error) -> Bool {
        if let ckError = error as? CKError {
            if isIgnorableLegacyDefaultZoneCode(ckError.code) {
                return true
            }
            // Every per-item error has to be tolerable. Matching on any one of
            // them would swallow a real failure whenever it happened to be
            // batched alongside a missing-schema error.
            if ckError.code == .partialFailure,
               let partialErrors = ckError.partialErrorsByItemID,
               !partialErrors.isEmpty,
               partialErrors.values.allSatisfy(isMissingLegacyDefaultZoneRecords) {
                return true
            }
        }

        let nsError = error as NSError
        if nsError.domain == CKError.errorDomain,
           isIgnorableLegacyDefaultZoneCode(CKError.Code(rawValue: nsError.code)) {
            return true
        }
        if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isMissingLegacyDefaultZoneRecords(underlyingError)
        }
        return false
    }

    static func isIgnorableLegacyDefaultZoneCode(_ code: CKError.Code?) -> Bool {
        switch code {
        case .unknownItem, .serverRejectedRequest, .invalidArguments, .zoneNotFound:
            return true
        default:
            return false
        }
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

    private func fetch(
        query: CKQuery,
        zoneID: CKRecordZone.ID? = nil,
        onRecordDelivered: (@Sendable () -> Void)? = nil
    ) async throws -> (records: [CKRecord], cursor: CKQueryOperation.Cursor?) {
        try await withCheckedThrowingContinuation { continuation in
            let operation = CKQueryOperation(query: query)
            operation.zoneID = zoneID
            collect(
                operation: operation,
                continuation: continuation,
                onRecordDelivered: onRecordDelivered
            )
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
        continuation: CheckedContinuation<(records: [CKRecord], cursor: CKQueryOperation.Cursor?), Error>,
        onRecordDelivered: (@Sendable () -> Void)? = nil
    ) {
        let lock = NSLock()
        var records: [CKRecord] = []
        operation.recordMatchedBlock = { _, result in
            if case .success(let record) = result {
                lock.lock()
                records.append(record)
                lock.unlock()
                // A query can deliver records and then fail, in which case the
                // error carries no trace of them. Callers that need to tell an
                // empty result from an interrupted one count them here.
                onRecordDelivered?()
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

    private func fetchRecord(id: CKRecord.ID) async throws -> CKRecord {
        try await withCheckedThrowingContinuation { continuation in
            database.fetch(withRecordID: id) { record, error in
                if let record {
                    continuation.resume(returning: record)
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
        cloud["manualNotesUpdatedAt"] = record.manualNotesUpdatedAt as NSDate?
        cloud["source"] = record.source as NSString?
        cloud["localSource"] = record.localSource as NSString?
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
            localSource: record["localSource"] as? String,
            engineIdentifier: record["engineIdentifier"] as? String,
            createdAt: createdAt,
            updatedAt: updatedAt,
            manualNotesUpdatedAt: record["manualNotesUpdatedAt"] as? Date,
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
            "manualNotesUpdatedAt",
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
