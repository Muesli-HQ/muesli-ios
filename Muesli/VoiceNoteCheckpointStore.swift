import AVFoundation
import Foundation

struct VoiceNoteCheckpointManifest: Codable, Sendable, Equatable {
    struct Entry: Codable, Sendable, Equatable {
        let index: Int
        let fileName: String
        let frameCount: Int64
        let startTime: TimeInterval
        let duration: TimeInterval
        let finalizedAt: Date
    }

    let schemaVersion: Int
    let sessionID: UUID
    let startedAt: Date
    var finalizedAt: Date?
    var entries: [Entry]

    init(sessionID: UUID, startedAt: Date) {
        schemaVersion = 1
        self.sessionID = sessionID
        self.startedAt = startedAt
        finalizedAt = nil
        entries = []
    }
}

actor VoiceNoteCheckpointStore {
    enum StoreError: Error {
        case missingManifest
        case noRecoverableAudio
        case incompatibleAudioFormat
    }

    private let store: SharedStore
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(store: SharedStore) {
        self.store = store
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
    }

    func prepare(sessionID: UUID, startedAt: Date) throws -> URL {
        let directory = try store.voiceNoteCheckpointDirectoryURL(sessionID: sessionID)
        try write(VoiceNoteCheckpointManifest(sessionID: sessionID, startedAt: startedAt), to: directory)
        return directory
    }

    func record(_ checkpoint: MeetingAudioChunk, sessionID: UUID) throws -> VoiceNoteCheckpointManifest {
        let directory = try store.voiceNoteCheckpointDirectoryURL(sessionID: sessionID)
        var manifest = try load(from: directory)
        guard !manifest.entries.contains(where: { $0.index == checkpoint.index }) else { return manifest }
        let frameCount = (try? AVAudioFile(forReading: checkpoint.url).length) ?? 0
        manifest.entries.append(.init(
            index: checkpoint.index,
            fileName: checkpoint.url.lastPathComponent,
            frameCount: frameCount,
            startTime: checkpoint.startTime,
            duration: checkpoint.duration,
            finalizedAt: .now
        ))
        manifest.entries.sort { $0.index < $1.index }
        try write(manifest, to: directory)
        return manifest
    }

    func finalize(sessionID: UUID, finalCheckpoint: MeetingAudioChunk?) throws -> VoiceNoteCheckpointManifest {
        if let finalCheckpoint {
            _ = try record(finalCheckpoint, sessionID: sessionID)
        }
        let directory = try store.voiceNoteCheckpointDirectoryURL(sessionID: sessionID)
        var manifest = try load(from: directory)
        manifest.finalizedAt = .now
        try write(manifest, to: directory)
        return manifest
    }

    func manifest(sessionID: UUID) throws -> VoiceNoteCheckpointManifest {
        try load(from: store.voiceNoteCheckpointDirectoryURL(sessionID: sessionID))
    }

    func salvageTrailingCheckpoint(sessionID: UUID) throws -> VoiceNoteCheckpointManifest {
        let directory = try store.voiceNoteCheckpointDirectoryURL(sessionID: sessionID)
        var manifest = try load(from: directory)
        var expectedIndex = (manifest.entries.map(\.index).max() ?? -1) + 1
        var startTime = manifest.entries
            .sorted(by: { $0.index < $1.index })
            .last
            .map { $0.startTime + $0.duration } ?? 0

        while true {
            let url = directory
                .appendingPathComponent("chunk-\(String(format: "%04d", expectedIndex))")
                .appendingPathExtension("wav")
            guard FileManager.default.fileExists(atPath: url.path),
                  let file = try? AVAudioFile(forReading: url),
                  file.length > 0,
                  file.processingFormat.sampleRate > 0
            else { break }

            let duration = Double(file.length) / file.processingFormat.sampleRate
            manifest.entries.append(.init(
                index: expectedIndex,
                fileName: url.lastPathComponent,
                frameCount: file.length,
                startTime: startTime,
                duration: duration,
                finalizedAt: fileModificationDate(at: url) ?? .now
            ))
            expectedIndex += 1
            startTime += duration
        }

        manifest.entries.sort { $0.index < $1.index }
        try write(manifest, to: directory)
        return manifest
    }

    func delete(sessionID: UUID) throws {
        try store.deleteVoiceNoteCheckpoints(sessionID: sessionID)
    }

    func checkpointSessionIDs() throws -> [UUID] {
        try store.voiceNoteCheckpointSessionIDs()
    }

    func isReadableAudio(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              let file = try? AVAudioFile(forReading: url)
        else { return false }
        return file.length > 0
    }

    func reconstructAudio(sessionID: UUID, destinationURL: URL) throws -> URL {
        let directory = try store.voiceNoteCheckpointDirectoryURL(sessionID: sessionID)
        let manifest = try salvageTrailingCheckpoint(sessionID: sessionID)
        let entries = recoverableContiguousEntries(manifest.entries, directory: directory)
        guard !entries.isEmpty else { throw StoreError.noRecoverableAudio }

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        var output: AVAudioFile?
        for entry in entries {
            let input = try AVAudioFile(forReading: directory.appendingPathComponent(entry.fileName))
            if output == nil {
                output = try AVAudioFile(forWriting: destinationURL, settings: input.processingFormat.settings)
            } else if output?.processingFormat.sampleRate != input.processingFormat.sampleRate
                        || output?.processingFormat.channelCount != input.processingFormat.channelCount {
                throw StoreError.incompatibleAudioFormat
            }
            while input.framePosition < input.length {
                let remaining = input.length - input.framePosition
                let capacity = AVAudioFrameCount(min(remaining, 8_192))
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: input.processingFormat,
                    frameCapacity: capacity
                ) else { throw StoreError.noRecoverableAudio }
                try input.read(into: buffer, frameCount: capacity)
                guard buffer.frameLength > 0 else { break }
                try output?.write(from: buffer)
            }
        }
        output = nil
        guard isReadableAudio(at: destinationURL) else { throw StoreError.noRecoverableAudio }
        return destinationURL
    }

    private func contiguousEntries(
        _ entries: [VoiceNoteCheckpointManifest.Entry]
    ) -> [VoiceNoteCheckpointManifest.Entry] {
        var expected = 0
        var contiguous: [VoiceNoteCheckpointManifest.Entry] = []
        for entry in entries.sorted(by: { $0.index < $1.index }) {
            guard entry.index == expected else { break }
            contiguous.append(entry)
            expected += 1
        }
        return contiguous
    }

    private func recoverableContiguousEntries(
        _ entries: [VoiceNoteCheckpointManifest.Entry],
        directory: URL
    ) -> [VoiceNoteCheckpointManifest.Entry] {
        var recoverable: [VoiceNoteCheckpointManifest.Entry] = []
        for entry in contiguousEntries(entries) {
            let url = directory.appendingPathComponent(entry.fileName)
            guard isReadableAudio(at: url) else { break }
            recoverable.append(entry)
        }
        return recoverable
    }

    private func load(from directory: URL) throws -> VoiceNoteCheckpointManifest {
        let url = directory.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: url.path) else { throw StoreError.missingManifest }
        return try decoder.decode(VoiceNoteCheckpointManifest.self, from: Data(contentsOf: url))
    }

    private func write(_ manifest: VoiceNoteCheckpointManifest, to directory: URL) throws {
        let url = directory.appendingPathComponent("manifest.json")
        try encoder.encode(manifest).write(to: url, options: .atomic)
    }

    private func fileModificationDate(at url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
