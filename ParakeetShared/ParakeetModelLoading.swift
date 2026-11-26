import CoreML
import FluidAudio
import Foundation

/// Loads a downloaded Parakeet TDT model from a folder. Shared by the app and
/// the keyboard extension, which loads the App Group copy the app shares.
enum ParakeetModelLoading {
    enum LoadError: Error {
        case unsupportedVersion
        case invalidVocabulary
    }

    static func loadAsrModels(
        from directory: URL,
        version: AsrModelVersion,
        encoderComputeUnits: MLComputeUnits? = nil,
        modelComputeUnits: MLComputeUnits? = nil
    ) async throws -> AsrModels {
        let preprocessorFile: String
        let encoderFile: String?
        let decoderFile: String
        let jointFile: String
        switch version {
        case .tdtCtc110m:
            preprocessorFile = ModelNames.ASR.preprocessorFile
            encoderFile = nil
            decoderFile = ModelNames.ASR.decoderFile
            jointFile = ModelNames.ASR.jointFile
        case .v3, .redux:
            preprocessorFile = ModelNames.ASR.preprocessorFile
            encoderFile = ModelNames.ASR.encoderFile
            decoderFile = ModelNames.ASR.decoderFile
            jointFile = ModelNames.ASR.jointV3File
        default:
            throw LoadError.unsupportedVersion
        }

        let defaultConfiguration = AsrModels.defaultConfiguration()
        if let modelComputeUnits {
            defaultConfiguration.computeUnits = modelComputeUnits
        }
        let preprocessorConfiguration = MLModelConfiguration()
        preprocessorConfiguration.computeUnits = .cpuOnly

        let preprocessor = try await MLModel.load(
            contentsOf: directory.appendingPathComponent(preprocessorFile),
            configuration: preprocessorConfiguration
        )
        let encoderConfiguration = MLModelConfiguration()
        encoderConfiguration.computeUnits = encoderComputeUnits ?? defaultConfiguration.computeUnits
        let encoder: MLModel?
        if let encoderFile {
            encoder = try await MLModel.load(
                contentsOf: directory.appendingPathComponent(encoderFile),
                configuration: encoderConfiguration
            )
        } else {
            encoder = nil
        }
        let decoder = try await MLModel.load(
            contentsOf: directory.appendingPathComponent(decoderFile),
            configuration: defaultConfiguration
        )
        let joint = try await MLModel.load(
            contentsOf: directory.appendingPathComponent(jointFile),
            configuration: defaultConfiguration
        )
        let vocabularyData = try Data(
            contentsOf: directory.appendingPathComponent(ModelNames.ASR.vocabularyFile)
        )

        return AsrModels(
            encoder: encoder,
            preprocessor: preprocessor,
            decoder: decoder,
            joint: joint,
            configuration: defaultConfiguration,
            vocabulary: try decodeVocabulary(vocabularyData),
            version: version
        )
    }

    static func decodeVocabulary(_ data: Data) throws -> [Int: String] {
        let object = try JSONSerialization.jsonObject(with: data)
        if let array = object as? [String] {
            return Dictionary(uniqueKeysWithValues: array.enumerated().map { ($0.offset, $0.element) })
        }
        if let dictionary = object as? [String: String] {
            return dictionary.reduce(into: [:]) { vocabulary, entry in
                if let tokenID = Int(entry.key) {
                    vocabulary[tokenID] = entry.value
                }
            }
        }
        throw LoadError.invalidVocabulary
    }
}
