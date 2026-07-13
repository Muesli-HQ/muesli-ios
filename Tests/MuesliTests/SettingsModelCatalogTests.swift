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
}
