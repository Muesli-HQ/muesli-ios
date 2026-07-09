import Foundation
import TelemetryDeck
import UIKit

enum AppTelemetryFailureDomain: String {
    case audio
    case cloudSync = "cloud_sync"
    case keyboardSession = "keyboard_session"
    case meeting
    case model
    case summary
    case transcription
}

@MainActor
enum AppTelemetry {
    private static let appIDInfoKey = "MuesliTelemetryDeckAppID"
    private static let fallbackAppID = "A851C6BD-4F55-41ED-A6BC-DA43C850B069"
    private static var isInitialized = false
    private static let maxParameterLength = 96

    static func configure() {
        signal("app_launched")
    }

    static func signal(_ name: String, parameters: [String: String] = [:]) {
        guard initializeIfNeeded() else { return }
        TelemetryDeck.signal("Muesli.iOS.\(name)", parameters: parameters)
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
        enriched["failure_stage"] = normalizedParameterValue(stage)
        if let reason {
            enriched["failure_reason"] = normalizedParameterValue(reason)
        }
        if isTimeout {
            enriched["timeout"] = "true"
        }
        if let error {
            enriched.merge(errorParameters(for: error), uniquingKeysWith: { _, new in new })
        }
        enriched.merge(normalized(parameters), uniquingKeysWith: { _, new in new })

        signal(name, parameters: enriched)

        var aggregate = enriched
        aggregate["failure_event"] = normalizedParameterValue(name)
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
            "error_type": normalizedParameterValue(String(describing: type(of: error))),
            "error_domain": normalizedParameterValue(nsError.domain),
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

    private static func normalized(_ parameters: [String: String]) -> [String: String] {
        parameters.reduce(into: [:]) { result, element in
            result[normalizedParameterKey(element.key)] = normalizedParameterValue(element.value)
        }
    }

    private static func normalizedParameterKey(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let normalized = String(scalars).lowercased()
        return normalized.isEmpty ? "unknown" : String(normalized.prefix(48))
    }

    private static func normalizedParameterValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "unknown" }
        return String(trimmed.prefix(maxParameterLength))
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
