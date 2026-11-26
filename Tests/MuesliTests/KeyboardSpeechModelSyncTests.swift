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

    func testOneFailedCopyDoesNotHideTheModelsThatCopied() throws {
        let missing = source.deletingLastPathComponent().appendingPathComponent("missing", isDirectory: true)
        let plan = KeyboardSpeechModelSync.Plan(entries: [
            .init(source: source, manifest: manifest("parakeet-redux")),
            .init(source: missing, manifest: manifest("nemotron-3.5")),
            .init(source: source, manifest: manifest("phonon-2.5")),
        ])

        XCTAssertEqual(KeyboardSpeechModelSync.apply(plan, container: container), "partial")

        XCTAssertEqual(Muesli.KeyboardSpeechModel.readCatalog(in: container)?.models.map(\.modelID), ["parakeet-redux", "phonon-2.5"])
    }

    func testWhisperTokenizerIsCopiedIntoTheSharedModel() throws {
        let tokenizer = source.deletingLastPathComponent().appendingPathComponent("tokenizer.json")
        try Data("{}".utf8).write(to: tokenizer)
        let plan = KeyboardSpeechModelSync.Plan(entries: [
            .init(source: source, manifest: manifest("whisper-tiny-en"), extraFiles: [tokenizer]),
        ])

        _ = KeyboardSpeechModelSync.apply(plan, container: container)

        let shared = try XCTUnwrap(Muesli.KeyboardSpeechModel.modelDirectory(for: "whisper-tiny-en", in: container))
        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.appendingPathComponent("tokenizer.json").path))
    }

    func testATokenizerChangesTheFingerprintSoAFailedCopyIsRetried() {
        let plain = KeyboardSpeechModelSync.fingerprint(of: source)
        XCTAssertEqual(KeyboardSpeechModelSync.fingerprint(of: source, extraFiles: []), plain)
        let withTokenizer = KeyboardSpeechModelSync.fingerprint(
            of: source,
            extraFiles: [URL(fileURLWithPath: "/hf/tokenizer.json")]
        )
        XCTAssertNotEqual(withTokenizer, plain)

        let defaults = UserDefaults(suiteName: "fingerprint-\(UUID().uuidString)")!
        let failed = KeyboardSpeechModel.Manifest(
            modelID: "whisper-tiny", displayName: "Whisper", engineIdentifier: "whisper",
            version: .whisper, sourceFingerprint: plain
        )
        KeyboardSpeechModel.markUnsupported(failed, in: defaults)
        var repaired = failed
        repaired.sourceFingerprint = withTokenizer
        XCTAssertTrue(KeyboardSpeechModel.isUnsupported(failed, in: defaults))
        XCTAssertFalse(KeyboardSpeechModel.isUnsupported(repaired, in: defaults))
    }

    func testTokenizerFetchedLaterIsAddedToTheSharedModel() throws {
        let tokenizer = source.deletingLastPathComponent().appendingPathComponent("tokenizer.json")
        _ = KeyboardSpeechModelSync.apply(.init(entries: [.init(source: source, manifest: manifest("whisper-tiny-en"))]),
                                          container: container)
        try Data("{}".utf8).write(to: tokenizer)

        let outcome = KeyboardSpeechModelSync.apply(
            .init(entries: [.init(source: source, manifest: manifest("whisper-tiny-en"), extraFiles: [tokenizer])]),
            container: container
        )

        XCTAssertEqual(outcome, "shared", "an unchanged model missing its tokenizer is re-shared")
        let shared = try XCTUnwrap(Muesli.KeyboardSpeechModel.modelDirectory(for: "whisper-tiny-en", in: container))
        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.appendingPathComponent("tokenizer.json").path))
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
    private func guardManifest(_ id: String, _ print: String) -> KeyboardSpeechModel.Manifest {
        .init(modelID: id, displayName: id, engineIdentifier: id, version: .redux, sourceFingerprint: print)
    }

    func testKeyboardSkipsAModelWhoseLastLoadNeverFinished() throws {
        let suite = "keyboard-model-guard-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let redux = guardManifest("parakeet-redux", "10-20")

        XCTAssertFalse(KeyboardSpeechModel.previousLoadDidNotFinish(manifest: redux, in: defaults))
        KeyboardSpeechModel.beginLoad(redux, in: defaults)
        XCTAssertTrue(KeyboardSpeechModel.previousLoadDidNotFinish(manifest: redux, in: defaults))
        XCTAssertFalse(KeyboardSpeechModel.previousLoadDidNotFinish(manifest: guardManifest("parakeet-redux", "11-20"), in: defaults),
                       "a new download is tried again")

        KeyboardSpeechModel.endLoad(redux, in: defaults)
        XCTAssertFalse(KeyboardSpeechModel.previousLoadDidNotFinish(manifest: redux, in: defaults))
    }

    func testLoadingAnotherModelKeepsTheCrashRecord() throws {
        let suite = "keyboard-model-guard-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let crashed = guardManifest("nemotron-3.5", "1")
        let other = guardManifest("parakeet-redux", "1")

        KeyboardSpeechModel.beginLoad(crashed, in: defaults)   // the keyboard was ended here
        KeyboardSpeechModel.beginLoad(other, in: defaults)
        KeyboardSpeechModel.endLoad(other, in: defaults)

        XCTAssertTrue(KeyboardSpeechModel.previousLoadDidNotFinish(manifest: crashed, in: defaults))
        XCTAssertFalse(KeyboardSpeechModel.previousLoadDidNotFinish(manifest: other, in: defaults))
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
        XCTAssertTrue(KeyboardSpeechModel.isUnsupported(manifest("whisper-large-turbo", "1"), in: defaults),
                      "the keyboard checks this before every load, so it never loads the model again")
        XCTAssertFalse(KeyboardSpeechModel.isUnsupported(manifest("whisper-large-turbo", "2"), in: defaults))

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
        let phonon = guardManifest("phonon-2.5", "1-2")
        KeyboardSpeechModel.beginLoad(phonon, in: defaults)

        KeyboardSpeechModel.endLoad(phonon, in: defaults)   // what unload() does

        XCTAssertFalse(KeyboardSpeechModel.previousLoadDidNotFinish(manifest: phonon, in: defaults))
    }
}

final class KeyboardDiagnosticsBudgetTests: XCTestCase {
    func testTrimNeverExceedsATinyBudget() {
        let text = (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n"
        for budget in [0, 1, 10] {
            XCTAssertLessThanOrEqual(KeyboardDiagnosticsLog.newestLines(of: text, fittingIn: budget).utf8.count, budget)
        }
    }

    func testSmallBudgetStillKeepsTheNewestLines() {
        let text = (1...40).map { "line \(String(format: "%02d", $0))" }.joined(separator: "\n") + "\n"

        let trimmed = KeyboardDiagnosticsLog.newestLines(of: text, fittingIn: 64)

        XCTAssertLessThanOrEqual(trimmed.utf8.count, 64)
        XCTAssertTrue(trimmed.hasSuffix("line 40\n"), "the newest entry is kept")
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
