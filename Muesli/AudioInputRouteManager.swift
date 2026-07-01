import AVFoundation
import Foundation

enum RecordingMicrophonePreference: String, CaseIterable, Identifiable {
    case automatic
    case builtIn
    case bluetooth
    case external

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic:
            "Automatic"
        case .builtIn:
            "iPhone Microphone"
        case .bluetooth:
            "AirPods / Bluetooth"
        case .external:
            "External Microphone"
        }
    }

    var detail: String {
        switch self {
        case .automatic:
            "Uses AirPods or Bluetooth when connected, otherwise falls back to iPhone."
        case .builtIn:
            "Records from this iPhone even when headphones are connected."
        case .bluetooth:
            "Uses a connected headset mic. Music may pause or switch quality."
        case .external:
            "Uses a connected USB or wired microphone when available."
        }
    }
}

struct AudioInputRouteSnapshot: Equatable {
    let preference: RecordingMicrophonePreference
    let inputName: String
    let inputDetail: String
    let outputName: String

    var displayText: String {
        if inputName.isEmpty {
            preference.label
        } else if preference == .bluetooth, inputDetail == "Built-in" {
            preference.label
        } else if preference == .external, inputDetail == "Built-in" {
            preference.label
        } else {
            inputName
        }
    }
}

enum AudioInputRouteManager {
    static func configureForRecording(
        stage: String,
        preference: RecordingMicrophonePreference = MuesliPreferences.recordingMicrophonePreference
    ) throws -> AudioInputRouteSnapshot {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .spokenAudio,
                options: [.mixWithOthers, .allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]
            )
            try session.setActive(true)
            let preferredInput = preferredInput(for: preference, in: session.availableInputs ?? [])
            try session.setPreferredInput(preferredInput)
        } catch {
            throw AudioRecorder.RecordingError.audioSessionFailed(stage: stage, underlying: error)
        }

        let snapshot = currentSnapshot(preference: preference)
        print(
            "Muesli audio route [\(stage)]: preference=\(preference.rawValue), input=\(snapshot.inputName), output=\(snapshot.outputName)"
        )
        return snapshot
    }

    static func currentSnapshot(
        preference: RecordingMicrophonePreference = MuesliPreferences.recordingMicrophonePreference
    ) -> AudioInputRouteSnapshot {
        let session = AVAudioSession.sharedInstance()
        let input = session.currentRoute.inputs.first
        let output = session.currentRoute.outputs.first
        return AudioInputRouteSnapshot(
            preference: preference,
            inputName: input?.portName ?? fallbackInputName(for: preference, availableInputs: session.availableInputs ?? []),
            inputDetail: detail(for: input?.portType),
            outputName: output?.portName ?? "Default Output"
        )
    }

    static func availablePreferenceOptions() -> [RecordingMicrophonePreference] {
        let inputs = AVAudioSession.sharedInstance().availableInputs ?? []
        var options: [RecordingMicrophonePreference] = [.automatic, .builtIn, .bluetooth]
        if inputs.contains(where: isExternalInput) {
            options.append(.external)
        }
        return options
    }

    private static func preferredInput(
        for preference: RecordingMicrophonePreference,
        in inputs: [AVAudioSessionPortDescription]
    ) -> AVAudioSessionPortDescription? {
        switch preference {
        case .automatic:
            return inputs.first(where: isBluetoothInput)
                ?? inputs.first(where: isExternalInput)
                ?? inputs.first(where: isBuiltInInput)
                ?? inputs.first
        case .builtIn:
            return inputs.first(where: isBuiltInInput)
        case .bluetooth:
            return inputs.first(where: isBluetoothInput)
        case .external:
            return inputs.first(where: isExternalInput)
        }
    }

    private static func fallbackInputName(
        for preference: RecordingMicrophonePreference,
        availableInputs: [AVAudioSessionPortDescription]
    ) -> String {
        preferredInput(for: preference, in: availableInputs)?.portName ?? preference.label
    }

    private static func isBuiltInInput(_ input: AVAudioSessionPortDescription) -> Bool {
        input.portType == .builtInMic
    }

    private static func isBluetoothInput(_ input: AVAudioSessionPortDescription) -> Bool {
        input.portType == .bluetoothHFP || input.portType == .bluetoothLE
    }

    private static func isExternalInput(_ input: AVAudioSessionPortDescription) -> Bool {
        !isBuiltInInput(input) && !isBluetoothInput(input)
    }

    private static func detail(for portType: AVAudioSession.Port?) -> String {
        switch portType {
        case .builtInMic:
            "Built-in"
        case .bluetoothHFP, .bluetoothLE:
            "Bluetooth headset mic"
        case .headsetMic:
            "Wired headset mic"
        case .usbAudio:
            "USB audio"
        case .none:
            "Inactive"
        default:
            "External"
        }
    }
}
