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

    static func failed(_ error: Error) -> Self {
        let failure = ModelSetupFailure.describe(error)
        return .init(phase: .failed, status: failure.status, detail: failure.detail)
    }

    static func progressPhase(status: String) -> ModelPreparationPhase {
        ["compil", "prepar", "optimiz", "loading downloaded", "model ready"].contains {
            status.localizedCaseInsensitiveContains($0)
        } ? .preparing : .downloading
    }
}

enum ModelPreparationAction: Equatable {
    case startBackgroundDownload
    case warmDownloadedModel
}

enum ModelPreparationPolicy {
    static func action(isDownloaded: Bool) -> ModelPreparationAction {
        isDownloaded ? .warmDownloadedModel : .startBackgroundDownload
    }
}
