import AVFoundation
import XCTest
@testable import Muesli

final class AudioImportTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testInboxOwnsAudioAfterSourceIsRemoved() throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("Meeting.mp3")
        let contents = Data([1, 2, 3, 4])
        try contents.write(to: source)
        let item = try AudioImportInbox.enqueue(source, root: root)
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(try AudioImportInbox.items(root: root).map(\.id), [item.id])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(item.id.uuidString).appendingPathComponent(item.fileName)), contents)
        XCTAssertEqual(item.title, "Meeting")
    }

    func testInboxDoesNotPublishFailedCopyOrUnsupportedFile() throws {
        let root = try temporaryDirectory()
        XCTAssertThrowsError(try AudioImportInbox.enqueue(root.appendingPathComponent("missing.wav"), root: root))
        XCTAssertThrowsError(try AudioImportInbox.enqueue(root.appendingPathComponent("note.txt"), root: root))
        XCTAssertTrue(try AudioImportInbox.items(root: root).isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testInboxIgnoresIncompleteAndPathTraversalEntries() throws {
        let root = try temporaryDirectory()
        let id = UUID()
        let directory = root.appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertTrue(try AudioImportInbox.items(root: root).isEmpty)
        let item = AudioImportInbox.Item(id: id, title: "Invalid", fileName: "../../private.wav")
        try JSONEncoder().encode(item).write(to: directory.appendingPathComponent("item.json"))
        XCTAssertTrue(try AudioImportInbox.items(root: root).isEmpty)
    }

    func testStereoImportConvertsToMono16kAndPreservesSource() async throws {
        let source = try temporaryDirectory().appendingPathComponent("stereo.wav")
        try writeAudio(to: source)
        let (output, duration) = try await AudioFileImporter.convert(sourceURL: source)
        defer { try? FileManager.default.removeItem(at: output) }
        let audio = try AVAudioFile(forReading: output)
        XCTAssertEqual(audio.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(audio.fileFormat.channelCount, 1)
        XCTAssertEqual(duration, 1, accuracy: 0.05)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertNotEqual(source, output)
    }

    func testInvalidAudioFailsWithoutTouchingSource() async throws {
        let source = try temporaryDirectory().appendingPathComponent("invalid.mp3")
        try Data("not audio".utf8).write(to: source)
        do {
            let (output, _) = try await AudioFileImporter.convert(sourceURL: source)
            try? FileManager.default.removeItem(at: output)
            XCTFail("Invalid audio must fail conversion")
        } catch { XCTAssertTrue(FileManager.default.fileExists(atPath: source.path)) }
    }

    func testCancelledConversionDoesNotReturnAudio() async throws {
        let source = try temporaryDirectory().appendingPathComponent("cancel.wav")
        try writeAudio(to: source)
        let task = Task {
            try Task.checkCancellation()
            return try await AudioFileImporter.convert(sourceURL: source)
        }
        task.cancel()
        do {
            let (output, _) = try await task.value
            try? FileManager.default.removeItem(at: output)
            XCTFail("Cancelled import completed")
        } catch is CancellationError { }
    }

    func testAppleSpeechUsesSystemAssetsInsteadOfModelDownloadDirectory() {
        XCTAssertNil(ModelBackgroundDownloadService.storageDirectory(for: .appleSpeech))
        XCTAssertFalse(ModelBackgroundDownloadService.supportsBackgroundDownload(.appleSpeech))
        XCTAssertEqual(LocalTranscriptionModel.appleSpeech.family, .apple)
    }

    private func writeAudio(to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let writer = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        buffer.frameLength = 48_000
        for channel in 0..<2 {
            for frame in 0..<48_000 {
                buffer.floatChannelData![channel][frame] = Float(sin(Double(frame) * 2 * .pi * 440 / 48_000)) * 0.1
            }
        }
        try writer.write(from: buffer)
    }
}
