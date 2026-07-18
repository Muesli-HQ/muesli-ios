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
        case invalidCheckpoint
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
        guard let checkpointFile = readableAudioFile(at: checkpoint.url, repairingTrailingPCMHeader: true) else {
            throw StoreError.invalidCheckpoint
        }
        let frameCount = checkpointFile.length
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
        var recoveredCheckpoint = false
        var startTime = manifest.entries
            .sorted(by: { $0.index < $1.index })
            .last
            .map { $0.startTime + $0.duration } ?? 0

        while true {
            let url = directory
                .appendingPathComponent("chunk-\(String(format: "%04d", expectedIndex))")
                .appendingPathExtension("wav")
            guard FileManager.default.fileExists(atPath: url.path),
                  let file = readableAudioFile(at: url, repairingTrailingPCMHeader: true)
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
            recoveredCheckpoint = true
            expectedIndex += 1
            startTime += duration
        }

        if recoveredCheckpoint {
            manifest.entries.sort { $0.index < $1.index }
            try write(manifest, to: directory)
        }
        return manifest
    }

    func delete(sessionID: UUID) throws {
        try store.deleteVoiceNoteCheckpoints(sessionID: sessionID)
    }

    func checkpointSessionIDs() throws -> [UUID] {
        try store.voiceNoteCheckpointSessionIDs()
    }

    func isReadableAudio(at url: URL) -> Bool {
        readableAudioFile(at: url, repairingTrailingPCMHeader: true) != nil
    }

    func reconstructAudio(sessionID: UUID, destinationURL: URL) throws -> URL {
        let directory = try store.voiceNoteCheckpointDirectoryURL(sessionID: sessionID)
        let manifest = try salvageTrailingCheckpoint(sessionID: sessionID)
        let entries = recoverableContiguousEntries(manifest.entries, directory: directory)
        guard !entries.isEmpty else { throw StoreError.noRecoverableAudio }

        let recoveryURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.deletingPathExtension().lastPathComponent)-recovery-\(UUID().uuidString)")
            .appendingPathExtension(destinationURL.pathExtension.isEmpty ? "wav" : destinationURL.pathExtension)
        try? FileManager.default.removeItem(at: recoveryURL)

        var output: AVAudioFile?
        defer {
            output = nil
            try? FileManager.default.removeItem(at: recoveryURL)
        }
        for entry in entries {
            guard let input = readableAudioFile(
                at: directory.appendingPathComponent(entry.fileName),
                repairingTrailingPCMHeader: true
            ) else { throw StoreError.noRecoverableAudio }
            if output == nil {
                output = try AVAudioFile(forWriting: recoveryURL, settings: input.processingFormat.settings)
                try SharedFileProtection.protectAudio(at: recoveryURL)
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
        guard isReadableAudio(at: recoveryURL) else { throw StoreError.noRecoverableAudio }
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: recoveryURL)
        } else {
            try FileManager.default.moveItem(at: recoveryURL, to: destinationURL)
        }
        try SharedFileProtection.protectAudio(at: destinationURL)
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
        SharedFileProtection.protectMetadataBestEffort(at: url)
        return try decoder.decode(VoiceNoteCheckpointManifest.self, from: Data(contentsOf: url))
    }

    private func write(_ manifest: VoiceNoteCheckpointManifest, to directory: URL) throws {
        let url = directory.appendingPathComponent("manifest.json")
        try encoder.encode(manifest).write(
            to: url,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
        try SharedFileProtection.protectMetadata(at: url)
    }

    private func readableAudioFile(
        at url: URL,
        repairingTrailingPCMHeader: Bool
    ) -> AVAudioFile? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try? SharedFileProtection.protectAudio(at: url)
        if let file = try? AVAudioFile(forReading: url),
           file.length > 0,
           file.processingFormat.sampleRate > 0 {
            return file
        }
        guard repairingTrailingPCMHeader, repairTrailingPCMHeader(at: url) else { return nil }
        guard let repaired = try? AVAudioFile(forReading: url),
              repaired.length > 0,
              repaired.processingFormat.sampleRate > 0
        else { return nil }
        return repaired
    }

    private func repairTrailingPCMHeader(at url: URL) -> Bool {
        let repair: TrailingPCMWAVRepair.RepairPlan
        do {
            guard let candidate = try TrailingPCMWAVRepair.repairPlan(for: url) else {
                return false
            }
            repair = candidate
        } catch {
            return false
        }

        do {
            try TrailingPCMWAVRepair.apply(repair, to: url)
            try SharedFileProtection.protectAudio(at: url)
            guard let repairedFile = try? AVAudioFile(forReading: url),
                  repairedFile.length > 0,
                  repairedFile.processingFormat.sampleRate > 0
            else {
                try? TrailingPCMWAVRepair.restore(repair, at: url)
                try? SharedFileProtection.protectAudio(at: url)
                return false
            }
            return true
        } catch {
            try? TrailingPCMWAVRepair.restore(repair, at: url)
            try? SharedFileProtection.protectAudio(at: url)
            return false
        }
    }

    private func fileModificationDate(at url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}

private enum TrailingPCMWAVRepair {
    struct RepairPlan {
        let riffSizeOffset: UInt64
        let dataSizeOffset: UInt64
        let originalRIFFSize: UInt32
        let originalDataSize: UInt32
        let repairedRIFFSize: UInt32
        let repairedDataSize: UInt32
    }

    private static let riff = Array("RIFF".utf8)
    private static let wave = Array("WAVE".utf8)
    private static let formatChunk = Array("fmt ".utf8)
    private static let dataChunk = Array("data".utf8)
    private static let supportedFormatTags: Set<UInt16> = [1, 3, 0xFFFE]

    static func repairPlan(for url: URL) throws -> RepairPlan? {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let sizeNumber = attributes[.size] as? NSNumber else { return nil }
        let fileSize = sizeNumber.uint64Value
        guard fileSize >= 44,
              fileSize - 8 <= UInt64(UInt32.max)
        else { return nil }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try read(handle, offset: 0, count: 12)
        guard matches(riff, in: header, at: 0),
              matches(wave, in: header, at: 8)
        else { return nil }

        let originalRIFFSize = readUInt32(from: header, at: 4)
        var cursor: UInt64 = 12
        var validPCMFormat = false
        var blockAlignment: UInt64 = 0

        while cursor + 8 <= fileSize {
            let chunkHeader = try read(handle, offset: cursor, count: 8)
            let payloadOffset = cursor + 8
            let declaredSize = UInt64(readUInt32(from: chunkHeader, at: 4))

            if matches(formatChunk, in: chunkHeader, at: 0) {
                guard declaredSize >= 16, payloadOffset + 16 <= fileSize else { return nil }
                let format = try read(handle, offset: payloadOffset, count: 16)
                let formatTag = readUInt16(from: format, at: 0)
                let channels = readUInt16(from: format, at: 2)
                let sampleRate = readUInt32(from: format, at: 4)
                let alignment = readUInt16(from: format, at: 12)
                let bitsPerSample = readUInt16(from: format, at: 14)
                validPCMFormat = supportedFormatTags.contains(formatTag)
                    && channels > 0
                    && sampleRate > 0
                    && alignment > 0
                    && bitsPerSample > 0
                blockAlignment = UInt64(alignment)
            } else if matches(dataChunk, in: chunkHeader, at: 0) {
                guard validPCMFormat, blockAlignment > 0 else { return nil }
                let availableBytes = fileSize - payloadOffset
                let recoveredBytes = availableBytes - (availableBytes % blockAlignment)
                guard recoveredBytes > 0,
                      recoveredBytes <= UInt64(UInt32.max)
                else { return nil }

                let expectedRIFFSize = UInt32(payloadOffset + recoveredBytes - 8)
                let expectedDataSize = UInt32(recoveredBytes)
                let originalDataSize = readUInt32(from: chunkHeader, at: 4)
                guard originalRIFFSize != expectedRIFFSize || originalDataSize != expectedDataSize else {
                    return nil
                }
                return RepairPlan(
                    riffSizeOffset: 4,
                    dataSizeOffset: cursor + 4,
                    originalRIFFSize: originalRIFFSize,
                    originalDataSize: originalDataSize,
                    repairedRIFFSize: expectedRIFFSize,
                    repairedDataSize: expectedDataSize
                )
            }

            let paddedSize = declaredSize + (declaredSize % 2)
            guard payloadOffset <= fileSize,
                  paddedSize <= fileSize - payloadOffset
            else { return nil }
            cursor = payloadOffset + paddedSize
        }
        return nil
    }

    static func apply(_ plan: RepairPlan, to url: URL) throws {
        try writeHeaderSizes(
            riffSize: plan.repairedRIFFSize,
            dataSize: plan.repairedDataSize,
            plan: plan,
            to: url
        )
    }

    static func restore(_ plan: RepairPlan, at url: URL) throws {
        try writeHeaderSizes(
            riffSize: plan.originalRIFFSize,
            dataSize: plan.originalDataSize,
            plan: plan,
            to: url
        )
    }

    private static func matches(_ bytes: [UInt8], in data: Data, at offset: Int) -> Bool {
        guard offset >= 0, offset + bytes.count <= data.count else { return false }
        return bytes.indices.allSatisfy { data[offset + $0] == bytes[$0] }
    }

    private static func readUInt16(from data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32(from data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func read(_ handle: FileHandle, offset: UInt64, count: Int) throws -> Data {
        try handle.seek(toOffset: offset)
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return data
    }

    private static func writeHeaderSizes(
        riffSize: UInt32,
        dataSize: UInt32,
        plan: RepairPlan,
        to url: URL
    ) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        // Write the payload size first. If the process is terminated between
        // writes, the next salvage pass can still derive and finish both values.
        try handle.seek(toOffset: plan.dataSizeOffset)
        try handle.write(contentsOf: littleEndianBytes(dataSize))
        try handle.seek(toOffset: plan.riffSizeOffset)
        try handle.write(contentsOf: littleEndianBytes(riffSize))
        try handle.synchronize()
    }

    private static func littleEndianBytes(_ value: UInt32) -> Data {
        Data([
            UInt8(truncatingIfNeeded: value),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 24),
        ])
    }
}
