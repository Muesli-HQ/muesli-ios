import XCTest
@testable import Muesli

final class MuesliBridgeDeviceIdentityTests: XCTestCase {
    private enum DefaultsKey {
        static let remoteDeviceID = "muesli.sync.bridge.remoteDeviceID.v1"
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "com.muesli.ios.tests.bridge-device-identity.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    func testShouldRefreshUsesShortIntervalBeforeRemoteDeviceIsKnown() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSince1970: 1_770_000_000)

        MuesliBridgeDeviceIdentity.markRefreshed(defaults: defaults, at: now)

        XCTAssertFalse(MuesliBridgeDeviceIdentity.shouldRefresh(
            defaults: defaults,
            now: now.addingTimeInterval(59)
        ))
        XCTAssertTrue(MuesliBridgeDeviceIdentity.shouldRefresh(
            defaults: defaults,
            now: now.addingTimeInterval(60)
        ))
    }

    func testShouldRefreshUsesOneHourIntervalOnceLinked() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSince1970: 1_770_000_000)

        defaults.set("remote-mac", forKey: DefaultsKey.remoteDeviceID)
        MuesliBridgeDeviceIdentity.markRefreshed(defaults: defaults, at: now)

        XCTAssertFalse(MuesliBridgeDeviceIdentity.shouldRefresh(
            defaults: defaults,
            now: now.addingTimeInterval(60 * 59)
        ))
        XCTAssertTrue(MuesliBridgeDeviceIdentity.shouldRefresh(
            defaults: defaults,
            now: now.addingTimeInterval(60 * 60)
        ))
    }

    func testShouldRefreshCanForceRefreshBeforeThrottleExpires() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSince1970: 1_770_000_000)

        MuesliBridgeDeviceIdentity.markRefreshed(defaults: defaults, at: now)

        XCTAssertTrue(MuesliBridgeDeviceIdentity.shouldRefresh(
            defaults: defaults,
            now: now.addingTimeInterval(1),
            forceRefresh: true
        ))
    }
}
