import Foundation
import TelemetryDeck
import UIKit

enum AppTelemetryFailureDomain: String {
    case audio
    case cloudSync = "cloud_sync"
    case keyboardSession = "keyboard_session"
    case liveActivity = "live_activity"
    case meeting
    case model
    case stateMachine = "state_machine"
    case summary
    case transcription
}

enum AppTelemetryParameterSanitizer {
    static let maxKeyLength = 48
    static let maxValueLength = 96

    private static let allowedKeyCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"
    )
    private static let reservedKeys: Set<String> = [
        "app_version",
        "app_build",
        "cloudkit_error",
        "device_family",
        "device_model",
        "error_code",
        "error_domain",
        "error_type",
        "failure_domain",
        "failure_event",
        "failure_reason",
        "failure_stage",
        "ios_version",
        "network_error",
        "timeout",
    ]

    static func normalizedKey(_ value: String) -> String {
        let scalars = value.unicodeScalars.map { allowedKeyCharacters.contains($0) ? Character($0) : "_" }
        let normalized = String(scalars).lowercased()
        return normalized.isEmpty ? "unknown" : String(normalized.prefix(maxKeyLength))
    }

    static func normalizedValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "unknown" }
        return String(trimmed.prefix(maxValueLength))
    }

    static func normalizedCustomParameters(_ parameters: [String: String]) -> [String: String] {
        parameters.reduce(into: [:]) { result, element in
            let key = normalizedKey(element.key)
            let outputKey = reservedKeys.contains(key) ? normalizedKey("custom_\(key)") : key
            result[outputKey] = normalizedValue(element.value)
        }
    }
}

@MainActor
enum AppTelemetry {
    private static let appIDInfoKey = "MuesliTelemetryDeckAppID"
    private static let fallbackAppID = "A851C6BD-4F55-41ED-A6BC-DA43C850B069"
    private static var isInitialized = false

    static func configure() {
        signal("app_launched")
    }

    static func signal(_ name: String, parameters: [String: String] = [:]) {
        guard initializeIfNeeded() else { return }
        TelemetryDeck.signal("Muesli.iOS.\(name)", parameters: parameters)
    }

    static func contextualSignal(_ name: String, parameters: [String: String] = [:]) {
        var enriched = runtimeParameters()
        enriched.merge(
            AppTelemetryParameterSanitizer.normalizedCustomParameters(parameters),
            uniquingKeysWith: { _, new in new }
        )
        signal(name, parameters: enriched)
    }

    static func failure(
        _ name: String,
        domain: AppTelemetryFailureDomain,
        stage: String,
        error: Error? = nil,
        reason: String? = nil,
        isTimeout: Bool = false,
        parameters: [String: String] = [:]
    ) {
        var enriched = runtimeParameters()
        enriched["failure_domain"] = domain.rawValue
        enriched["failure_stage"] = AppTelemetryParameterSanitizer.normalizedValue(stage)
        if let reason {
            enriched["failure_reason"] = AppTelemetryParameterSanitizer.normalizedValue(reason)
        }
        if isTimeout {
            enriched["timeout"] = "true"
        }
        if let error {
            enriched.merge(errorParameters(for: error), uniquingKeysWith: { _, new in new })
        }
        enriched.merge(
            AppTelemetryParameterSanitizer.normalizedCustomParameters(parameters),
            uniquingKeysWith: { _, new in new }
        )

        signal(name, parameters: enriched)

        var aggregate = enriched
        aggregate["failure_event"] = AppTelemetryParameterSanitizer.normalizedValue(name)
        signal("failure_observed", parameters: aggregate)
    }

    @discardableResult
    private static func initializeIfNeeded() -> Bool {
        if isInitialized { return true }

        let configuredAppID = Bundle.main.object(forInfoDictionaryKey: appIDInfoKey) as? String
        let trimmedAppID = configuredAppID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let appID = (!trimmedAppID.isEmpty && !trimmedAppID.hasPrefix("$("))
            ? trimmedAppID
            : fallbackAppID

        TelemetryDeck.initialize(config: .init(appID: appID))
        isInitialized = true
        return true
    }

    private static func runtimeParameters() -> [String: String] {
        [
            "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "app_build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "ios_version": UIDevice.current.systemVersion,
            "device_model": deviceModelIdentifier(),
            "device_family": UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone",
        ]
    }

    private static func errorParameters(for error: Error) -> [String: String] {
        let nsError = error as NSError
        var parameters = [
            "error_type": AppTelemetryParameterSanitizer.normalizedValue(String(describing: type(of: error))),
            "error_domain": AppTelemetryParameterSanitizer.normalizedValue(nsError.domain),
            "error_code": "\(nsError.code)",
        ]

        if nsError.domain == NSURLErrorDomain {
            parameters["network_error"] = "true"
        }
        if nsError.domain == "CKErrorDomain" {
            parameters["cloudkit_error"] = "true"
        }

        return parameters
    }

    private static func deviceModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let identifier = mirror.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(String(UnicodeScalar(UInt8(value))))
        }
        return identifier.isEmpty ? "unknown" : identifier
    }
}
