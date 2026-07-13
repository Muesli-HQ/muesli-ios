import Foundation
@preconcurrency import WhisperKit

actor WhisperKitTranscriptionRuntime {
    private var whisperKit: WhisperKit?
    private var loadedVariant: String?

    func load(
        variant: String,
        progress: (@Sendable (Double, String?) -> Void)? = nil
    ) async throws {
        if loadedVariant == variant, whisperKit != nil { return }

        let modelFolder: URL?
        if Self.isModelDownloaded(variant) {
            progress?(0.92, "Loading downloaded Whisper model...")
            modelFolder = nil
        } else {
            let estimatedBytes = Self.estimatedDownloadBytes(for: variant)
            progress?(0.02, "Starting \(Self.formattedSize(estimatedBytes)) download...")
            modelFolder = try await WhisperKit.download(variant: variant) { downloadProgress in
                let fraction = min(max(downloadProgress.fractionCompleted, 0), 1)
                let downloadedBytes = Int64(Double(estimatedBytes) * fraction)
                progress?(
                    max(fraction * 0.9, 0.02),
                    "\(Self.formattedSize(downloadedBytes)) of \(Self.formattedSize(estimatedBytes))"
                )
            }
        }

        progress?(0.94, "Optimizing WhisperKit for this iPhone...")
        let configuration = WhisperKitConfig(
            model: modelFolder == nil ? variant : nil,
            modelFolder: modelFolder?.path,
            computeOptions: ModelComputeOptions(
                audioEncoderCompute: .cpuAndNeuralEngine,
                textDecoderCompute: .cpuAndNeuralEngine
            )
        )
        whisperKit = try await WhisperKit(configuration)
        loadedVariant = variant
        progress?(1, "Whisper model ready")
    }

    func transcribe(audioURL: URL) async throws -> String {
        guard let whisperKit else {
            throw WhisperKitRuntimeError.notLoaded
        }
        let results = try await whisperKit.transcribe(audioPath: audioURL.path)
        return results
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func unload() async {
        await whisperKit?.unloadModels()
        whisperKit = nil
        loadedVariant = nil
    }

    static func isModelDownloaded(_ variant: String) -> Bool {
        FileManager.default.fileExists(atPath: modelDirectory(for: variant).path)
    }

    static func modelDirectory(for variant: String) -> URL {
        let fullName = variant.hasPrefix("openai_whisper-")
            ? variant
            : "openai_whisper-\(variant)"
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("huggingface", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(fullName, isDirectory: true)
    }

    private static func estimatedDownloadBytes(for variant: String) -> Int64 {
        switch variant {
        case "tiny.en":
            153 * 1_000_000
        case "small.en":
            250 * 1_000_000
        case "medium.en":
            1_500 * 1_000_000
        case "large-v3-v20240930_626MB":
            626 * 1_000_000
        default:
            250 * 1_000_000
        }
    }

    private static func formattedSize(_ bytes: Int64) -> String {
        let megabytes = Double(bytes) / 1_000_000
        if megabytes >= 1_000 {
            return String(format: "%.1f GB", megabytes / 1_000)
        }
        if megabytes >= 100 {
            return "\(Int(megabytes.rounded())) MB"
        }
        return String(format: "%.1f MB", megabytes)
    }
}

private enum WhisperKitRuntimeError: LocalizedError {
    case notLoaded

    var errorDescription: String? {
        "WhisperKit model is not loaded."
    }
}
