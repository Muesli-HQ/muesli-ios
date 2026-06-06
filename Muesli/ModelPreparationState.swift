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
    var status = "\(LocalTranscriptionModel.defaultModel.shortName) is not downloaded"
    var detail = LocalTranscriptionModel.defaultModel.detail

    var isPreparing: Bool {
        phase == .downloading || phase == .preparing
    }

    var isReady: Bool {
        phase == .ready
    }
}
