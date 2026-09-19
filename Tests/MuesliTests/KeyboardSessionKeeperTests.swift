import AVFoundation
import XCTest

@testable import Muesli

final class KeyboardSessionKeeperTests: XCTestCase {
    @MainActor
    func testCoordinatorRefreshesStandbyReadinessAndMicOffStopsHeartbeat() async throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw XCTSkip("Microphone permission is required for the standby integration test")
        }
        let defaults = UserDefaults.standard
        let keys = [MuesliPreferences.keyboardSessionModeKey, MuesliPreferences.manuallyRemovedTranscriptionModelKey]
        let original = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, original) {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(true, forKey: keys[0])
        defaults.set(MuesliPreferences.transcriptionModel.rawValue, forKey: keys[1])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = Muesli.SharedStore(containerURL: directory)
        let coordinator = DictationCoordinator(store: store)
        await coordinator.startKeyboardSessionMode()
        let first = try? store.keyboardRuntimeStatus()
        try? await Task.sleep(for: .seconds(1.2))
        let refreshed = try? store.keyboardRuntimeStatus()
        let stopped = await coordinator.turnOffKeyboardMic()
        try? await Task.sleep(for: .milliseconds(700))
        let afterStop = try? store.keyboardRuntimeStatus()

        XCTAssertEqual(first?.canAcceptStartCommand, true)
        XCTAssertEqual(refreshed?.canAcceptStartCommand, true)
        XCTAssertGreaterThan(refreshed?.updatedAt ?? .distantPast, first?.updatedAt ?? .distantFuture)
        XCTAssertTrue(MuesliPreferences.keyboardSessionModeEnabled, "Mic Off must not disable automatic persistence")
        XCTAssertTrue(stopped)
        XCTAssertFalse(coordinator.isKeyboardMicOn)
        XCTAssertEqual(afterStop?.canAcceptStartCommand, false)
    }

    @MainActor
    func testMicOffWhilePermissionIsPendingPreventsLateAudioStartup() async {
        let keeper = KeyboardSessionKeeper()
        let permission = PendingKeyboardMicPermission()
        let startup = Task {
            try await keeper.start(requestPermission: { await permission.request() })
        }
        while permission.continuation == nil { await Task.yield() }
        keeper.stop()
        permission.continuation?.resume(returning: true)
        do {
            try await startup.value
            XCTFail("A permission response after Mic Off must not start the engine")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(keeper.isRunning)
        XCTAssertFalse(keeper.canAcceptStartCommand)
    }

    func testDiscardAudioTapIsCallableFromNonMainActorContext() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024))
        let time = AVAudioTime(sampleTime: 0, atRate: 16_000)

        KeyboardSessionKeeper.discardAudioTap(buffer, when: time)
    }
}

@MainActor
private final class PendingKeyboardMicPermission {
    var continuation: CheckedContinuation<Bool, Never>?
    func request() async -> Bool {
        await withCheckedContinuation { continuation = $0 }
    }
}
