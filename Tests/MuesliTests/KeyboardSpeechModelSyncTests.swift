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

    private func plan(_ ids: String...) -> KeyboardSpeechModelSync.Plan {
        .init(entries: ids.map { .init(source: source, manifest: manifest($0)) })
    }

    func testShareClonesEveryModelAndListsThem() throws {
        XCTAssertEqual(KeyboardSpeechModelSync.apply(plan("parakeet-redux", "nemotron-3.5"), container: container), "shared")

        XCTAssertEqual(Muesli.KeyboardSpeechModel.readCatalog(in: container)?.models.map(\.modelID), ["parakeet-redux", "nemotron-3.5"])
        XCTAssertEqual(Muesli.KeyboardSpeechModel.readManifest(for: "nemotron-3.5", in: container), manifest("nemotron-3.5"))
        XCTAssertNil(Muesli.KeyboardSpeechModel.readManifest(for: "whisper-tiny-en", in: container))
        let copied = try XCTUnwrap(Muesli.KeyboardSpeechModel.modelDirectory(for: "nemotron-3.5", in: container))
        XCTAssertEqual(try Data(contentsOf: copied.appendingPathComponent("Encoder.mlmodelc")), Data("weights".utf8))

        XCTAssertEqual(KeyboardSpeechModelSync.apply(plan("parakeet-redux", "nemotron-3.5"), container: container), "current",
                       "unchanged models are not copied again")
    }

    func testRemovedDownloadsAreWithdrawn() throws {
        _ = KeyboardSpeechModelSync.apply(plan("parakeet-redux", "nemotron-3.5"), container: container)
        _ = KeyboardSpeechModelSync.apply(plan("parakeet-redux"), container: container)

        let root = try XCTUnwrap(Muesli.KeyboardSpeechModel.rootDirectory(in: container))
        let entries = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        XCTAssertEqual(entries, [Muesli.KeyboardSpeechModel.catalogFileName, "parakeet-redux"].sorted())
        XCTAssertNil(Muesli.KeyboardSpeechModel.readManifest(for: "nemotron-3.5", in: container))
    }

    func testNoKeyboardModelsRemovesTheSharedFolder() throws {
        _ = KeyboardSpeechModelSync.apply(plan("parakeet-redux"), container: container)

        XCTAssertEqual(KeyboardSpeechModelSync.apply(.init(entries: []), container: container), "removed")
        XCTAssertNil(Muesli.KeyboardSpeechModel.readCatalog(in: container))
        XCTAssertEqual(KeyboardSpeechModelSync.apply(.init(entries: []), container: container), "none")
    }

    func testEveryDownloadableModelCanBeTriedInTheKeyboard() {
        XCTAssertEqual(KeyboardSpeechModelSync.keyboardVersion(for: .parakeetTdtCtc110m), .tdtCtc110m)
        XCTAssertEqual(KeyboardSpeechModelSync.keyboardVersion(for: .parakeetV3), .v3)
        XCTAssertEqual(KeyboardSpeechModelSync.keyboardVersion(for: .phonon25), .phonon)
        XCTAssertEqual(KeyboardSpeechModelSync.keyboardVersion(for: .parakeetUnified), .unified)
        XCTAssertEqual(KeyboardSpeechModelSync.keyboardVersion(for: .nemotron35), .nemotron)
        XCTAssertEqual(KeyboardSpeechModelSync.keyboardVersion(for: .parakeetRealtimeEou120m), .eou320)
        XCTAssertEqual(KeyboardSpeechModelSync.keyboardVersion(for: .whisperLargeTurbo), .whisper)
        XCTAssertNil(KeyboardSpeechModelSync.keyboardVersion(for: .appleSpeech), "Apple Speech runs natively, nothing to share")
        XCTAssertNil(KeyboardSpeechModelSync.keyboardVersion(for: .appleSpeech))
        let shared = KeyboardSpeechModelSync.makePlan(
            models: [.appleSpeech],
            isDownloaded: { _ in true }
        )
        XCTAssertTrue(shared.entries.isEmpty, "Apple Speech has no files to share")
    }

    func testKeyboardMemoryLimitGate() {
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

    func testFailedModelsAreNotRunnableUntilRedownloaded() throws {
        let suite = "keyboard-model-guard-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("runnable-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: container) }
        let root = try XCTUnwrap(KeyboardSpeechModel.rootDirectory(in: container))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func manifest(_ id: String, _ print: String) -> KeyboardSpeechModel.Manifest {
            .init(modelID: id, displayName: id, engineIdentifier: id, version: .whisper, sourceFingerprint: print)
        }
        func share(_ models: [KeyboardSpeechModel.Manifest]) throws {
            try JSONEncoder().encode(KeyboardSpeechModel.Catalog(models: models))
                .write(to: root.appendingPathComponent(KeyboardSpeechModel.catalogFileName))
        }
        try share([manifest("whisper-tiny-en", "1"), manifest("whisper-large-turbo", "1")])
        XCTAssertEqual(KeyboardSpeechModel.runnableModelIDs(in: container, defaults: defaults), ["whisper-tiny-en", "whisper-large-turbo"])

        KeyboardSpeechModel.markUnsupported(manifest("whisper-large-turbo", "1"), in: defaults)
        XCTAssertEqual(KeyboardSpeechModel.runnableModelIDs(in: container, defaults: defaults), ["whisper-tiny-en"])

        try share([manifest("whisper-tiny-en", "1"), manifest("whisper-large-turbo", "2")])
        XCTAssertEqual(KeyboardSpeechModel.runnableModelIDs(in: container, defaults: defaults), ["whisper-tiny-en", "whisper-large-turbo"],
                       "a new download is offered again")

        KeyboardSpeechModel.recordMemoryLimit(80 * 1_048_576, in: defaults)
        XCTAssertEqual(KeyboardSpeechModel.runnableModelIDs(in: container, defaults: defaults), [], "too little keyboard memory for any model")
    }

    func testDeliberateUnloadIsNotMistakenForACrash() throws {
        let suite = "keyboard-model-guard-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manifest = KeyboardSpeechModel.Manifest(
            modelID: "phonon-2.5", displayName: "Phonon", engineIdentifier: "phonon-2.5",
            version: .phonon, sourceFingerprint: "1-2"
        )
        KeyboardSpeechModel.recordKeyboardState(.loading, modelID: manifest.modelID, fingerprint: "1-2", in: defaults)

        KeyboardSpeechModel.clearKeyboardState(ifLoading: manifest.modelID, in: defaults)

        XCTAssertFalse(KeyboardSpeechModel.previousLoadDidNotFinish(manifest: manifest, in: defaults))
    }
}

final class TaskDeadlineTests: XCTestCase {
    func testReturnsAtTheDeadlineEvenIfTheTaskNeverFinishes() async {
        let stuck = Task<Void, Never> { try? await Task.sleep(for: .seconds(3_600)) }
        defer { stuck.cancel() }
        let started = ContinuousClock.now

        let finished = await TaskDeadline.wait(for: stuck, limit: .milliseconds(100))

        XCTAssertFalse(finished)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2), "the wait must not block on the stuck task")
    }

    func testReportsATaskThatFinishesInTime() async {
        let quick = Task<Void, Never> {}
        let finished = await TaskDeadline.wait(for: quick, limit: .seconds(5))
        XCTAssertTrue(finished)
    }
}
