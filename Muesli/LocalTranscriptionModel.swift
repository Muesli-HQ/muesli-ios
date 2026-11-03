import FluidAudio
import Foundation
import Speech

enum LocalTranscriptionModel: String, CaseIterable, Identifiable, Codable, Sendable {
    case appleSpeech = "apple-speech"
    case parakeetTdtCtc110m = "parakeet-tdt-ctc-110m"
    case parakeetRealtimeEou120m = "parakeet-realtime-eou-120m"
    case parakeetV3 = "parakeet-v3"
    case parakeetRedux = "parakeet-redux"
    case phonon25 = "phonon-2.5"
    case nemotron35 = "nemotron-3.5"
    case parakeetUnified = "parakeet-unified"
    case whisperTinyEnglish = "whisper-tiny-en"
    case whisperSmallEnglish = "whisper-small-en"
    case whisperMediumEnglish = "whisper-medium-en"
    case whisperLargeTurbo = "whisper-large-turbo"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .parakeetRedux: "Parakeet Redux"
        case .phonon25: "Phonon-2.5"
        case .nemotron35: "Nemotron 3.5"
        case .appleSpeech: "Apple Speech"
        case .parakeetUnified:
            "Parakeet Unified"
        case .parakeetTdtCtc110m:
            "Parakeet Compact"
        case .parakeetRealtimeEou120m:
            "Parakeet Realtime"
        case .parakeetV3:
            "Parakeet v3"
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
        case .parakeetRedux: "Parakeet Redux"
        case .phonon25: "Phonon-2.5"
        case .nemotron35: "Nemotron 3.5"
        case .appleSpeech: "Apple Speech"
        case .parakeetUnified:
            "Parakeet Unified"
        case .parakeetTdtCtc110m:
            "Parakeet Compact"
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

    var keyboardCatalogOption: KeyboardTranscriptionModelOption {
        KeyboardTranscriptionModelOption(
            rawValue: rawValue,
            displayName: displayName,
            shortName: shortName,
            capabilityLabel: capabilityLabel,
            isReady: isDownloaded
        )
    }

    var detail: String {
        switch self {
        case .parakeetRedux: "Compact multilingual transcription in 25 languages."
        case .phonon25: "Multilingual transcription with a smaller download."
        case .nemotron35: "Live multilingual transcription with automatic language detection."
        case .appleSpeech: "Private, on-device transcription in your iPhone’s language. Language assets are managed by iOS."
        case .parakeetUnified:
            "English transcription with punctuation and capitalization. Results appear after recording."
        case .parakeetTdtCtc110m:
            "English transcription with faster setup and a smaller download."
        case .parakeetRealtimeEou120m:
            "Live English transcription for voice notes and meetings."
        case .parakeetV3:
            "Multilingual transcription with broad language coverage."
        case .whisperTinyEnglish:
            "Smallest English WhisperKit model. Fastest download and lightest storage footprint."
        case .whisperSmallEnglish:
            "Fast English Whisper model with a practical accuracy and storage balance."
        case .whisperMediumEnglish:
            "Higher-accuracy English Whisper model for longer recordings, with a larger download."
        case .whisperLargeTurbo:
            "Our most accurate multilingual Whisper option."
        }
    }

    var capabilityLabel: String {
        switch self {
        case .parakeetRedux, .phonon25: "Multilingual"
        case .nemotron35: "Multilingual realtime"
        case .appleSpeech: Locale.current.localizedString(forIdentifier: Locale.current.identifier) ?? Locale.current.identifier
        case .parakeetUnified:
            "English only"
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
        case .parakeetRedux: "~220 MB"
        case .phonon25: "~290 MB"
        case .nemotron35: "~665 MB"
        case .appleSpeech: "Managed by iOS"
        case .parakeetUnified:
            "~614 MB"
        case .parakeetTdtCtc110m:
            "Compact download"
        case .parakeetRealtimeEou120m:
            "Streaming model"
        case .parakeetV3:
            "~450 MB"
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
        case .parakeetRedux: "parakeet-redux"
        case .phonon25: "phonon-2.5"
        case .nemotron35: "nemotron-3.5"
        case .appleSpeech: "apple-speech"
        case .parakeetUnified:
            "parakeet-unified"
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
        case .parakeetRedux: .redux
        case .phonon25: .v3
        case .nemotron35: nil
        case .appleSpeech: nil
        case .parakeetUnified:
            nil
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
        case .parakeetRedux, .phonon25, .nemotron35: nil
        case .appleSpeech: nil
        case .parakeetRealtimeEou120m:
            .parakeetEou320ms
        case .parakeetUnified, .parakeetTdtCtc110m, .parakeetV3,
             .whisperTinyEnglish, .whisperSmallEnglish, .whisperMediumEnglish, .whisperLargeTurbo:
            nil
        }
    }

    var supportsRealtimeStreaming: Bool {
        self == .nemotron35 || streamingVariant != nil
    }

    var family: LocalTranscriptionModelFamily {
        switch self {
        case .parakeetRedux: .parakeet
        case .phonon25: .phonon
        case .nemotron35: .nemotron
        case .appleSpeech: .apple
        case .parakeetUnified, .parakeetTdtCtc110m, .parakeetRealtimeEou120m, .parakeetV3:
            .parakeet
        case .whisperTinyEnglish, .whisperSmallEnglish, .whisperMediumEnglish, .whisperLargeTurbo:
            .whisper
        }
    }

    var whisperVariant: String? {
        switch self {
        case .parakeetRedux, .phonon25, .nemotron35: nil
        case .appleSpeech: nil
        case .whisperTinyEnglish:
            "tiny.en"
        case .whisperSmallEnglish:
            "small.en"
        case .whisperMediumEnglish:
            "medium.en"
        case .whisperLargeTurbo:
            "large-v3-v20240930_626MB"
        case .parakeetUnified, .parakeetTdtCtc110m, .parakeetRealtimeEou120m, .parakeetV3:
            nil
        }
    }

    var isDownloaded: Bool {
        if self == .appleSpeech { return AppleSpeechAssetState.shared.isPrepared }
        return ModelBackgroundDownloadService.isModelDownloaded(self)
    }

    var isAvailable: Bool {
        if self == .parakeetRedux || self == .phonon25 || self == .nemotron35 {
            if #available(iOS 18, *) { return true }
            return false
        }
        if self != .appleSpeech { return true }
        if #available(iOS 26, *) { return SpeechTranscriber.isAvailable }
        return false
    }
    static var availableModels: [Self] { allCases.filter(\.isAvailable) }

    static let parakeetModels = allCases.filter { $0.family == .parakeet }
    static let whisperModels = allCases.filter { $0.family == .whisper }

    static let defaultModel: LocalTranscriptionModel = .parakeetTdtCtc110m
}

enum LocalTranscriptionModelFamily: String, CaseIterable, Identifiable {
    case parakeet
    case phonon
    case nemotron
    case whisper
    case apple

    var id: String { rawValue }

    var title: String {
        switch self {
        case .phonon: "Phonon"
        case .nemotron: "Nemotron"
        case .parakeet:
            "Parakeet"
        case .apple: "Apple"
        case .whisper:
            "WhisperKit"
        }
    }

    var models: [LocalTranscriptionModel] {
        switch self {
        case .parakeet:
            LocalTranscriptionModel.parakeetModels.filter(\.isAvailable)
        case .phonon: LocalTranscriptionModel.availableModels.filter { $0.family == .phonon }
        case .nemotron: LocalTranscriptionModel.availableModels.filter { $0.family == .nemotron }
        case .apple: LocalTranscriptionModel.availableModels.filter { $0.family == .apple }
        case .whisper:
            LocalTranscriptionModel.whisperModels
        }
    }
}

/// iOS owns these assets. Never persist a filesystem-style "downloaded" flag across launches.
final class AppleSpeechAssetState: @unchecked Sendable {
    static let shared = AppleSpeechAssetState()
    private let lock = NSLock()
    private var localeIdentifier: String?
    var isPrepared: Bool {
        lock.lock(); defer { lock.unlock() }
        return localeIdentifier == Locale.current.identifier
    }
    func markPrepared() {
        lock.lock(); defer { lock.unlock() }
        localeIdentifier = Locale.current.identifier
    }
}
