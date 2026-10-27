import CryptoKit
import XCTest
#if canImport(MuesliDev)
@testable import MuesliDev
#else
@testable import Muesli
#endif

final class ModelDownloadManifestTests: XCTestCase {
    private let digest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    private func payload() -> [String: Any] {
        ["format": "muesli-r2-model-manifest-v1", "modelID": "tiny.en", "version": "legacy-local-v1",
         "files": ["AudioEncoder.mlmodelc/coremldata.bin", "TextDecoder.mlmodelc/coremldata.bin", "MelSpectrogram.mlmodelc/coremldata.bin", "config.json", "generation_config.json"].map {
             ["relativePath": $0,
              "objectKey": "models/whisperkit/openai_whisper-tiny.en/legacy-local-v1/files/\($0)",
              "bytes": 3, "sha256": digest] as [String: Any]
         }]
    }

    private func decode(_ payload: [String: Any]) throws -> ModelDownloadManifest {
        try ModelDownloadManifest.decodeMirror(JSONSerialization.data(withJSONObject: payload),
            url: XCTUnwrap(ModelDownloadManifest.mirrorURL(for: .whisperTinyEnglish)),
            spec: XCTUnwrap(ModelDownloadSpec(model: .whisperTinyEnglish)))
    }

    func testMirrorCoverageMatchesPublishedModels() {
        for model in LocalTranscriptionModel.whisperModels + [.parakeetV3, .parakeetUnified] {
            XCTAssertNotNil(ModelDownloadManifest.mirrorURL(for: model))
        }
        XCTAssertNil(ModelDownloadManifest.mirrorURL(for: .parakeetTdtCtc110m))
        XCTAssertNil(ModelDownloadManifest.mirrorURL(for: .parakeetRealtimeEou120m))
    }

    func testUnifiedDownloadsOnlyOfflineInt8Assets() throws {
        let spec = try XCTUnwrap(ModelDownloadSpec(model: .parakeetUnified))
        XCTAssertEqual(spec.requiredModels, ["parakeet_unified_encoder_int8.mlmodelc",
            "parakeet_unified_decoder.mlmodelc", "parakeet_unified_joint_decision_single_step.mlmodelc"])
        XCTAssertEqual(spec.requiredSupportingFiles, ["vocab.json", "metadata.json"])
        XCTAssertTrue(spec.shouldDownloadFile("parakeet_unified_encoder_int8.mlmodelc/weights/weight.bin"))
        XCTAssertFalse(spec.shouldDownloadFile("parakeet_unified_encoder.mlmodelc/weights/weight.bin"))
        XCTAssertFalse(spec.shouldDownloadFile("parakeet_unified_encoder_streaming_70_2_2_int8.mlmodelc/weights/weight.bin"))
        XCTAssertEqual(LocalTranscriptionModel.parakeetUnified.family, .parakeet)
        XCTAssertFalse(LocalTranscriptionModel.parakeetUnified.supportsRealtimeStreaming)
        XCTAssertNil(LocalTranscriptionModel.parakeetUnified.asrVersion)
        XCTAssertEqual(LocalTranscriptionModel.parakeetUnified.estimatedSizeLabel, "~614 MB")
        XCTAssertEqual(LocalTranscriptionModel.defaultModel, .parakeetTdtCtc110m)
    }

    func testManifestIdentityPathsAndCoverageAreValidated() throws {
        XCTAssertEqual(try decode(payload()).files.count, 5)
        var wrong = payload(); wrong["modelID"] = "small.en"
        XCTAssertThrowsError(try decode(wrong))
        wrong = payload(); wrong["files"] = [] as [[String: Any]]
        XCTAssertThrowsError(try decode(wrong))
        for badPath in ["../escape", "/absolute", "x//y", "x/%2e%2e/y", "x\\y", "x\ny"] {
            wrong = payload()
            var files = wrong["files"] as! [[String: Any]]
            files[0]["relativePath"] = badPath
            wrong["files"] = files
            XCTAssertThrowsError(try decode(wrong), badPath)
        }
        wrong = payload()
        var files = wrong["files"] as! [[String: Any]]
        files[0]["objectKey"] = "models/another-release/files/model.bin"
        wrong["files"] = files
        XCTAssertThrowsError(try decode(wrong))
        wrong = payload(); files = wrong["files"] as! [[String: Any]]
        files.append(files[0]); wrong["files"] = files
        XCTAssertThrowsError(try decode(wrong))
    }

    func testRejectsSameSizeCorruptionAndWrongSize() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("weights")
        let file = try XCTUnwrap(decode(payload()).files.first)
        try Data("abc".utf8).write(to: url)
        XCTAssertNoThrow(try ModelDownloadManifest.validate(file, at: url))
        try Data("abd".utf8).write(to: url)
        XCTAssertThrowsError(try ModelDownloadManifest.validate(file, at: url))
        try Data("abcd".utf8).write(to: url)
        XCTAssertThrowsError(try ModelDownloadManifest.validate(file, at: url))
    }

    func testHuggingFaceGitBlobChecksumIncludesHeader() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let content = Data("abc".utf8)
        try content.write(to: url)
        let digest = Insecure.SHA1.hash(data: Data("blob 3\0".utf8) + content).map { String(format: "%02x", $0) }.joined()
        let file = ModelDownloadFile(remotePath: "config.json", localPath: "config.json", remoteURL: URL(string: "https://huggingface.co/config.json")!, size: 3, gitSHA1: digest)
        XCTAssertNoThrow(try ModelDownloadManifest.validate(file, at: url))
        try Data("bad".utf8).write(to: url)
        XCTAssertThrowsError(try ModelDownloadManifest.validate(file, at: url))
    }

    func testMissingChecksumCannotCertifyDownloadedFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("abc".utf8).write(to: url)
        let file = ModelDownloadFile(remotePath: "weights", localPath: "weights",
            remoteURL: URL(string: "https://assets.muesli.works/weights")!, size: 3)
        XCTAssertThrowsError(try ModelDownloadManifest.validate(file, at: url))
    }

    func testFallbackUsesFreshGenerationAndStageAfterJournalRoundTrip() throws {
        let mirror = try decode(payload())
        var tx = ModelDownloadTransaction(id: UUID(), modelRawValue: LocalTranscriptionModel.whisperTinyEnglish.rawValue, manifest: mirror)
        tx.completed.insert(mirror.files[0].localPath)
        tx.phase = .needsFallback
        let restored = try JSONDecoder().decode(ModelDownloadTransaction.self, from: JSONEncoder().encode(tx))
        XCTAssertEqual(restored.phase, .needsFallback)
        XCTAssertEqual(restored.completed, tx.completed)
        let destination = URL(fileURLWithPath: "/tmp/models/tiny")
        let originalStage = tx.stagingDirectory(for: destination)
        let originalID = tx.id
        tx.useFallback(.init(source: .huggingFace, version: "pinned-sha", files: mirror.files))
        XCTAssertNotEqual(tx.id, originalID)
        XCTAssertNotEqual(tx.stagingDirectory(for: destination), originalStage)
        XCTAssertTrue(tx.completed.isEmpty)
        XCTAssertEqual(tx.retiredStages, [originalID])
        XCTAssertEqual(tx.manifest.source, .huggingFace)
    }

    func testFailedInstallRestoresExistingModelAndInterruptedSwapRecovers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("installed")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: destination.appendingPathComponent("model"))
        XCTAssertThrowsError(try ModelDownloadTransaction.install(staging: root.appendingPathComponent("missing"), destination: destination))
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("model"), encoding: .utf8), "old")
        try FileManager.default.moveItem(at: destination, to: ModelDownloadTransaction.backupDirectory(for: destination))
        try ModelDownloadTransaction.recoverInstallation(at: destination)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("model"), encoding: .utf8), "old")
        let staging = root.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: staging.appendingPathComponent("model"))
        try ModelDownloadTransaction.install(staging: staging, destination: destination)
        try ModelDownloadTransaction.rollbackInstallation(staging: staging, destination: destination)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("model"), encoding: .utf8), "old")
        XCTAssertEqual(try String(contentsOf: staging.appendingPathComponent("model"), encoding: .utf8), "new")
    }

    func testFailedOrReplacedAttemptRejectsLateBackgroundCallbacks() throws {
        let manifest = try decode(payload())
        var tx = ModelDownloadTransaction(id: UUID(), modelRawValue: LocalTranscriptionModel.whisperTinyEnglish.rawValue, manifest: manifest)
        let description = manifest.files[0].taskDescription(model: .whisperTinyEnglish, attemptID: tx.id)
        let callback = try XCTUnwrap(ModelDownloadFile(taskDescription: description))
        XCTAssertTrue(tx.accepts(callback))
        tx.phase = .failed
        XCTAssertFalse(tx.accepts(callback))
        tx.phase = .needsFallback
        XCTAssertFalse(tx.accepts(callback))
        tx.useFallback(.init(source: .huggingFace, version: "commit", files: manifest.files))
        XCTAssertFalse(tx.accepts(callback))
        let restored = try JSONDecoder().decode(ModelDownloadTransaction.self, from: JSONEncoder().encode(tx))
        XCTAssertEqual(restored.manifest.files[0].sha256, digest)
    }
}
