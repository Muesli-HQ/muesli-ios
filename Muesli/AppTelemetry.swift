import Foundation
import TelemetryDeck

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
}
