import FluidAudio
import Foundation

enum LocalTranscriptionModel: String, CaseIterable, Identifiable {
    case parakeetTdtCtc110m = "parakeet-tdt-ctc-110m"
    case parakeetV3 = "parakeet-v3"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .parakeetTdtCtc110m:
            "Parakeet 110M"
        case .parakeetV3:
            "Parakeet v3 600M"
        }
    }

    var shortName: String {
        switch self {
        case .parakeetTdtCtc110m:
            "Parakeet 110M"
        case .parakeetV3:
            "Parakeet v3"
        }
    }

    var detail: String {
        switch self {
        case .parakeetTdtCtc110m:
            "English-only CoreML model. Faster first setup and lighter on storage."
        case .parakeetV3:
            "Larger multilingual CoreML model. Better coverage, slower first setup."
        }
    }

    var capabilityLabel: String {
        switch self {
        case .parakeetTdtCtc110m:
            "English only"
        case .parakeetV3:
            "Multilingual"
        }
    }

    var estimatedSizeLabel: String {
        switch self {
        case .parakeetTdtCtc110m:
            "Smaller 110M model"
        case .parakeetV3:
            "~450 MB 600M model"
        }
    }

    var engineIdentifier: String {
        switch self {
        case .parakeetTdtCtc110m:
            "parakeet-tdt-ctc-110m"
        case .parakeetV3:
            "parakeet-v3"
        }
    }

    var asrVersion: AsrModelVersion {
        switch self {
        case .parakeetTdtCtc110m:
            .tdtCtc110m
        case .parakeetV3:
            .v3
        }
    }

    static let defaultModel: LocalTranscriptionModel = .parakeetTdtCtc110m
}
