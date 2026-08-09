import CloudKit
import XCTest
@testable import Muesli

final class MuesliCKSyncEngineTests: XCTestCase {
    func testCycleFetchesBeforeSendingEveryAvailableDirtyPage() async throws {
        var events: [String] = []
        var registeredPages = [2, 1, 0]
        var uploaded = 0

        try await MuesliCKSyncCycle.run(
            maximumUploadBatches: 10,
            fetch: { events.append("fetch") },
            registerNextBatch: {
                events.append("register")
                return registeredPages.removeFirst()
            },
            uploadedCount: { uploaded },
            send: {
                events.append("send")
                uploaded += 1
            }
        )

        XCTAssertEqual(
            events,
            ["fetch", "register", "send", "register", "send", "register"]
        )
        XCTAssertEqual(uploaded, 2)
    }

    func testCycleStopsWhenSendMakesNoProgress() async throws {
        var registrations = 0

        try await MuesliCKSyncCycle.run(
            maximumUploadBatches: 10,
            fetch: {},
            registerNextBatch: {
                registrations += 1
                return 1
            },
            uploadedCount: { 0 },
            send: {}
        )

        XCTAssertEqual(registrations, 1)
    }

    func testRecordBatchLoadsCurrentRowsAndDropsOnlyMissingRows() async {
        let engine = MuesliCKSyncEngine()
        let presentID = CKRecord.ID(
            recordName: "present",
            zoneID: ICloudTextSyncEngine.Schema.syncZoneID
        )
        let missingID = CKRecord.ID(
            recordName: "missing",
            zoneID: ICloudTextSyncEngine.Schema.syncZoneID
        )
        let present = Self.record(id: "present", text: "latest local value")

        let batch = await engine.makeRecordBatch(
            pendingChanges: [.saveRecord(presentID), .saveRecord(missingID)],
            loadRecords: { _ in [present.id: present] }
        )

        XCTAssertEqual(batch.recordsToSave.count, 1)
        XCTAssertEqual(batch.recordsToSave.first?.recordID, presentID)
        let uploadedText = batch.recordsToSave.first?["text"] as? String
        XCTAssertEqual(uploadedText, "latest local value")
        XCTAssertEqual(batch.staleChanges.count, 1)
        if case .saveRecord(let staleID) = batch.staleChanges[0] {
            XCTAssertEqual(staleID, missingID)
        } else {
            XCTFail("Expected missing local row to become a stale save")
        }
    }

    func testRecordBatchKeepsPendingStateWhenLocalReadFails() async {
        let engine = MuesliCKSyncEngine()
        let recordID = CKRecord.ID(
            recordName: "retry-me",
            zoneID: ICloudTextSyncEngine.Schema.syncZoneID
        )

        let batch = await engine.makeRecordBatch(
            pendingChanges: [.saveRecord(recordID)],
            loadRecords: { _ in throw TestFailure.expected }
        )

        XCTAssertTrue(batch.recordsToSave.isEmpty)
        XCTAssertTrue(batch.staleChanges.isEmpty)
    }

    func testTombstoneRoundTripDoesNotRequireAuthoredText() {
        var tombstone = Self.record(id: "deleted", text: "private text")
        tombstone.isDeleted = true
        let cloud = ICloudTextSyncEngine.syncZoneCloudRecord(from: tombstone)

        XCTAssertNil(cloud["text"])
        let decoded = ICloudTextSyncEngine.syncTextRecord(from: cloud)
        XCTAssertEqual(decoded?.id, "deleted")
        XCTAssertEqual(decoded?.text, "")
        XCTAssertEqual(decoded?.isDeleted, true)
        XCTAssertNotNil(decoded?.cloudSystemFields)
    }

    func testPersistedSystemFieldsRehydrateCloudRecordIdentity() {
        let original = ICloudTextSyncEngine.syncZoneCloudRecord(
            from: Self.record(id: "stable", text: "first")
        )
        var updated = Self.record(id: "stable", text: "second")
        updated.cloudSystemFields = ICloudTextSyncEngine.encodedSystemFields(for: original)

        let rehydrated = ICloudTextSyncEngine.syncZoneCloudRecord(from: updated)

        XCTAssertEqual(rehydrated.recordID, original.recordID)
        XCTAssertEqual(rehydrated["text"] as? String, "second")
    }

    func testNewerFetchedServerRecordReplacesLocalDirtyRowAndPendingSave() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = Muesli.SharedStore(containerURL: directory)
        let result = Muesli.DictationResult(
            requestID: UUID(),
            text: "older local text",
            engineIdentifier: "test"
        )
        try store.saveResult(result)
        let local = try XCTUnwrap(try store.textRecordsNeedingSync().first)
        let remote = Self.cloudRecord(
            basedOn: local,
            text: "newer server text",
            updatedAt: local.updatedAt.addingTimeInterval(60)
        )
        let pending = CKSyncEngine.PendingRecordZoneChange.saveRecord(remote.recordID)
        let state = TestPendingState([pending])
        let engine = MuesliCKSyncEngine(store: store)

        let appliedCount = try await engine.handleFetchedRecords([remote], state: state)
        XCTAssertEqual(appliedCount, 1)

        let resolved = try XCTUnwrap(
            try store.textRecordsForSync(recordNames: [local.id])[local.id]
        )
        XCTAssertEqual(resolved.text, "newer server text")
        XCTAssertFalse(try store.hasTextRecordsNeedingSync())
        XCTAssertTrue(state.pendingRecordZoneChanges.isEmpty)
    }

    func testNewerLocalEditKeepsDirtyOutboxAndHydratesFetchedServerMetadata() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = Muesli.SharedStore(containerURL: directory)
        let result = Muesli.DictationResult(
            requestID: UUID(),
            text: "newer local text",
            engineIdentifier: "test"
        )
        try store.saveResult(result)
        let local = try XCTUnwrap(try store.textRecordsNeedingSync().first)
        let remote = Self.cloudRecord(
            basedOn: local,
            text: "older server text",
            updatedAt: local.updatedAt.addingTimeInterval(-60)
        )
        let pending = CKSyncEngine.PendingRecordZoneChange.saveRecord(remote.recordID)
        let state = TestPendingState([pending])
        let engine = MuesliCKSyncEngine(store: store)

        let appliedCount = try await engine.handleFetchedRecords([remote], state: state)
        XCTAssertEqual(appliedCount, 0)

        let resolved = try XCTUnwrap(try store.textRecordsNeedingSync().first)
        XCTAssertEqual(resolved.text, "newer local text")
        XCTAssertNotNil(resolved.cloudSystemFields)
        XCTAssertEqual(state.pendingRecordZoneChanges, [pending])
    }

    func testSavedRecordClearsDurableOutboxAndPendingState() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = Muesli.SharedStore(containerURL: directory)
        try store.saveResult(Muesli.DictationResult(
            requestID: UUID(),
            text: "uploaded text",
            engineIdentifier: "test"
        ))
        let local = try XCTUnwrap(try store.textRecordsNeedingSync().first)
        let saved = Self.cloudRecord(
            basedOn: local,
            text: local.text,
            updatedAt: local.updatedAt
        )
        let pending = CKSyncEngine.PendingRecordZoneChange.saveRecord(saved.recordID)
        let state = TestPendingState([pending])
        let engine = MuesliCKSyncEngine(store: store)

        try await engine.handleSentRecordChanges(
            savedRecords: [saved],
            failedRecordSaves: [],
            state: state
        )

        XCTAssertFalse(try store.hasTextRecordsNeedingSync())
        XCTAssertTrue(state.pendingRecordZoneChanges.isEmpty)
        let stored = try XCTUnwrap(
            try store.textRecordsForSync(recordNames: [local.id])[local.id]
        )
        XCTAssertNotNil(stored.cloudSystemFields)
    }

    private static func cloudRecord(
        basedOn record: Muesli.SyncTextRecord,
        text: String,
        updatedAt: Date
    ) -> CKRecord {
        ICloudTextSyncEngine.syncZoneCloudRecord(from: Muesli.SyncTextRecord(
            id: record.id,
            kind: record.kind,
            title: record.title,
            text: text,
            speakerTranscript: record.speakerTranscript,
            summaryText: record.summaryText,
            manualNotes: record.manualNotes,
            source: record.source,
            localSource: record.localSource,
            engineIdentifier: record.engineIdentifier,
            createdAt: record.createdAt,
            updatedAt: updatedAt,
            startedAt: record.startedAt,
            endedAt: record.endedAt,
            durationSeconds: record.durationSeconds,
            wordCount: text.split(separator: " ").count,
            isDeleted: record.isDeleted,
            cloudChangeTag: record.cloudChangeTag
        ))
    }

    private static func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-cksyncengine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func record(id: String, text: String) -> Muesli.SyncTextRecord {
        Muesli.SyncTextRecord(
            id: id,
            kind: Muesli.SyncTextRecordKind.dictation,
            title: nil,
            text: text,
            speakerTranscript: nil,
            summaryText: nil,
            manualNotes: nil,
            source: "ios",
            engineIdentifier: "test",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200),
            startedAt: nil,
            endedAt: nil,
            durationSeconds: 0,
            wordCount: text.split(separator: " ").count,
            isDeleted: false,
            cloudChangeTag: nil
        )
    }
}

private enum TestFailure: Error {
    case expected
}

private final class TestPendingState: MuesliCKSyncPendingState, @unchecked Sendable {
    private(set) var pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange]

    init(_ changes: [CKSyncEngine.PendingRecordZoneChange] = []) {
        pendingRecordZoneChanges = changes
    }

    func add(pendingRecordZoneChanges changes: [CKSyncEngine.PendingRecordZoneChange]) {
        for change in changes where !pendingRecordZoneChanges.contains(change) {
            pendingRecordZoneChanges.append(change)
        }
    }

    func remove(pendingRecordZoneChanges changes: [CKSyncEngine.PendingRecordZoneChange]) {
        pendingRecordZoneChanges.removeAll { changes.contains($0) }
    }
}
