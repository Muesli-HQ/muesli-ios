import Foundation

enum ModelPreparationPhase: Equatable {
    case idle
    case downloading
    case preparing
    case ready
    case failed
}

struct ModelPreparationState: Equatable {
    var phase: ModelPreparationPhase = .idle
    var progress: Double?
    var status = "Parakeet v3 is not downloaded"
    var detail = "On-device CoreML / ANE transcription"

    var isPreparing: Bool {
        phase == .downloading || phase == .preparing
    }

    var isReady: Bool {
        phase == .ready
    }
}
