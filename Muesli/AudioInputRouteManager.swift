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
        inputName.isEmpty ? preference.label : inputName
    }
}

enum AudioInputRouteManager {
    static func configureForRecording(
        stage: String,
        preference: RecordingMicrophonePreference = MuesliPreferences.recordingMicrophonePreference
    ) throws -> AudioInputRouteSnapshot {
        let session = AVAudioSession.sharedInstance()
        let activationStartedAt = Date()
        var step = "category"
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .spokenAudio,
                options: recordingCategoryOptions
            )
            step = "activation"
            try session.setActive(true)
        } catch {
            recordActivationFailure(error, stage: stage, step: step, attempt: 1, session: session)
            // Repeating setActive without changing execution context cannot recover
            // a background priority denial. Preserve the original failure.
            if isBackgroundPlaybackDenial(error) {
                throw AudioRecorder.RecordingError.audioSessionFailed(stage: stage, underlying: error)
            }
            do {
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
                step = "category"
                try session.setCategory(
                    .playAndRecord,
                    mode: .spokenAudio,
                    options: recordingCategoryOptions
                )
                step = "activation"
                try session.setActive(true)
            } catch {
                recordActivationFailure(error, stage: stage, step: step, attempt: 2, session: session)
                throw AudioRecorder.RecordingError.audioSessionFailed(stage: stage, underlying: error)
            }
        }

        KeyboardDiagnosticsLog.record("audioSession.activated", [
            "stage": stage,
            "elapsed_ms": String(Int(Date().timeIntervalSince(activationStartedAt) * 1_000)),
            "category": session.category.rawValue,
            "mode": session.mode.rawValue,
            "options": String(session.categoryOptions.rawValue)
        ])

        let preferredInput = preferredInput(for: preference, in: session.availableInputs ?? [])
        do {
            try session.setPreferredInput(preferredInput)
        } catch {
            #if DEBUG
            print("Muesli audio route preference was ignored [\(stage)]: \(preference.rawValue)")
            #endif
        }

        let snapshot = currentSnapshot(preference: preference)
        #if DEBUG
        print("Muesli audio route configured [\(stage)]: preference=\(preference.rawValue)")
        #endif
        return snapshot
    }

    static func isBackgroundPlaybackDenial(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSOSStatusErrorDomain && error.code == 561015905 // '!pla': CannotStartPlaying
    }

    private static func recordActivationFailure(
        _ error: Error,
        stage: String,
        step: String,
        attempt: Int,
        session: AVAudioSession
    ) {
        let error = error as NSError
        KeyboardDiagnosticsLog.record("audioSession.failed", [
            "stage": stage,
            "step": step,
            "attempt": String(attempt),
            "domain": error.domain,
            "code": String(error.code),
            "category": session.category.rawValue,
            "mode": session.mode.rawValue,
            "options": String(session.categoryOptions.rawValue),
            "other_audio": String(session.isOtherAudioPlaying),
            "input_available": String(session.isInputAvailable)
        ])
        #if DEBUG
        print("Muesli audio session failed [\(stage), \(step), attempt \(attempt)]: \(error.domain) \(error.code)")
        #endif
    }

    static func currentSnapshot(
        preference: RecordingMicrophonePreference = MuesliPreferences.recordingMicrophonePreference
    ) -> AudioInputRouteSnapshot {
        let session = AVAudioSession.sharedInstance()
        let input = session.currentRoute.inputs.first
        let output = session.currentRoute.outputs.first
        return AudioInputRouteSnapshot(
            preference: preference,
            inputName: displayName(for: input) ?? fallbackInputName(for: preference, availableInputs: session.availableInputs ?? []),
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

    private static var recordingCategoryOptions: AVAudioSession.CategoryOptions {
        [.mixWithOthers, bluetoothRecordingOption, .allowBluetoothA2DP, .defaultToSpeaker]
    }

    private static var bluetoothRecordingOption: AVAudioSession.CategoryOptions {
        #if compiler(>=6.2)
        .allowBluetoothHFP
        #else
        .allowBluetooth
        #endif
    }

    private static func fallbackInputName(
        for preference: RecordingMicrophonePreference,
        availableInputs: [AVAudioSessionPortDescription]
    ) -> String {
        preferredInput(for: preference, in: availableInputs).flatMap(displayName(for:)) ?? preference.label
    }

    private static func displayName(for input: AVAudioSessionPortDescription?) -> String? {
        guard let input else { return nil }
        if isBuiltInInput(input) {
            return RecordingMicrophonePreference.builtIn.label
        }
        return input.portName
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
