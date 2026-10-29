import XCTest
#if canImport(MuesliDev)
@testable import MuesliDev
private typealias CatalogTestStore = MuesliDev.SharedStore
#else
@testable import Muesli
private typealias CatalogTestStore = Muesli.SharedStore
#endif

final class SettingsModelCatalogTests: XCTestCase {
    @MainActor
    func testInventoryRefreshRemovesDeletedModelsAndClearsStaleReadyState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = DictationCoordinator(store: CatalogTestStore(containerURL: directory.appendingPathComponent("store")))
        let selected = coordinator.selectedTranscriptionModel
        let other = try XCTUnwrap(LocalTranscriptionModel.allCases.first { $0 != selected })
        for model in [selected, other] {
            try Data("downloaded".utf8).write(to: directory.appendingPathComponent(model.rawValue))
        }
        let exists: (LocalTranscriptionModel) -> Bool = {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.rawValue).path)
        }
        coordinator.refreshDownloadedModels(isDownloaded: exists)
        coordinator.modelPreparation = .init(phase: .ready, status: "Ready")
        XCTAssertEqual(coordinator.downloadedTranscriptionModels, Set([selected, other]))

        try FileManager.default.removeItem(at: directory.appendingPathComponent(other.rawValue))
        coordinator.refreshDownloadedModels(isDownloaded: exists)
        XCTAssertEqual(coordinator.downloadedTranscriptionModels, [selected])
        XCTAssertTrue(coordinator.modelPreparation.isReady)

        try FileManager.default.removeItem(at: directory.appendingPathComponent(selected.rawValue))
        coordinator.refreshDownloadedModels(isDownloaded: exists)
        XCTAssertTrue(coordinator.downloadedTranscriptionModels.isEmpty)
        XCTAssertEqual(coordinator.modelPreparation.phase, .idle)
        XCTAssertEqual(coordinator.selectedTranscriptionModel, selected)
    }

    func testMissingFilesOverrideCachedReadyStateInSelector() {
        let ready = ModelPreparationState(phase: .ready, status: "Ready")
        XCTAssertEqual(ModelCatalogState.resolve(isDownloaded: false, preparation: ready), .needsDownload)
        XCTAssertEqual(ModelCatalogState.resolve(isDownloaded: false, preparation: ready).icon, "arrow.down.circle")
        XCTAssertEqual(ModelCatalogState.resolve(isDownloaded: true, preparation: nil).icon, "checkmark.circle.fill")
    }

    @MainActor
    func testPreparationCannotRestartWhileModelRemovalIsInProgress() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = DictationCoordinator(store: CatalogTestStore(containerURL: directory))
        coordinator.isRemovingTranscriptionModel = true
        coordinator.modelPreparation = .init(status: "Removing")
        coordinator.prepareModel()
        XCTAssertEqual(coordinator.modelPreparation.phase, .idle)
        XCTAssertEqual(coordinator.modelPreparation.status, "Removing")
    }

    @MainActor
    func testRecordingAndRetryRequirePreparedRuntimeNotJustDownloadedFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = DictationCoordinator(store: CatalogTestStore(containerURL: directory))
        coordinator.refreshDownloadedModels(isDownloaded: { _ in true })
        for phase in [ModelPreparationPhase.idle, .downloading, .preparing, .failed] {
            coordinator.modelPreparation = .init(phase: phase, status: "Not ready")
            XCTAssertFalse(coordinator.isTranscriptionModelReady)
            XCTAssertFalse(coordinator.canRetrySavedVoiceNote)
            XCTAssertFalse(coordinator.canStartNotepadBurst(sessionID: UUID()))
            XCTAssertNil(coordinator.startMeetingRecording())
            XCTAssertFalse(coordinator.isRecording)
            XCTAssertNil(coordinator.activeMeetingSessionID)
        }
        coordinator.modelPreparation = .init(phase: .ready, status: "Ready")
        XCTAssertTrue(coordinator.isTranscriptionModelReady)
        XCTAssertTrue(coordinator.canRetrySavedVoiceNote)
        coordinator.isRemovingTranscriptionModel = true
        XCTAssertFalse(coordinator.isTranscriptionModelReady)
    }

    @MainActor
    func testOpeningRecordingSurfacePreservesPreparationAndFailureState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = DictationCoordinator(store: CatalogTestStore(containerURL: directory))
        for phase in [ModelPreparationPhase.downloading, .preparing, .ready, .failed] {
            let state = ModelPreparationState(phase: phase, progress: 0.4, status: "Current stage", detail: "Details")
            coordinator.modelPreparation = state
            coordinator.ensureModelReadyForRecording()
            XCTAssertEqual(coordinator.modelPreparation, state)
        }
    }

    @MainActor
    func testOnboardingCannotRecordWhileModelLoads() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = DictationCoordinator(store: CatalogTestStore(containerURL: directory))
        coordinator.modelPreparation = .init(phase: .preparing, status: "Loading")
        coordinator.startOnboardingTestDictation()
        XCTAssertFalse(coordinator.isOnboardingTestRecording)
    }

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
            LocalTranscriptionModel.parakeetModels.count + LocalTranscriptionModel.whisperModels.count + 1
        )
    }

    func testEverySelectableModelHasABackgroundDownloadPlan() {
        XCTAssertTrue(
            LocalTranscriptionModel.allCases.filter { $0 != .appleSpeech }.allSatisfy {
                ModelBackgroundDownloadService.supportsBackgroundDownload($0)
            }
        )
    }

    func testPreparationPolicyDownloadsBeforeAttemptingWarmup() {
        XCTAssertEqual(
            ModelPreparationPolicy.action(isDownloaded: false),
            .startBackgroundDownload
        )
        XCTAssertEqual(
            ModelPreparationPolicy.action(isDownloaded: true),
            .warmDownloadedModel
        )
    }

    func testFluidAudioDownloadRequiresCompleteModelsAndVocabulary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-fluidaudio-integrity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let modelNames: Set<String> = ["Encoder.mlmodelc", "Decoder.mlmodelc"]
        let supportingFiles: Set<String> = ["parakeet_vocab.json"]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for modelName in modelNames {
            let modelDirectory = root.appendingPathComponent(modelName, isDirectory: true)
            try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
            try Data("model".utf8).write(to: modelDirectory.appendingPathComponent("coremldata.bin"))
        }

        XCTAssertFalse(
            ModelBackgroundDownloadService.containsCompleteFluidAudioArtifacts(
                at: root,
                modelNames: modelNames,
                supportingFiles: supportingFiles
            ),
            "Compiled models without their vocabulary must not be treated as transcription-ready."
        )

        try Data("{}".utf8).write(to: root.appendingPathComponent("parakeet_vocab.json"))
        XCTAssertTrue(
            ModelBackgroundDownloadService.containsCompleteFluidAudioArtifacts(
                at: root,
                modelNames: modelNames,
                supportingFiles: supportingFiles
            )
        )

        try FileManager.default.removeItem(
            at: root.appendingPathComponent("Encoder.mlmodelc/coremldata.bin")
        )
        XCTAssertFalse(
            ModelBackgroundDownloadService.containsCompleteFluidAudioArtifacts(
                at: root,
                modelNames: modelNames,
                supportingFiles: supportingFiles
            ),
            "A partially downloaded CoreML directory must not enter the inference path."
        )
    }

    func testLocalParakeetVocabularySupportsBothShippedFormats() throws {
        let arrayVocabulary = try FluidAudioTranscriptionEngine.decodeParakeetVocabulary(
            Data("[\"blank\",\"hello\"]".utf8)
        )
        XCTAssertEqual(arrayVocabulary, [0: "blank", 1: "hello"])

        let dictionaryVocabulary = try FluidAudioTranscriptionEngine.decodeParakeetVocabulary(
            Data("{\"0\":\"blank\",\"42\":\"hello\"}".utf8)
        )
        XCTAssertEqual(dictionaryVocabulary, [0: "blank", 42: "hello"])

        XCTAssertThrowsError(
            try FluidAudioTranscriptionEngine.decodeParakeetVocabulary(Data("[1]".utf8))
        )
    }

    func testEveryModelHasAnIsolatedStorageDirectory() {
        let directories = LocalTranscriptionModel.allCases.compactMap {
            ModelBackgroundDownloadService.storageDirectory(for: $0)?.standardizedFileURL.path
        }

        XCTAssertEqual(directories.count, LocalTranscriptionModel.allCases.count - 1)
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

        var plan = ModelDownloadTransaction(id: currentAttemptID, modelRawValue: LocalTranscriptionModel.parakeetV3.rawValue,
            manifest: .init(source: .mirror, version: "v1", files: [currentFile]))
        XCTAssertFalse(plan.accepts(staleFile))
        XCTAssertTrue(plan.accepts(currentFile))
        plan.phase = .failed
        XCTAssertFalse(plan.accepts(currentFile), "Failure must reject late success callbacks")
        plan.phase = .needsFallback
        XCTAssertFalse(plan.accepts(currentFile), "Fallback must reject the old source's callbacks")
    }

}
