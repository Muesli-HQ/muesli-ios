import CloudKit
import XCTest
@testable import Muesli

final class MuesliCKSyncEngineTests: XCTestCase {
    func testProgressDiagnosticsExposeOnlyFixedPhaseNames() {
        XCTAssertEqual(MuesliCKSyncProgress.preparing.diagnosticValue, "preparing")
        XCTAssertEqual(MuesliCKSyncProgress.fetching.diagnosticValue, "fetching")
        XCTAssertEqual(MuesliCKSyncProgress.downloading(42).diagnosticValue, "downloading")
        XCTAssertEqual(MuesliCKSyncProgress.uploading(42).diagnosticValue, "uploading")
    }

    func testLocalCycleSendsEveryAvailableDirtyPageWithoutFetching() async throws {
        var events: [String] = []
        var registeredPages = [2, 1, 0]
        var uploaded = 0

        try await MuesliCKSyncCycle.sendLocalChanges(
            maximumUploadBatches: 10,
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
            ["register", "send", "register", "send", "register"]
        )
        XCTAssertEqual(uploaded, 2)
    }

    func testCycleStopsWhenSendMakesNoProgress() async throws {
        var registrations = 0

        try await MuesliCKSyncCycle.sendLocalChanges(
            maximumUploadBatches: 10,
            registerNextBatch: {
                registrations += 1
                return 1
            },
            uploadedCount: { 0 },
            send: {}
        )

        XCTAssertEqual(registrations, 1)
    }

    func testOperationPlansKeepLocalAndIncomingPathsDirectional() {
        XCTAssertEqual(MuesliCKSyncPlan.operations(for: .send), [.send])
        XCTAssertEqual(MuesliCKSyncPlan.operations(for: .fetch), [.fetch])
        XCTAssertEqual(MuesliCKSyncPlan.operations(for: .manual), [.send, .fetch])
    }

    func testLaunchPolicyReplaysOutgoingBeforeFetchingWheneverSyncIsEnabled() {
        XCTAssertEqual(MuesliCKSyncLaunchPolicy.initialIntent(syncEnabled: true), .manual)
        XCTAssertNil(MuesliCKSyncLaunchPolicy.initialIntent(syncEnabled: false))
    }

    func testAutomaticZoneLossEventsOnlyClassifyTheMuesliSyncZone() {
        let target = ICloudTextSyncEngine.Schema.syncZoneID
        let unrelated = CKRecordZone.ID(zoneName: "unrelated")

        XCTAssertTrue(MuesliCKSyncAutomaticEventPolicy.lostSyncZone(in: [target]))
        XCTAssertFalse(MuesliCKSyncAutomaticEventPolicy.lostSyncZone(in: [unrelated]))
        XCTAssertTrue(MuesliCKSyncAutomaticEventPolicy.lostSyncZone(
            zoneID: target,
            error: CKError(.userDeletedZone)
        ))
        XCTAssertFalse(MuesliCKSyncAutomaticEventPolicy.lostSyncZone(
            zoneID: target,
            error: CKError(.networkUnavailable)
        ))
        XCTAssertFalse(MuesliCKSyncAutomaticEventPolicy.lostSyncZone(
            zoneID: unrelated,
            error: CKError(.zoneNotFound)
        ))
    }

    func testConcurrentTriggerIntentUnionsInsteadOfOverwritingDirections() {
        var intents = MuesliCKSyncIntentAccumulator()
        intents.insert(.fetch)
        intents.insert(.send)

        XCTAssertEqual(intents.take(), .manual)
        XCTAssertTrue(intents.pending.isEmpty)
    }

    func testPreparationGateRunsPreflightOnceUntilInvalidated() async throws {
        let gate = MuesliCKSyncPreparationGate()
        let counter = TestAsyncCounter()

        async let first = gate.prepare {
            await counter.increment()
            try await Task.sleep(for: .milliseconds(20))
            return false
        }
        async let second = gate.prepare {
            await counter.increment()
            return false
        }
        _ = try await (first, second)

        _ = try await gate.prepare {
            await counter.increment()
            return false
        }
        let countBeforeInvalidation = await counter.value
        XCTAssertEqual(countBeforeInvalidation, 1)

        await gate.invalidate()
        _ = try await gate.prepare {
            await counter.increment()
            return false
        }
        let countAfterInvalidation = await counter.value
        XCTAssertEqual(countAfterInvalidation, 2)
    }

    func testPreparationInvalidationCannotPublishRetiredCompletion() async throws {
        let gate = MuesliCKSyncPreparationGate()
        let started = XCTestExpectation(description: "preparation started")

        let preparation = Task {
            try await gate.prepare {
                started.fulfill()
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    // Simulate an underlying CloudKit bridge that completes even
                    // after task cancellation; the gate generation must reject it.
                }
                return false
            }
        }
        await fulfillment(of: [started], timeout: 1)
        await gate.invalidate()

        do {
            _ = try await preparation.value
            XCTFail("Retired preparation must not become ready")
        } catch is CancellationError {
            // Expected.
        }

        _ = try await gate.prepare { false }
    }

    func testZoneMissingClassifierRecognizesDirectAndNestedCloudKitErrors() {
        for code in [CKError.Code.unknownItem, .zoneNotFound, .userDeletedZone] {
            let direct = CKError(code)
            XCTAssertTrue(ICloudTextSyncEngine.isSyncZoneMissing(direct), "direct \(code)")
            XCTAssertTrue(MuesliCKSyncEngine.invalidatesPreparation(direct), "direct \(code)")

            let nested = Self.partialFailure(containing: Self.partialFailure(containing: direct))
            XCTAssertTrue(ICloudTextSyncEngine.isSyncZoneMissing(nested), "nested \(code)")
            XCTAssertTrue(MuesliCKSyncEngine.invalidatesPreparation(nested), "nested \(code)")
        }
    }

    func testAccountContextClassifierRecognizesDirectAndNestedPartialFailures() {
        for code in [CKError.Code.notAuthenticated, .permissionFailure] {
            let direct = CKError(code)
            XCTAssertFalse(ICloudTextSyncEngine.isSyncZoneMissing(direct), "direct \(code)")
            XCTAssertTrue(MuesliCKSyncEngine.invalidatesPreparation(direct), "direct \(code)")

            let nested = Self.partialFailure(containing: Self.partialFailure(containing: direct))
            XCTAssertFalse(ICloudTextSyncEngine.isSyncZoneMissing(nested), "nested \(code)")
            XCTAssertTrue(MuesliCKSyncEngine.invalidatesPreparation(nested), "nested \(code)")
        }
    }

    func testRecoveryRetryInvalidatesAgainWhenSecondAttemptLosesAccountContext() async {
        var attempts = 0
        var invalidationCodes: [CKError.Code] = []

        do {
            _ = try await MuesliCKSyncRecoveryRunner.run(
                operation: {
                    attempts += 1
                    if attempts == 1 { throw CKError(.zoneNotFound) }
                    throw CKError(.notAuthenticated)
                },
                isZoneMissing: ICloudTextSyncEngine.isSyncZoneMissing,
                invalidatesPreparation: MuesliCKSyncEngine.invalidatesPreparation,
                invalidate: { error in
                    invalidationCodes.append((error as? CKError)?.code ?? .internalError)
                }
            ) as ICloudTextSyncResult
            XCTFail("The bounded retry must rethrow its second failure")
        } catch let error as CKError {
            XCTAssertEqual(error.code, .notAuthenticated)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(invalidationCodes, [.zoneNotFound, .notAuthenticated])
    }

    func testRecoveryRetryInvalidatesAgainWhenSecondAttemptAlsoLosesZone() async {
        var attempts = 0
        var invalidations = 0

        do {
            _ = try await MuesliCKSyncRecoveryRunner.run(
                operation: {
                    attempts += 1
                    throw CKError(attempts == 1 ? .userDeletedZone : .zoneNotFound)
                },
                isZoneMissing: ICloudTextSyncEngine.isSyncZoneMissing,
                invalidatesPreparation: MuesliCKSyncEngine.invalidatesPreparation,
                invalidate: { _ in invalidations += 1 }
            ) as ICloudTextSyncResult
            XCTFail("The bounded retry must stop after two attempts")
        } catch let error as CKError {
            XCTAssertEqual(error.code, .zoneNotFound)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(invalidations, 2)
    }

    func testFetchZoneRecoveryFlushesEveryRebuiltOutboxPageBeforeFetching() async throws {
        var events: [String] = []
        var pages = [2, 1, 0]
        var uploaded = 0

        let result: ICloudTextSyncResult = try await MuesliCKSyncRecoveryRunner.run(
            operation: {
                events.append("fetch-failed")
                throw CKError(.zoneNotFound)
            },
            recoveryOperation: {
                try await MuesliCKSyncCycle.sendLocalChanges(
                    maximumUploadBatches: 10,
                    registerNextBatch: {
                        events.append("register")
                        return pages.removeFirst()
                    },
                    uploadedCount: { uploaded },
                    send: {
                        events.append("send")
                        uploaded += 1
                    }
                )
                events.append("fetch")
                return ICloudTextSyncResult(uploaded: uploaded, downloaded: 0)
            },
            isZoneMissing: ICloudTextSyncEngine.isSyncZoneMissing,
            invalidatesPreparation: MuesliCKSyncEngine.invalidatesPreparation,
            invalidate: { _ in events.append("invalidate") }
        )

        XCTAssertEqual(result.uploaded, 2)
        XCTAssertEqual(
            events,
            ["fetch-failed", "invalidate", "register", "send", "register", "send", "register", "fetch"]
        )
    }

    func testFailedActiveRuntimeBatchPreservesLaterIncomingRequest() async throws {
        let executor = TestRuntimeExecutor()
        let runtime = MuesliCKSyncRuntime(execute: { intent in
            try await executor.execute(intent)
        })

        let first = Task { try await runtime.sendLocalChanges() }
        try await executor.waitForCallCount(1)
        let merged = Task { try await runtime.fetchRemoteChanges() }
        await executor.failActiveOperation()

        await assertFailure(first)
        try await executor.waitForCallCount(2)
        await executor.succeedActiveOperation()
        _ = try await merged.value

        let executedIntents = await executor.executedIntents()
        XCTAssertEqual(executedIntents, [.send, .fetch])
        let pendingIntent = await runtime.pendingIntentForTesting()
        XCTAssertTrue(pendingIntent.isEmpty)
    }

    func testRuntimeCancellationReleasesBackgroundWaiterBeforeEngineCleanupFinishes() async throws {
        let executor = TestRuntimeExecutor()
        let runtime = MuesliCKSyncRuntime(
            execute: { intent in try await executor.execute(intent) },
            cancel: { await executor.waitForCancellationRelease() }
        )
        let request = Task { try await runtime.fetchRemoteChanges() }
        try await executor.waitForCallCount(1)

        let cancellation = Task { await runtime.cancel() }
        do {
            _ = try await request.value
            XCTFail("Cancellation must release the background request")
        } catch is CancellationError {
            // Expected before the injected engine cleanup is released.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let finishedBeforeRelease = await executor.cancellationCleanupFinished()
        XCTAssertFalse(finishedBeforeRelease)
        await executor.releaseCancellationCleanup()
        await cancellation.value
        let finishedAfterRelease = await executor.cancellationCleanupFinished()
        XCTAssertTrue(finishedAfterRelease)
    }

    func testRequestEnqueuedDuringCancellationWaitsForCleanupThenStartsOnce() async throws {
        let executor = TestRuntimeExecutor()
        let runtime = MuesliCKSyncRuntime(
            execute: { intent in try await executor.execute(intent) },
            cancel: { await executor.waitForCancellationRelease() }
        )
        let retired = Task { try await runtime.fetchRemoteChanges() }
        try await executor.waitForCallCount(1)

        let cancellation = Task { await runtime.cancel() }
        try await executor.waitForCancellationCleanupStart()
        let replacement = Task { try await runtime.sendLocalChanges() }
        try await Task.sleep(for: .milliseconds(30))
        let intentsBeforeCleanup = await executor.executedIntents()
        XCTAssertEqual(intentsBeforeCleanup, [.fetch])

        await executor.releaseCancellationCleanup()
        await cancellation.value
        try await executor.waitForCallCount(2)
        let intentsAfterCleanup = await executor.executedIntents()
        XCTAssertEqual(intentsAfterCleanup, [.fetch, .send])
        await executor.succeedActiveOperation()
        _ = try await replacement.value

        do {
            _ = try await retired.value
            XCTFail("The retired generation must be cancelled")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testDeadlineRemovesBlockedBackgroundWaiterButLeavesDurableFetchRunning() async throws {
        let executor = TestRuntimeExecutor()
        let runtime = MuesliCKSyncRuntime(execute: { intent in
            try await executor.execute(intent)
        })
        let request = Task {
            try await runtime.fetchRemoteChanges(deadline: .milliseconds(25))
        }
        try await executor.waitForCallCount(1)

        do {
            _ = try await request.value
            XCTFail("The bounded APNs waiter must expire")
        } catch MuesliCKSyncRuntimeError.deadlineExceeded {
            // Expected.
        }
        let waiterCount = await runtime.waiterCountForTesting()
        let executedIntents = await executor.executedIntents()
        XCTAssertEqual(waiterCount, 0)
        XCTAssertEqual(executedIntents, [.fetch])

        // Expiry releases only the OS completion waiter. The shared durable
        // operation remains owned by the runtime/CKSyncEngine and may finish.
        await executor.succeedActiveOperation()
    }

    func testBridgeRefreshUnionsForceAndRunsOneFollowUpGeneration() async throws {
        let bridge = TestBridgeRefreshExecutor()
        let runtime = MuesliCKSyncRuntime(
            execute: { _ in ICloudTextSyncResult(uploaded: 0, downloaded: 0) },
            refreshBridge: { force, shouldCommit in
                await bridge.execute(force: force, shouldCommit: shouldCommit)
            }
        )

        let first = Task { await runtime.refreshBridgeDevice(forceRefresh: false) }
        try await bridge.waitForCallCount(1)
        let forced = Task { await runtime.refreshBridgeDevice(forceRefresh: true) }
        await bridge.releaseActive()
        try await bridge.waitForCallCount(2)
        await bridge.releaseActive()
        await first.value
        await forced.value

        let forceValues = await bridge.forceValues()
        let commitAuthorities = await bridge.commitAuthorities()
        XCTAssertEqual(forceValues, [false, true])
        XCTAssertEqual(commitAuthorities, [true, true])
    }

    func testCancelledBridgeRefreshCannotPublishStaleIdentity() async throws {
        let bridge = TestBridgeRefreshExecutor()
        let runtime = MuesliCKSyncRuntime(
            execute: { _ in ICloudTextSyncResult(uploaded: 0, downloaded: 0) },
            refreshBridge: { force, shouldCommit in
                await bridge.execute(force: force, shouldCommit: shouldCommit)
            }
        )

        let refresh = Task { await runtime.refreshBridgeDevice(forceRefresh: true) }
        try await bridge.waitForCallCount(1)
        await runtime.cancel()
        await refresh.value
        await bridge.releaseActive()
        try await bridge.waitForCommitCount(1)

        let commitAuthorities = await bridge.commitAuthorities()
        XCTAssertEqual(commitAuthorities, [false])
    }

    func testBackgroundFetchReportsNewDataOnlyForAppliedRemoteRecords() async {
        let newData = await MuesliCKSyncBackgroundFetch.run {
            ICloudTextSyncResult(uploaded: 0, downloaded: 1)
        }
        let noData = await MuesliCKSyncBackgroundFetch.run {
            ICloudTextSyncResult(uploaded: 0, downloaded: 0)
        }
        let failed = await MuesliCKSyncBackgroundFetch.run {
            throw TestFailure.expected
        }

        XCTAssertEqual(newData, .newData)
        XCTAssertEqual(noData, .noData)
        XCTAssertEqual(failed, .failed)
    }

    func testBackgroundNotificationRoutesOnlyCloudKitPushesWhileSyncIsEnabled() {
        XCTAssertTrue(MuesliCKSyncBackgroundFetch.shouldFetch(
            isCloudKitNotification: true,
            syncEnabled: true
        ))
        XCTAssertFalse(MuesliCKSyncBackgroundFetch.shouldFetch(
            isCloudKitNotification: false,
            syncEnabled: true
        ))
        XCTAssertFalse(MuesliCKSyncBackgroundFetch.shouldFetch(
            isCloudKitNotification: true,
            syncEnabled: false
        ))
    }

    func testProvenanceMissingClassifierBoundsNestedErrorGraphs() {
        let withinBound = Self.nestedPartialFailure(depth: 6, leaf: CKError(.unknownItem))
        let beyondBound = Self.nestedPartialFailure(depth: 9, leaf: CKError(.unknownItem))

        XCTAssertTrue(ICloudTextSyncEngine.isMissingProvenanceRecord(withinBound))
        XCTAssertFalse(ICloudTextSyncEngine.isMissingProvenanceRecord(beyondBound))
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

    func testDictationTimingSurvivesCloudRecordRoundTrip() throws {
        let startedAt = Date(timeIntervalSince1970: 100)
        let endedAt = Date(timeIntervalSince1970: 142)
        var local = Self.record(id: "timed", text: "timed voice note")
        local.startedAt = startedAt
        local.endedAt = endedAt
        local.durationSeconds = 42

        let cloud = ICloudTextSyncEngine.syncZoneCloudRecord(from: local)
        let decoded = try XCTUnwrap(ICloudTextSyncEngine.syncTextRecord(from: cloud))

        XCTAssertEqual((cloud["durationSeconds"] as? NSNumber)?.doubleValue, 42)
        XCTAssertEqual(decoded.startedAt, startedAt)
        XCTAssertEqual(decoded.endedAt, endedAt)
        XCTAssertEqual(decoded.durationSeconds, 42, accuracy: 0.001)
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

    func testAccountScopeHashIsStableDistinctAndDoesNotExposeRecordName() {
        let first = CKRecord.ID(recordName: "private-user-a")
        let second = CKRecord.ID(recordName: "private-user-b")

        let firstScope = MuesliCKSyncEngine.accountScope(for: first)

        XCTAssertEqual(firstScope, MuesliCKSyncEngine.accountScope(for: first))
        XCTAssertNotEqual(firstScope, MuesliCKSyncEngine.accountScope(for: second))
        XCTAssertFalse(firstScope.contains(first.recordName))
    }

    func testAccountSwitchClearsPendingStateWithoutRequeueingSyncedLocalText() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = Muesli.SharedStore(containerURL: directory)
        try store.saveResult(Muesli.DictationResult(
            requestID: UUID(),
            text: "local text survives account change",
            engineIdentifier: "test"
        ))
        let local = try XCTUnwrap(try store.textRecordsNeedingSync().first)
        let saved = Self.cloudRecord(
            basedOn: local,
            text: local.text,
            updatedAt: local.updatedAt
        )
        XCTAssertTrue(try store.markTextRecordSynced(
            kind: local.kind,
            recordName: local.id,
            changeTag: "old-account-tag",
            systemFields: ICloudTextSyncEngine.encodedSystemFields(for: saved),
            recordUpdatedAt: local.updatedAt
        ))
        XCTAssertFalse(try store.hasTextRecordsNeedingSync())
        try store.saveCloudSyncStateData(Data([1, 2, 3]), forKey: MuesliCKSyncEngine.stateKey)
        let owner = CKRecord.ID(recordName: "owner-account")
        XCTAssertTrue(try store.claimCloudSyncAccountScope(
            MuesliCKSyncEngine.accountScope(for: owner),
            forKey: MuesliCKSyncEngine.accountScopeKey
        ))

        let pending = CKSyncEngine.PendingRecordZoneChange.saveRecord(saved.recordID)
        let state = TestPendingState([pending])
        let engine = MuesliCKSyncEngine(store: store)
        let authorized = try await engine.handleAccountChange(
            currentUser: CKRecord.ID(recordName: "different-account"),
            state: state
        )

        XCTAssertFalse(authorized)
        XCTAssertNil(try store.cloudSyncStateData(forKey: MuesliCKSyncEngine.stateKey))
        XCTAssertTrue(state.pendingRecordZoneChanges.isEmpty)
        XCTAssertFalse(try store.hasTextRecordsNeedingSync())
        let registeredWhileBlocked = try await engine.registerNextDirtyBatch(state: state)
        XCTAssertEqual(registeredWhileBlocked, 0)

        let preserved = try XCTUnwrap(
            try store.textRecordsForSync(recordNames: [local.id])[local.id]
        )
        XCTAssertEqual(preserved.text, "local text survives account change")
        XCTAssertEqual(preserved.cloudChangeTag, "old-account-tag")
        XCTAssertNotNil(preserved.cloudSystemFields)
    }

    func testSameAccountSignInRebuildsPendingSavesForDirtyRows() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = Muesli.SharedStore(containerURL: directory)
        try store.saveResult(Muesli.DictationResult(
            requestID: UUID(),
            text: "same-account dirty row",
            engineIdentifier: "test"
        ))
        let dirty = try XCTUnwrap(try store.textRecordsNeedingSync().first)
        let owner = CKRecord.ID(recordName: "owner-account")
        XCTAssertTrue(try store.claimCloudSyncAccountScope(
            MuesliCKSyncEngine.accountScope(for: owner),
            forKey: MuesliCKSyncEngine.accountScopeKey
        ))

        let state = TestPendingState()
        let engine = MuesliCKSyncEngine(store: store)
        let authorized = try await engine.handleAccountChange(
            currentUser: owner,
            state: state
        )

        XCTAssertTrue(authorized)
        let pending = try XCTUnwrap(state.pendingRecordZoneChanges.first)
        guard case .saveRecord(let pendingRecordID) = pending else {
            return XCTFail("Expected the dirty row to be restored to the pending outbox")
        }
        XCTAssertEqual(pendingRecordID.recordName, dirty.id)
        XCTAssertEqual(pendingRecordID.zoneID, ICloudTextSyncEngine.Schema.syncZoneID)
    }

    func testStartupCanRebuildOrdinaryPersistedDirtyOutboxFromEmptyEngineState() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = Muesli.SharedStore(containerURL: directory)
        try store.saveResult(Muesli.DictationResult(
            requestID: UUID(),
            text: "persisted before process launch",
            engineIdentifier: "test"
        ))
        let dirty = try XCTUnwrap(try store.textRecordsNeedingSync().first)
        let owner = CKRecord.ID(recordName: "startup-owner")
        XCTAssertTrue(try store.claimCloudSyncAccountScope(
            MuesliCKSyncEngine.accountScope(for: owner),
            forKey: MuesliCKSyncEngine.accountScopeKey
        ))
        let state = TestPendingState()
        let engine = MuesliCKSyncEngine(store: store)
        let authorized = try await engine.handleAccountChange(currentUser: owner, state: state)
        XCTAssertTrue(authorized)

        // Simulate an empty restored CKSyncEngine serialization while SQLite's
        // durable sync_dirty row survived the prior process.
        state.remove(pendingRecordZoneChanges: state.pendingRecordZoneChanges)
        XCTAssertTrue(state.pendingRecordZoneChanges.isEmpty)
        let registered = try await engine.registerNextDirtyBatch(state: state)
        XCTAssertEqual(registered, 1)
        guard case .saveRecord(let recordID) = try XCTUnwrap(state.pendingRecordZoneChanges.first) else {
            return XCTFail("Expected startup convergence to rebuild the save")
        }
        XCTAssertEqual(recordID.recordName, dirty.id)
    }

    func testUnscopedLegacyLibraryDoesNotClaimUnverifiedAccount() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = Muesli.SharedStore(containerURL: directory)
        try store.saveResult(Muesli.DictationResult(
            requestID: UUID(),
            text: "legacy authored text stays local",
            engineIdentifier: "test"
        ))
        let local = try XCTUnwrap(try store.textRecordsNeedingSync().first)
        let saved = Self.cloudRecord(
            basedOn: local,
            text: local.text,
            updatedAt: local.updatedAt
        )
        XCTAssertTrue(try store.markTextRecordSynced(
            kind: local.kind,
            recordName: local.id,
            changeTag: "legacy-account-tag",
            systemFields: ICloudTextSyncEngine.encodedSystemFields(for: saved),
            recordUpdatedAt: local.updatedAt
        ))
        try store.saveCloudSyncStateData(Data([7, 8, 9]), forKey: MuesliCKSyncEngine.stateKey)

        let pending = CKSyncEngine.PendingRecordZoneChange.saveRecord(saved.recordID)
        let state = TestPendingState([pending])
        let engine = MuesliCKSyncEngine(
            store: store,
            legacyAccountRecordVerifier: { recordNames in
                XCTAssertEqual(recordNames, Set([local.id]))
                return false
            }
        )
        let authorized = try await engine.handleAccountChange(
            currentUser: CKRecord.ID(recordName: "unverified-account"),
            state: state
        )

        XCTAssertFalse(authorized)
        XCTAssertNil(try store.cloudSyncStateData(forKey: MuesliCKSyncEngine.accountScopeKey))
        XCTAssertNil(try store.cloudSyncStateData(forKey: MuesliCKSyncEngine.stateKey))
        XCTAssertTrue(state.pendingRecordZoneChanges.isEmpty)
        XCTAssertFalse(try store.hasTextRecordsNeedingSync())

        let preserved = try XCTUnwrap(
            try store.textRecordsForSync(recordNames: [local.id])[local.id]
        )
        XCTAssertEqual(preserved.text, "legacy authored text stays local")
        XCTAssertEqual(preserved.cloudChangeTag, "legacy-account-tag")
        XCTAssertNotNil(preserved.cloudSystemFields)
    }

    func testUnscopedLegacyLibraryClaimsVerifiedAccount() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = Muesli.SharedStore(containerURL: directory)
        try store.saveResult(Muesli.DictationResult(
            requestID: UUID(),
            text: "legacy synced text",
            engineIdentifier: "test"
        ))
        let local = try XCTUnwrap(try store.textRecordsNeedingSync().first)
        XCTAssertTrue(try store.markTextRecordSynced(
            kind: local.kind,
            recordName: local.id,
            changeTag: "legacy-account-tag",
            systemFields: Data([1]),
            recordUpdatedAt: local.updatedAt
        ))

        let currentUser = CKRecord.ID(recordName: "verified-account")
        let state = TestPendingState()
        let engine = MuesliCKSyncEngine(
            store: store,
            legacyAccountRecordVerifier: { recordNames in
                XCTAssertEqual(recordNames, Set([local.id]))
                return true
            }
        )
        let authorized = try await engine.handleAccountChange(
            currentUser: currentUser,
            state: state
        )

        XCTAssertTrue(authorized)
        XCTAssertEqual(
            try store.cloudSyncStateData(forKey: MuesliCKSyncEngine.accountScopeKey),
            Data(MuesliCKSyncEngine.accountScope(for: currentUser).utf8)
        )
        XCTAssertTrue(state.pendingRecordZoneChanges.isEmpty)
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

    private static func partialFailure(containing error: Error) -> CKError {
        CKError(
            .partialFailure,
            userInfo: [
                CKPartialErrorsByItemIDKey: [
                    CKRecord.ID(recordName: UUID().uuidString): error,
                ],
            ]
        )
    }

    private static func nestedPartialFailure(depth: Int, leaf: Error) -> Error {
        (0..<depth).reduce(leaf) { current, _ in partialFailure(containing: current) }
    }

    private func assertFailure(
        _ task: Task<ICloudTextSyncResult, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await task.value
            XCTFail("Expected runtime request to fail", file: file, line: line)
        } catch TestFailure.expected {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
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

private actor TestAsyncCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private actor TestRuntimeExecutor {
    private var intents: [MuesliCKSyncIntent] = []
    private var operationContinuations: [CheckedContinuation<ICloudTextSyncResult, Error>] = []
    private var cancellationContinuation: CheckedContinuation<Void, Never>?
    private var cancellationStarted = false
    private var cancellationFinished = false

    func execute(_ intent: MuesliCKSyncIntent) async throws -> ICloudTextSyncResult {
        intents.append(intent)
        return try await withCheckedThrowingContinuation { continuation in
            operationContinuations.append(continuation)
        }
    }

    func waitForCallCount(_ expected: Int) async throws {
        for _ in 0..<200 {
            if intents.count >= expected { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw TestFailure.expected
    }

    func failActiveOperation() {
        guard !operationContinuations.isEmpty else { return }
        operationContinuations.removeFirst().resume(throwing: TestFailure.expected)
    }

    func succeedActiveOperation() {
        guard !operationContinuations.isEmpty else { return }
        operationContinuations.removeFirst().resume(
            returning: ICloudTextSyncResult(uploaded: 1, downloaded: 0)
        )
    }

    func executedIntents() -> [MuesliCKSyncIntent] {
        intents
    }

    func waitForCancellationRelease() async {
        cancellationStarted = true
        await withCheckedContinuation { continuation in
            cancellationContinuation = continuation
        }
        cancellationFinished = true
    }

    func releaseCancellationCleanup() {
        if !operationContinuations.isEmpty {
            operationContinuations.removeFirst().resume(throwing: CancellationError())
        }
        cancellationContinuation?.resume()
        cancellationContinuation = nil
    }

    func waitForCancellationCleanupStart() async throws {
        for _ in 0..<200 {
            if cancellationStarted { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw TestFailure.expected
    }

    func cancellationCleanupFinished() -> Bool {
        cancellationFinished
    }
}

private actor TestBridgeRefreshExecutor {
    private var forces: [Bool] = []
    private var commitResults: [Bool] = []
    private var operationContinuations: [CheckedContinuation<Void, Never>] = []

    func execute(
        force: Bool,
        shouldCommit: @escaping @Sendable () async -> Bool
    ) async {
        forces.append(force)
        await withCheckedContinuation { continuation in
            operationContinuations.append(continuation)
        }
        commitResults.append(await shouldCommit())
    }

    func waitForCallCount(_ expected: Int) async throws {
        for _ in 0..<200 {
            if forces.count >= expected { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw TestFailure.expected
    }

    func waitForCommitCount(_ expected: Int) async throws {
        for _ in 0..<200 {
            if commitResults.count >= expected { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw TestFailure.expected
    }

    func releaseActive() {
        guard !operationContinuations.isEmpty else { return }
        operationContinuations.removeFirst().resume()
    }

    func forceValues() -> [Bool] { forces }
    func commitAuthorities() -> [Bool] { commitResults }
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
