import AVFoundation
import XCTest
#if canImport(MuesliDev)
@testable import MuesliDev
private typealias ImportStore = MuesliDev.SharedStore
private typealias ImportSession = MuesliDev.RecordingSession
private typealias ImportPhase = MuesliDev.RecordingSessionPhase
private typealias ImportDestination = MuesliDev.AudioImportDestination
#else
@testable import Muesli
private typealias ImportStore = Muesli.SharedStore
private typealias ImportSession = Muesli.RecordingSession
private typealias ImportPhase = Muesli.RecordingSessionPhase
private typealias ImportDestination = Muesli.AudioImportDestination
#endif

final class AudioImportTests: XCTestCase {
    func testImportDestinationPreservesIntentRegardlessOfDuration() throws {
        let store = SharedStore(containerURL: try temporaryDirectory())
        for duration in [6.0, 7_200.0] {
            for destination in [AudioImportDestination.voiceNote, .meeting] {
                let id = UUID()
                let session = destination.session(id: id, title: "Imported audio",
                    duration: duration, audioFileName: "audio.wav")
                try store.saveSession(session)
                let saved = try XCTUnwrap(store.activeRecordingSession(id: id))
                XCTAssertEqual(saved.kind, destination == .voiceNote ? .quickDictation : .meeting)
                XCTAssertEqual(saved.requestID, destination == .voiceNote ? id : nil)
                XCTAssertEqual(saved.phase, .transcriptionQueued)
                XCTAssertTrue(saved.keepsAudioRecording)
                XCTAssertTrue(saved.protectedAudioUntilTranscriptCompletes)
                XCTAssertFalse(saved.isLongForm)
                var interrupted = saved
                interrupted.phase = .failed
                XCTAssertEqual(interrupted.canRetryVoiceNoteTranscription, destination == .voiceNote)
            }
        }
    }

    @MainActor
    func testLaunchRecoversInterruptedImportsWithoutChangingVoiceNoteIntent() async throws {
        let store = ImportStore(containerURL: try temporaryDirectory())
        var originals: [ImportSession] = []
        for phase in [ImportPhase.transcriptionQueued, .transcribing] {
            let id = UUID()
            let audioURL = try store.newAudioFileURL(sessionID: id)
            try writeAudio(to: audioURL)
            var session = ImportDestination.voiceNote.session(id: id, title: "Monologue",
                duration: 1, audioFileName: audioURL.lastPathComponent)
            session.phase = phase
            try store.saveSession(session)
            originals.append(session)
        }
        let coordinator = DictationCoordinator(store: store)
        // Launch recovery validates actual saved audio asynchronously.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if try originals.allSatisfy({ try store.activeRecordingSession(id: $0.id)?.phase == .failed }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        for original in originals {
            let recovered = try XCTUnwrap(store.activeRecordingSession(id: original.id))
            XCTAssertEqual(recovered.phase, .failed)
            XCTAssertTrue(recovered.canRetryVoiceNoteTranscription)
            XCTAssertEqual(recovered.kind, .quickDictation)
            XCTAssertFalse(recovered.isLongForm)
            XCTAssertEqual(recovered.audioFileName, original.audioFileName)
            XCTAssertEqual(recovered.requestID, original.requestID)
            coordinator.openLongVoiceNote(recovered)
            XCTAssertNil(coordinator.presentedLongVoiceNoteSessionID)
        }
    }

    @MainActor
    func testImportHandoffRechecksBusyAndModelStateAfterConversion() throws {
        let coordinator = DictationCoordinator(store: ImportStore(containerURL: try temporaryDirectory()))
        coordinator.modelPreparation = .init(phase: .ready, status: "Ready")
        XCTAssertTrue(coordinator.canImportAudio)
        // The import itself must not block its own post-conversion handoff.
        coordinator.isImportingAudio = true
        XCTAssertNoThrow(try coordinator.validateAudioImportHandoff())
        coordinator.isRecording = true
        XCTAssertThrowsError(try coordinator.validateAudioImportHandoff())
        coordinator.isRecording = false
        coordinator.statusText = "Transcribing"
        XCTAssertThrowsError(try coordinator.validateAudioImportHandoff())
        coordinator.statusText = "Ready"
        coordinator.modelPreparation = .init(phase: .idle, status: "")
        XCTAssertThrowsError(try coordinator.validateAudioImportHandoff())
        coordinator.modelPreparation = .init(phase: .ready, status: "Ready")
        XCTAssertNoThrow(try coordinator.validateAudioImportHandoff())
    }

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

    func testVoicemailRateWAVAndCompressedM4AConvert() async throws {
        let root = try temporaryDirectory()
        for (name, rate, codec) in [("voicemail.wav", 8_000.0, kAudioFormatLinearPCM),
                                    ("voicemail.m4a", 16_000.0, kAudioFormatMPEG4AAC)] {
            let source = root.appendingPathComponent(name)
            try writeVoicemailFixture(to: source, rate: rate, codec: codec)
            let (wav, duration) = try await AudioFileImporter.convert(sourceURL: source)
            defer { try? FileManager.default.removeItem(at: wav) }
            XCTAssertEqual(duration, 1, accuracy: 0.15)
            let file = try AVAudioFile(forReading: wav)
            XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
            XCTAssertEqual(file.fileFormat.channelCount, 1)
        }
    }

    private func writeVoicemailFixture(to url: URL, rate: Double, codec: AudioFormatID) throws {
        let settings: [String: Any] = [AVFormatIDKey: codec, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1]
        let writer = try AVAudioFile(forWriting: url, settings: settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: writer.processingFormat, frameCapacity: AVAudioFrameCount(rate))!
        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<Int(buffer.frameLength) {
            buffer.floatChannelData![0][frame] = Float(sin(Double(frame) * 2 * .pi * 440 / rate)) * 0.1
        }
        try writer.write(from: buffer)
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
