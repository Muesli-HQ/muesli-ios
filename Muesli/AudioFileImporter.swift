import AVFoundation
import Foundation
import FluidAudio

/// Ported from the macOS importer: bounded-memory decoding to mono 16 kHz PCM.
enum AudioFileImporter {
    enum ImportError: LocalizedError {
        case noAudioTracks, conversionFailed(String), readError(String)
        var errorDescription: String? {
            switch self {
            case .noAudioTracks: "This file does not contain readable audio."
            case .conversionFailed(let detail), .readError(let detail): "Could not import audio. \(detail)"
            }
        }
    }
    static func convert(sourceURL: URL,
                        didWriteSamples: (@Sendable (URL) async -> Void)? = nil) async throws -> (URL, TimeInterval) {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: sourceURL)
        let tracks = try await asset.load(.tracks)
        guard let audioTrack = tracks.first(where: { $0.mediaType == .audio }) else {
            throw ImportError.noAudioTracks
        }

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw ImportError.conversionFailed("Could not read audio samples from the selected file.")
        }
        reader.add(output)

        guard reader.startReading() else {
            throw ImportError.readError(reader.error?.localizedDescription ?? "Unknown read error")
        }
        defer { reader.cancelReading() }

        let wavURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: wavURL) } }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let writer = try AVAudioFile(forWriting: wavURL, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
        ])

        let converter = AudioConverter()
        var frameCount = 0
        while reader.status == .reading {
            try Task.checkCancellation()
            let didRead = try autoreleasepool {
                guard let sampleBuffer = output.copyNextSampleBuffer() else { return false }
                let samples = try converter.resampleSampleBuffer(sampleBuffer)
                guard !samples.isEmpty else { return true }
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
                    throw ImportError.conversionFailed("Could not allocate conversion buffer.")
                }
                buffer.frameLength = AVAudioFrameCount(samples.count)
                samples.withUnsafeBufferPointer { source in
                    buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
                }
                try writer.write(from: buffer)
                frameCount += samples.count
                return true
            }
            if !didRead { break }
            if let didWriteSamples { await didWriteSamples(wavURL) }
        }

        guard reader.status == .completed else {
            throw ImportError.readError(reader.error?.localizedDescription ?? "Read did not complete")
        }
        try Task.checkCancellation()
        guard frameCount > 0 else { throw ImportError.noAudioTracks }
        completed = true
        return (wavURL, Double(frameCount) / 16_000)
    }

    /// The source stays owned by the caller until this task has finished, even
    /// when cancellation arrives during a synchronous filesystem copy.
    static func copyConvertedAudio(from source: URL, to destination: URL) async throws {
        let copy = Task.detached(priority: .utility) {
            var completed = false
            defer { if !completed { try? FileManager.default.removeItem(at: destination) } }
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
            try Task.checkCancellation()
            completed = true
        }
        try await withTaskCancellationHandler {
            try await copy.value
        } onCancel: { copy.cancel() }
    }
}
