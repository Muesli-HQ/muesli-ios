import FluidAudio
import Foundation

enum LocalTranscriptionModel: String, CaseIterable, Identifiable, Sendable {
    case parakeetTdtCtc110m = "parakeet-tdt-ctc-110m"
    case parakeetRealtimeEou120m = "parakeet-realtime-eou-120m"
    case parakeetV3 = "parakeet-v3"
    case whisperTinyEnglish = "whisper-tiny-en"
    case whisperSmallEnglish = "whisper-small-en"
    case whisperMediumEnglish = "whisper-medium-en"
    case whisperLargeTurbo = "whisper-large-turbo"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .parakeetTdtCtc110m:
            "Parakeet 110M"
        case .parakeetRealtimeEou120m:
            "Parakeet Realtime EOU 120M"
        case .parakeetV3:
            "Parakeet v3 600M"
        case .whisperTinyEnglish:
            "Whisper Tiny English"
        case .whisperSmallEnglish:
            "Whisper Small English"
        case .whisperMediumEnglish:
            "Whisper Medium English"
        case .whisperLargeTurbo:
            "Whisper Large Turbo"
        }
    }

    var shortName: String {
        switch self {
        case .parakeetTdtCtc110m:
            "Parakeet 110M"
        case .parakeetRealtimeEou120m:
            "Parakeet Realtime"
        case .parakeetV3:
            "Parakeet v3"
        case .whisperTinyEnglish:
            "Whisper Tiny"
        case .whisperSmallEnglish:
            "Whisper Small"
        case .whisperMediumEnglish:
            "Whisper Medium"
        case .whisperLargeTurbo:
            "Whisper Turbo"
        }
    }

    var detail: String {
        switch self {
        case .parakeetTdtCtc110m:
            "English-only CoreML model. Faster first setup and lighter on storage."
        case .parakeetRealtimeEou120m:
            "English-only CoreML streaming model with end-of-utterance detection for low-latency voice notes and meeting chunks."
        case .parakeetV3:
            "Larger multilingual CoreML model. Better coverage, slower first setup."
        case .whisperTinyEnglish:
            "Smallest English WhisperKit model. Fastest download and lightest storage footprint."
        case .whisperSmallEnglish:
            "Fast English Whisper model with a practical accuracy and storage balance."
        case .whisperMediumEnglish:
            "Higher-accuracy English Whisper model for longer recordings, with a larger download."
        case .whisperLargeTurbo:
            "Highest-accuracy multilingual Whisper option, quantized for faster CoreML inference."
        }
    }

    var capabilityLabel: String {
        switch self {
        case .parakeetTdtCtc110m:
            "English only"
        case .parakeetRealtimeEou120m:
            "English realtime"
        case .parakeetV3:
            "Multilingual"
        case .whisperTinyEnglish, .whisperSmallEnglish, .whisperMediumEnglish:
            "English only"
        case .whisperLargeTurbo:
            "Multilingual"
        }
    }

    var estimatedSizeLabel: String {
        switch self {
        case .parakeetTdtCtc110m:
            "Smaller 110M model"
        case .parakeetRealtimeEou120m:
            "120M streaming model"
        case .parakeetV3:
            "~450 MB 600M model"
        case .whisperTinyEnglish:
            "~153 MB"
        case .whisperSmallEnglish:
            "~250 MB"
        case .whisperMediumEnglish:
            "~1.5 GB"
        case .whisperLargeTurbo:
            "~626 MB"
        }
    }

    var engineIdentifier: String {
        switch self {
        case .parakeetTdtCtc110m:
            "parakeet-tdt-ctc-110m"
        case .parakeetRealtimeEou120m:
            "parakeet-realtime-eou-120m"
        case .parakeetV3:
            "parakeet-v3"
        case .whisperTinyEnglish:
            "whisper-tiny-en"
        case .whisperSmallEnglish:
            "whisper-small-en"
        case .whisperMediumEnglish:
            "whisper-medium-en"
        case .whisperLargeTurbo:
            "whisper-large-turbo"
        }
    }

    var asrVersion: AsrModelVersion? {
        switch self {
        case .parakeetTdtCtc110m:
            .tdtCtc110m
        case .parakeetRealtimeEou120m:
            nil
        case .parakeetV3:
            .v3
        case .whisperTinyEnglish, .whisperSmallEnglish, .whisperMediumEnglish, .whisperLargeTurbo:
            nil
        }
    }

    var streamingVariant: StreamingModelVariant? {
        switch self {
        case .parakeetRealtimeEou120m:
            .parakeetEou320ms
        case .parakeetTdtCtc110m, .parakeetV3,
             .whisperTinyEnglish, .whisperSmallEnglish, .whisperMediumEnglish, .whisperLargeTurbo:
            nil
        }
    }

    var supportsRealtimeStreaming: Bool {
        streamingVariant != nil
    }

    var family: LocalTranscriptionModelFamily {
        switch self {
        case .parakeetTdtCtc110m, .parakeetRealtimeEou120m, .parakeetV3:
            .parakeet
        case .whisperTinyEnglish, .whisperSmallEnglish, .whisperMediumEnglish, .whisperLargeTurbo:
            .whisper
        }
    }

    var whisperVariant: String? {
        switch self {
        case .whisperTinyEnglish:
            "tiny.en"
        case .whisperSmallEnglish:
            "small.en"
        case .whisperMediumEnglish:
            "medium.en"
        case .whisperLargeTurbo:
            "large-v3-v20240930_626MB"
        case .parakeetTdtCtc110m, .parakeetRealtimeEou120m, .parakeetV3:
            nil
        }
    }

    var isDownloaded: Bool {
        ModelBackgroundDownloadService.isModelDownloaded(self)
    }

    static let parakeetModels = allCases.filter { $0.family == .parakeet }
    static let whisperModels = allCases.filter { $0.family == .whisper }

    static let defaultModel: LocalTranscriptionModel = .parakeetTdtCtc110m
}

enum LocalTranscriptionModelFamily: String, CaseIterable, Identifiable {
    case parakeet
    case whisper

    var id: String { rawValue }

    var title: String {
        switch self {
        case .parakeet:
            "Parakeet"
        case .whisper:
            "WhisperKit"
        }
    }

    var models: [LocalTranscriptionModel] {
        switch self {
        case .parakeet:
            LocalTranscriptionModel.parakeetModels
        case .whisper:
            LocalTranscriptionModel.whisperModels
        }
    }
}
