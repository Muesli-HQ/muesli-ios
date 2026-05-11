import Foundation
import TelemetryDeck

@MainActor
enum AppTelemetry {
    private static let appIDInfoKey = "MuesliTelemetryDeckAppID"
    private static let enabledDefaultsKey = "muesli.telemetry.enabled"
    private static var isInitialized = false

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledDefaultsKey)
    }

    static func configure() {
        signal("app_launched")
    }

    static func setEnabled(_ enabled: Bool) {
        if enabled {
            UserDefaults.standard.set(true, forKey: enabledDefaultsKey)
            signal("telemetry_enabled")
        } else {
            signal("telemetry_disabled")
            UserDefaults.standard.set(false, forKey: enabledDefaultsKey)
        }
    }

    static func signal(_ name: String, parameters: [String: String] = [:]) {
        guard isEnabled, initializeIfNeeded() else { return }
        TelemetryDeck.signal("Muesli.iOS.\(name)", parameters: parameters)
    }

    @discardableResult
    private static func initializeIfNeeded() -> Bool {
        if isInitialized { return true }

        guard let appID = Bundle.main.object(forInfoDictionaryKey: appIDInfoKey) as? String,
              !appID.isEmpty,
              !appID.hasPrefix("$(")
        else { return false }

        TelemetryDeck.initialize(config: .init(appID: appID))
        isInitialized = true
        return true
    }
}
