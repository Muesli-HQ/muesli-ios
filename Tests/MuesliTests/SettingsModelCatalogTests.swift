import XCTest
@testable import Muesli

final class SettingsModelCatalogTests: XCTestCase {
    func testSettingsSectionsFollowCoreWorkflowPriority() {
        XCTAssertEqual(
            SettingsSection.allCases.map(\.title),
            [
                "Voice Notes",
                "Meetings",
                "Dictionary",
                "Models",
                "AI Summaries",
                "Sync & Privacy",
                "Appearance",
                "About",
            ]
        )
        XCTAssertFalse(SettingsSection.allCases.map(\.title).contains("Status"))
    }

    func testAboutListsEveryDirectThirdPartyRuntimeDependency() {
        XCTAssertEqual(
            OpenSourceLibrary.all.map(\.id),
            ["fluidaudio", "whisperkit", "telemetrydeck", "sqlite"]
        )
        XCTAssertTrue(OpenSourceLibrary.all.allSatisfy { !$0.name.isEmpty && !$0.license.isEmpty })
    }

    func testWhisperKitCatalogMatchesSupportedMacVariants() {
        XCTAssertEqual(
            LocalTranscriptionModel.whisperModels.map(\.whisperVariant),
            [
                "tiny.en",
                "small.en",
                "medium.en",
                "large-v3-v20240930_626MB",
            ]
        )
        XCTAssertTrue(LocalTranscriptionModel.whisperModels.allSatisfy { $0.family == .whisper })
        XCTAssertTrue(LocalTranscriptionModel.whisperModels.allSatisfy { !$0.supportsRealtimeStreaming })
    }

    func testWhisperKitDownloadStateUsesTheRuntimeCacheLocation() {
        let modelDirectory = WhisperKitTranscriptionRuntime.modelDirectory(for: "tiny.en")
        XCTAssertTrue(
            modelDirectory.path.hasSuffix(
                "huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-tiny.en"
            )
        )
    }

    func testWhisperKitDownloadRequiresCompletionMarkerAndAllCoreModels() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-whisper-integrity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertFalse(WhisperKitTranscriptionRuntime.isModelDownloaded(at: root))

        for component in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            let compiledModel = root.appendingPathComponent("\(component).mlmodelc", isDirectory: true)
            try FileManager.default.createDirectory(at: compiledModel, withIntermediateDirectories: true)
            try Data("model".utf8).write(to: compiledModel.appendingPathComponent("model.mil"))
        }

        XCTAssertFalse(
            WhisperKitTranscriptionRuntime.isModelDownloaded(at: root),
            "A structurally complete directory is not trusted until the download commits its marker."
        )

        try WhisperKitTranscriptionRuntime.markDownloadComplete(at: root)
        XCTAssertTrue(WhisperKitTranscriptionRuntime.isModelDownloaded(at: root))

        try FileManager.default.removeItem(
            at: root.appendingPathComponent("AudioEncoder.mlmodelc/model.mil")
        )
        XCTAssertFalse(
            WhisperKitTranscriptionRuntime.isModelDownloaded(at: root),
            "The marker cannot make a partial model installation appear ready."
        )
    }

    func testModelCatalogHasStableUniqueIdentifiers() {
        let models = LocalTranscriptionModel.allCases
        XCTAssertEqual(Set(models.map(\.id)).count, models.count)
        XCTAssertEqual(
            models.count,
            LocalTranscriptionModel.parakeetModels.count + LocalTranscriptionModel.whisperModels.count
        )
    }

    func testEveryModelHasAnIsolatedStorageDirectory() {
        let directories = LocalTranscriptionModel.allCases.compactMap {
            ModelBackgroundDownloadService.storageDirectory(for: $0)?.standardizedFileURL.path
        }

        XCTAssertEqual(directories.count, LocalTranscriptionModel.allCases.count)
        XCTAssertEqual(Set(directories).count, directories.count)
        XCTAssertTrue(directories.allSatisfy { !$0.isEmpty && $0 != "/" })
    }

    func testRemovingModelDirectoryDoesNotRemoveSiblingModels() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-model-removal-\(UUID().uuidString)", isDirectory: true)
        let target = root.appendingPathComponent("target-model", isDirectory: true)
        let sibling = root.appendingPathComponent("sibling-model", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try Data("target".utf8).write(to: target.appendingPathComponent("model.bin"))
        try Data("sibling".utf8).write(to: sibling.appendingPathComponent("model.bin"))

        try ModelBackgroundDownloadService.removeDownloadedModel(at: target)

        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path))
    }

    func testBackgroundDownloadTaskDescriptionPreservesAttemptIdentity() throws {
        let attemptID = UUID()
        let file = ModelDownloadFile(
            remotePath: "Encoder.mlmodelc/model.mil",
            localPath: "Encoder.mlmodelc/model.mil",
            remoteURL: try XCTUnwrap(URL(string: "https://example.com/model.mil")),
            size: 42
        )

        let description = file.taskDescription(model: .parakeetV3, attemptID: attemptID)
        let restored = try XCTUnwrap(ModelDownloadFile(taskDescription: description))

        XCTAssertEqual(restored.model, .parakeetV3)
        XCTAssertEqual(restored.remotePath, file.remotePath)
        XCTAssertEqual(restored.localPath, file.localPath)
        XCTAssertEqual(restored.remoteURL, file.remoteURL)
        XCTAssertEqual(restored.size, file.size)
        XCTAssertEqual(restored.attemptID, attemptID)
    }

    func testLegacyBackgroundDownloadTaskDescriptionStillRestores() throws {
        let description = [
            LocalTranscriptionModel.parakeetV3.rawValue,
            "Encoder.mlmodelc/model.mil",
            "Encoder.mlmodelc/model.mil",
            "https://example.com/model.mil",
            "42",
        ].joined(separator: "\n")

        let restored = try XCTUnwrap(ModelDownloadFile(taskDescription: description))

        XCTAssertEqual(restored.model, .parakeetV3)
        XCTAssertNil(restored.attemptID)
    }

    func testStaleAttemptCannotMatchNewPlanForSameModel() throws {
        let staleAttemptID = UUID()
        let currentAttemptID = UUID()
        let currentAttempt = ModelDownloadAttempt(
            modelRawValue: LocalTranscriptionModel.parakeetV3.rawValue,
            id: currentAttemptID
        )
        let plan = DownloadPlan(attempt: currentAttempt, totalBytes: 42, pendingCount: 1)
        let staleFile = ModelDownloadFile(
            remotePath: "Encoder.mlmodelc/model.mil",
            localPath: "Encoder.mlmodelc/model.mil",
            remoteURL: try XCTUnwrap(URL(string: "https://example.com/model.mil")),
            size: 42,
            model: .parakeetV3,
            attemptID: staleAttemptID
        )
        let currentFile = ModelDownloadFile(
            remotePath: staleFile.remotePath,
            localPath: staleFile.localPath,
            remoteURL: staleFile.remoteURL,
            size: staleFile.size,
            model: .parakeetV3,
            attemptID: currentAttemptID
        )

        XCTAssertFalse(plan.matches(staleFile))
        XCTAssertFalse(currentAttempt.matches(staleFile))
        XCTAssertTrue(plan.matches(currentFile))
        XCTAssertTrue(currentAttempt.matches(currentFile))
    }

    func testRestoredAttemptCannotCompleteAfterAnyFileFails() {
        let attempt = ModelDownloadAttempt(
            modelRawValue: LocalTranscriptionModel.parakeetV3.rawValue,
            id: UUID()
        )
        var outcomes = ModelDownloadAttemptOutcomeTracker()

        outcomes.recordCompletion(attempt)
        XCTAssertTrue(outcomes.recordFailure(attempt))
        outcomes.recordCompletion(attempt)

        XCTAssertTrue(outcomes.drainCompletedAttempts().isEmpty)
    }
}
