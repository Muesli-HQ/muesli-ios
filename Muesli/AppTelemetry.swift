import Foundation
import TelemetryDeck

@MainActor
enum AppTelemetry {
    private static let appIDInfoKey = "MuesliTelemetryDeckAppID"
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

        guard let appID = Bundle.main.object(forInfoDictionaryKey: appIDInfoKey) as? String,
              !appID.isEmpty,
              !appID.hasPrefix("$(")
        else { return false }

        TelemetryDeck.initialize(config: .init(appID: appID))
        isInitialized = true
        return true
    }
}
