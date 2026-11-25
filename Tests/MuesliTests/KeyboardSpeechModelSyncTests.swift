import XCTest
@testable import Muesli

@MainActor
final class KeyboardSpeechModelSyncTests: XCTestCase {
    private var container: URL!
    private var source: URL!

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("keyboard-model-sync-\(UUID().uuidString)")
        container = base.appendingPathComponent("group", isDirectory: true)
        source = base.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: source.appendingPathComponent("Encoder.mlmodelc"))
        try Data("{}".utf8).write(to: source.appendingPathComponent(".muesli-verified-manifest.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: container.deletingLastPathComponent())
    }

    private func manifest(_ id: String = "parakeet-tdt-ctc-110m", fingerprint: String = "1-2") -> Muesli.KeyboardSpeechModel.Manifest {
        .init(modelID: id, displayName: "Parakeet", engineIdentifier: id, version: .tdtCtc110m, sourceFingerprint: fingerprint)
    }

    func testShareClonesModelAndWritesManifestLast() throws {
        let plan = KeyboardSpeechModelSync.Plan.share(source: source, manifest: manifest())

        XCTAssertEqual(KeyboardSpeechModelSync.apply(plan, container: container), "shared")
        XCTAssertEqual(Muesli.KeyboardSpeechModel.readManifest(in: container), manifest())
        let copied = try XCTUnwrap(Muesli.KeyboardSpeechModel.modelDirectory(for: manifest().modelID, in: container))
        XCTAssertEqual(try Data(contentsOf: copied.appendingPathComponent("Encoder.mlmodelc")), Data("weights".utf8))

        XCTAssertEqual(KeyboardSpeechModelSync.apply(plan, container: container), "current", "an unchanged model is not copied again")
    }

    func testSwitchingModelsRemovesTheOldCopy() throws {
        _ = KeyboardSpeechModelSync.apply(.share(source: source, manifest: manifest("parakeet-v3")), container: container)
        _ = KeyboardSpeechModelSync.apply(.share(source: source, manifest: manifest()), container: container)

        let root = try XCTUnwrap(Muesli.KeyboardSpeechModel.rootDirectory(in: container))
        let entries = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        XCTAssertEqual(entries, [Muesli.KeyboardSpeechModel.manifestFileName, "parakeet-tdt-ctc-110m"].sorted())
    }

    func testRemovePlanDeletesSharedModel() throws {
        _ = KeyboardSpeechModelSync.apply(.share(source: source, manifest: manifest()), container: container)

        XCTAssertEqual(KeyboardSpeechModelSync.apply(.remove, container: container), "removed")
        XCTAssertNil(Muesli.KeyboardSpeechModel.readManifest(in: container))
        XCTAssertEqual(KeyboardSpeechModelSync.apply(.remove, container: container), "none")
    }

    func testOnlyCompactParakeetModelsRunInTheKeyboard() {
        XCTAssertEqual(KeyboardSpeechModelSync.keyboardVersion(for: .parakeetTdtCtc110m), .tdtCtc110m)
        XCTAssertEqual(KeyboardSpeechModelSync.keyboardVersion(for: .parakeetV3), .v3)
        XCTAssertNil(KeyboardSpeechModelSync.keyboardVersion(for: .whisperLargeTurbo))
        XCTAssertNil(KeyboardSpeechModelSync.keyboardVersion(for: .appleSpeech))
        guard case .remove = KeyboardSpeechModelSync.makePlan(for: .parakeetV3, isEnabled: false) else {
            return XCTFail("turning in-keyboard dictation off withdraws the shared model")
        }
    }

    func testStatusExplainsWhichEngineTheKeyboardUses() {
        XCTAssertEqual(KeyboardSpeechModelSync.status(selectedModel: .parakeetTdtCtc110m, isEnabled: false), .off)
        if case .appleSpeechOnly = KeyboardSpeechModelSync.status(selectedModel: .whisperLargeTurbo, isEnabled: true) {
        } else {
            XCTFail("Whisper cannot run in the keyboard")
        }
        let small: UInt64 = 80 * 1_048_576
        let large: UInt64 = 177 * 1_048_576
        XCTAssertTrue(Muesli.KeyboardSpeechModel.canHoldModel(memoryLimit: large))
        XCTAssertFalse(Muesli.KeyboardSpeechModel.canHoldModel(memoryLimit: small))
        XCTAssertFalse(Muesli.KeyboardSpeechModel.canHoldModel(memoryLimit: nil))
    }
}

@MainActor
final class KeyboardSpeechModelCrashGuardTests: XCTestCase {
    func testKeyboardSkipsAModelWhoseLastLoadNeverFinished() throws {
        let suite = "keyboard-model-guard-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manifest = KeyboardSpeechModel.Manifest(
            modelID: "parakeet-redux", displayName: "Redux", engineIdentifier: "parakeet-redux",
            version: .redux, sourceFingerprint: "10-20"
        )

        XCTAssertFalse(KeyboardSpeechModel.previousLoadDidNotFinish(manifest: manifest, in: defaults))
        KeyboardSpeechModel.recordKeyboardState(.loading, modelID: manifest.modelID, fingerprint: "10-20", in: defaults)
        XCTAssertTrue(KeyboardSpeechModel.previousLoadDidNotFinish(manifest: manifest, in: defaults))

        var redownloaded = manifest
        redownloaded.sourceFingerprint = "11-20"
        XCTAssertFalse(KeyboardSpeechModel.previousLoadDidNotFinish(manifest: redownloaded, in: defaults), "a new download is tried again")

        KeyboardSpeechModel.recordKeyboardState(.ready, modelID: manifest.modelID, fingerprint: "10-20", in: defaults)
        XCTAssertFalse(KeyboardSpeechModel.previousLoadDidNotFinish(manifest: manifest, in: defaults))
    }
}
