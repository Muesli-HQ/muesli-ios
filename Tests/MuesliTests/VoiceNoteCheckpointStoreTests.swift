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

    func testRecoveryIgnoresCorruptTrailingChunk() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let first = try writeChunk(index: 0, duration: 0.1, directory: fixture.directory)
        _ = try await fixture.checkpoints.record(first, sessionID: fixture.sessionID)
        let corruptURL = fixture.directory.appendingPathComponent("chunk-0001.wav")
        try Data("not audio".utf8).write(to: corruptURL)
        let corrupt = Muesli.MeetingAudioChunk(index: 1, url: corruptURL, startTime: 0.1, duration: 0.1)
        _ = try await fixture.checkpoints.record(corrupt, sessionID: fixture.sessionID)
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
}
