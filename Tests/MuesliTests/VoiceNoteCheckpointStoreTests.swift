import AVFoundation
import XCTest
@testable import Muesli

final class VoiceNoteCheckpointStoreTests: XCTestCase {
    func testManifestSortsChunksAndPersistsFrameCounts() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let first = try writeChunk(index: 0, duration: 0.1, directory: fixture.directory)
        let second = try writeChunk(index: 1, duration: 0.1, directory: fixture.directory)
        _ = try await fixture.checkpoints.record(second, sessionID: fixture.sessionID)
        let manifest = try await fixture.checkpoints.record(first, sessionID: fixture.sessionID)

        XCTAssertEqual(manifest.entries.map(\.index), [0, 1])
        XCTAssertTrue(manifest.entries.allSatisfy { $0.frameCount > 0 })
        let persistedManifest = try await fixture.checkpoints.manifest(sessionID: fixture.sessionID)
        XCTAssertEqual(persistedManifest, manifest)
    }

    func testReconstructsContinuousAudioFromOrderedChunks() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        for index in 0..<2 {
            let chunk = try writeChunk(index: index, duration: 0.1, directory: fixture.directory)
            _ = try await fixture.checkpoints.record(chunk, sessionID: fixture.sessionID)
        }
        let output = fixture.root.appendingPathComponent("reconstructed.wav")

        _ = try await fixture.checkpoints.reconstructAudio(
            sessionID: fixture.sessionID,
            destinationURL: output
        )

        let file = try AVAudioFile(forReading: output)
        XCTAssertEqual(file.length, 3_200, accuracy: 2)
        try assertReopenableProtection(at: output)
    }

    func testRecoveryStopsAtMissingChunkInsteadOfAppendingLaterAudio() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        for index in [0, 2] {
            let chunk = try writeChunk(index: index, duration: 0.1, directory: fixture.directory)
            _ = try await fixture.checkpoints.record(chunk, sessionID: fixture.sessionID)
        }
        let output = fixture.root.appendingPathComponent("contiguous.wav")

        _ = try await fixture.checkpoints.reconstructAudio(
            sessionID: fixture.sessionID,
            destinationURL: output
        )

        XCTAssertEqual(try AVAudioFile(forReading: output).length, 1_600, accuracy: 2)
    }

    func testRecordRejectsCorruptCheckpoint() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let corruptURL = fixture.directory.appendingPathComponent("chunk-0000.wav")
        let corruptBytes = Data("not audio".utf8)
        try corruptBytes.write(to: corruptURL)
        let corrupt = Muesli.MeetingAudioChunk(index: 0, url: corruptURL, startTime: 0, duration: 0.1)

        do {
            _ = try await fixture.checkpoints.record(corrupt, sessionID: fixture.sessionID)
            XCTFail("Corrupt checkpoint should not be added to the manifest")
        } catch Muesli.VoiceNoteCheckpointStore.StoreError.invalidCheckpoint {
            let manifest = try await fixture.checkpoints.manifest(sessionID: fixture.sessionID)
            XCTAssertTrue(manifest.entries.isEmpty)
            XCTAssertEqual(try Data(contentsOf: corruptURL), corruptBytes)
        }
    }

    func testRecoveryIgnoresCorruptUnmanifestedTrailingChunk() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let first = try writeChunk(index: 0, duration: 0.1, directory: fixture.directory)
        _ = try await fixture.checkpoints.record(first, sessionID: fixture.sessionID)
        let corruptURL = fixture.directory.appendingPathComponent("chunk-0001.wav")
        try Data("not audio".utf8).write(to: corruptURL)
        let output = fixture.root.appendingPathComponent("salvaged.wav")

        _ = try await fixture.checkpoints.reconstructAudio(
            sessionID: fixture.sessionID,
            destinationURL: output
        )

        XCTAssertEqual(try AVAudioFile(forReading: output).length, 1_600, accuracy: 2)
    }

    func testRecoveryAddsValidUnmanifestedTrailingChunkAfterProcessDeath() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let first = try writeChunk(index: 0, duration: 0.1, directory: fixture.directory)
        _ = try await fixture.checkpoints.record(first, sessionID: fixture.sessionID)
        _ = try writeChunk(index: 1, duration: 0.1, directory: fixture.directory)

        let salvaged = try await fixture.checkpoints.salvageTrailingCheckpoint(
            sessionID: fixture.sessionID
        )

        XCTAssertEqual(salvaged.entries.map(\.index), [0, 1])
        XCTAssertTrue(salvaged.entries.allSatisfy { $0.frameCount > 0 })
    }

    func testRecoveryRepairsZeroSizedTrailingPCMWAVHeader() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let chunk = try writeChunk(index: 0, duration: 0.1, directory: fixture.directory)
        let original = try Data(contentsOf: chunk.url)
        let payloadOffset = try XCTUnwrap(wavDataPayloadOffset(in: original))
        let originalPayload = original[payloadOffset...]
        var unfinalized = original
        writeUInt32(0, to: &unfinalized, at: 4)
        writeUInt32(0, to: &unfinalized, at: payloadOffset - 4)
        try unfinalized.write(to: chunk.url, options: .atomic)

        let unreadable = try? AVAudioFile(forReading: chunk.url)
        XCTAssertTrue(unreadable == nil || unreadable?.length == 0)

        let salvaged = try await fixture.checkpoints.salvageTrailingCheckpoint(
            sessionID: fixture.sessionID
        )

        XCTAssertEqual(salvaged.entries.map(\.index), [0])
        XCTAssertEqual(salvaged.entries.first?.frameCount, 1_600)
        let repaired = try Data(contentsOf: chunk.url)
        XCTAssertNotEqual(readUInt32(from: repaired, at: 4), 0)
        XCTAssertNotEqual(readUInt32(from: repaired, at: payloadOffset - 4), 0)
        XCTAssertEqual(repaired[payloadOffset...], originalPayload)
        XCTAssertEqual(try AVAudioFile(forReading: chunk.url).length, 1_600)
    }

    func testPrimaryContinuousAudioRecoversStaleHeaderBeforeFirstCheckpoint() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let manifestBeforeRecovery = try await fixture.checkpoints.manifest(sessionID: fixture.sessionID)
        XCTAssertTrue(manifestBeforeRecovery.entries.isEmpty)

        let primaryURL = fixture.root.appendingPathComponent("continuous-primary.wav")
        let sampleRate = 16_000.0
        let frameCount: AVAudioFrameCount = 1_600
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ))
        let buffer = try makeBuffer(format: format, frameCount: frameCount)
        do {
            let file = try AVAudioFile(forWriting: primaryURL, settings: format.settings)
            try file.write(from: buffer)
        }

        let original = try Data(contentsOf: primaryURL)
        let payloadOffset = try XCTUnwrap(wavDataPayloadOffset(in: original))
        let originalPayload = original[payloadOffset...]
        var unfinalized = original
        writeUInt32(0, to: &unfinalized, at: 4)
        writeUInt32(0, to: &unfinalized, at: payloadOffset - 4)
        try unfinalized.write(to: primaryURL, options: .atomic)

        let unreadable = try? AVAudioFile(forReading: primaryURL)
        XCTAssertTrue(unreadable == nil || unreadable?.length == 0)

        let recovered = await fixture.checkpoints.isReadableAudio(at: primaryURL)

        XCTAssertTrue(recovered)
        let manifestAfterRecovery = try await fixture.checkpoints.manifest(sessionID: fixture.sessionID)
        XCTAssertTrue(manifestAfterRecovery.entries.isEmpty)
        let repaired = try Data(contentsOf: primaryURL)
        XCTAssertNotEqual(readUInt32(from: repaired, at: 4), 0)
        XCTAssertNotEqual(readUInt32(from: repaired, at: payloadOffset - 4), 0)
        XCTAssertEqual(repaired[payloadOffset...], originalPayload)
        XCTAssertEqual(try AVAudioFile(forReading: primaryURL).length, AVAudioFramePosition(frameCount))
    }

    func testSalvageLeavesIrrecoverableTrailingCheckpointAndManifestUntouched() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let first = try writeChunk(index: 0, duration: 0.1, directory: fixture.directory)
        let originalManifest = try await fixture.checkpoints.record(first, sessionID: fixture.sessionID)
        let manifestURL = fixture.directory.appendingPathComponent("manifest.json")
        let manifestBytes = try Data(contentsOf: manifestURL)
        let corruptURL = fixture.directory.appendingPathComponent("chunk-0001.wav")
        let corruptBytes = Data("irrecoverable trailing checkpoint".utf8)
        try corruptBytes.write(to: corruptURL)

        let salvaged = try await fixture.checkpoints.salvageTrailingCheckpoint(
            sessionID: fixture.sessionID
        )

        XCTAssertEqual(salvaged, originalManifest)
        XCTAssertEqual(try Data(contentsOf: manifestURL), manifestBytes)
        XCTAssertEqual(try Data(contentsOf: corruptURL), corruptBytes)
    }

    func testConcurrentRecordAndSalvageRemainOrderedAndDeduplicated() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let first = try writeChunk(index: 0, duration: 0.1, directory: fixture.directory)
        _ = try writeChunk(index: 1, duration: 0.1, directory: fixture.directory)
        async let recorded = fixture.checkpoints.record(first, sessionID: fixture.sessionID)
        async let salvaged = fixture.checkpoints.salvageTrailingCheckpoint(sessionID: fixture.sessionID)
        _ = try await (recorded, salvaged)

        let manifest = try await fixture.checkpoints.manifest(sessionID: fixture.sessionID)
        XCTAssertEqual(manifest.entries.map(\.index), [0, 1])
        XCTAssertEqual(Set(manifest.entries.map(\.index)).count, manifest.entries.count)
    }

    func testCheckpointWriterCancellationRemovesRotatedChunksAndContinuousAudio() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-writer-cancel-\(UUID().uuidString)", isDirectory: true)
        let checkpointDirectory = root.appendingPathComponent("checkpoints", isDirectory: true)
        let continuousURL = root.appendingPathComponent("continuous.wav")
        defer { try? FileManager.default.removeItem(at: root) }

        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let writer = try Muesli.CheckpointingAudioWriter(
            continuousAudioURL: continuousURL,
            checkpointDirectory: checkpointDirectory,
            format: format
        )
        writer.append(try makeBuffer(format: format, frameCount: 1_600))
        let rotated = try XCTUnwrap(writer.rotateCheckpoint())
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotated.url.path))
        try assertReopenableProtection(at: rotated.url)
        try assertReopenableProtection(at: continuousURL)

        writer.cancel()

        XCTAssertFalse(FileManager.default.fileExists(atPath: checkpointDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: continuousURL.path))
    }

    func testCheckpointWriterAcknowledgesOnlyAfterAudioIsAccepted() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-writer-ack-\(UUID().uuidString)", isDirectory: true)
        let checkpointDirectory = root.appendingPathComponent("checkpoints", isDirectory: true)
        let continuousURL = root.appendingPathComponent("continuous.wav")
        defer { try? FileManager.default.removeItem(at: root) }

        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let writer = try Muesli.CheckpointingAudioWriter(
            continuousAudioURL: continuousURL,
            checkpointDirectory: checkpointDirectory,
            format: format
        )
        let accepted = DispatchSemaphore(value: 0)

        writer.append(try makeBuffer(format: format, frameCount: 1_600)) {
            accepted.signal()
        }

        XCTAssertEqual(accepted.wait(timeout: .now() + 1), .success)
        let result = writer.finish()
        XCTAssertEqual(result.totalFrames, 1_600)
        XCTAssertNil(result.failure)
    }

    private func makeFixture() async throws -> (
        root: URL,
        directory: URL,
        sessionID: UUID,
        checkpoints: Muesli.VoiceNoteCheckpointStore
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-checkpoints-\(UUID().uuidString)", isDirectory: true)
        let store = Muesli.SharedStore(containerURL: root)
        let sessionID = UUID()
        let checkpoints = Muesli.VoiceNoteCheckpointStore(store: store)
        let directory = try await checkpoints.prepare(sessionID: sessionID, startedAt: .now)
        return (root, directory, sessionID, checkpoints)
    }

    private func writeChunk(index: Int, duration: TimeInterval, directory: URL) throws -> Muesli.MeetingAudioChunk {
        let sampleRate = 16_000.0
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        if let samples = buffer.floatChannelData?[0] {
            for frame in 0..<Int(frameCount) {
                samples[frame] = sin(Float(frame) * 0.03) * 0.1
            }
        }
        let url = directory.appendingPathComponent(String(format: "chunk-%04d.wav", index))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return Muesli.MeetingAudioChunk(
            index: index,
            url: url,
            startTime: Double(index) * duration,
            duration: duration
        )
    }

    private func makeBuffer(format: AVAudioFormat, frameCount: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        if let samples = buffer.floatChannelData?[0] {
            for frame in 0..<Int(frameCount) {
                samples[frame] = sin(Float(frame) * 0.03) * 0.1
            }
        }
        return buffer
    }

    private func wavDataPayloadOffset(in data: Data) -> Int? {
        guard data.count >= 12,
              String(decoding: data[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: data[8..<12], as: UTF8.self) == "WAVE"
        else { return nil }
        var cursor = 12
        while cursor + 8 <= data.count {
            let identifier = String(decoding: data[cursor..<(cursor + 4)], as: UTF8.self)
            let size = Int(readUInt32(from: data, at: cursor + 4))
            if identifier == "data" {
                return cursor + 8
            }
            let next = cursor + 8 + size + (size % 2)
            guard next > cursor, next <= data.count else { return nil }
            cursor = next
        }
        return nil
    }

    private func readUInt32(from data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private func writeUInt32(_ value: UInt32, to data: inout Data, at offset: Int) {
        data[offset] = UInt8(truncatingIfNeeded: value)
        data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        data[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        data[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    private func fileProtection(at url: URL) throws -> FileProtectionType? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.protectionKey]
            as? FileProtectionType
    }

    private func assertReopenableProtection(at url: URL) throws {
        XCTAssertEqual(
            SharedFileProtection.reopenableAudio,
            .completeUntilFirstUserAuthentication
        )
        // CoreSimulator does not surface NSFileProtectionKey. When the host does
        // expose it (including device-hosted tests), verify the applied attribute.
        if let protection = try fileProtection(at: url) {
            XCTAssertEqual(protection, SharedFileProtection.reopenableAudio)
        }
    }
}
