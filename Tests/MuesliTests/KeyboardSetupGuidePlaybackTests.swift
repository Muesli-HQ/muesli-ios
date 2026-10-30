import AVKit
import XCTest
@testable import Muesli

final class KeyboardSetupGuidePlaybackTests: XCTestCase {
    @MainActor
    func testSettingsWaitsForReadyFramePossiblePiPAndDidStart() {
        let fixture = GuideFixture()
        fixture.layerReady = false
        fixture.pip.isPossible = false
        fixture.guide.start(allowed: true)
        fixture.guide.attach(fixture.layer)
        XCTAssertEqual(fixture.pip.starts, 0)
        XCTAssertEqual(fixture.settingsOpens, 0)

        fixture.layerReady = true
        fixture.pip.onPossibleChanged?()
        XCTAssertEqual(fixture.pip.starts, 0)
        fixture.pip.isPossible = true
        fixture.pip.onPossibleChanged?()
        fixture.pip.onPossibleChanged?()
        XCTAssertEqual(fixture.pip.starts, 1)
        XCTAssertEqual(fixture.settingsOpens, 0, "A start request is not proof that PiP is onscreen")

        fixture.pip.onStarted?()
        fixture.pip.onStarted?()
        XCTAssertEqual(fixture.settingsOpens, 1)
        XCTAssertFalse(fixture.guide.isPreparing)
        fixture.guide.stop()
    }

    @MainActor
    func testCancellationRejectsDelayedReadinessAndDidStart() {
        let fixture = GuideFixture()
        fixture.pip.isPossible = false
        fixture.guide.start(allowed: true)
        fixture.guide.attach(fixture.layer)
        fixture.guide.stop()

        fixture.pip.isPossible = true
        fixture.pip.onPossibleChanged?()
        fixture.pip.onStarted?()

        XCTAssertEqual(fixture.pip.starts, 0)
        XCTAssertEqual(fixture.settingsOpens, 0)
        XCTAssertNil(fixture.guide.player)
        XCTAssertFalse(fixture.audio.isOwned)
    }

    @MainActor
    func testBackgroundBeforeReadinessCannotOpenSettingsLater() {
        let fixture = GuideFixture()
        fixture.pip.isPossible = false
        fixture.guide.start(allowed: true)
        fixture.guide.attach(fixture.layer)
        fixture.applicationState = .background
        fixture.guide.cancelPendingHandoff()
        fixture.applicationState = .active
        fixture.pip.isPossible = true
        fixture.pip.onPossibleChanged?()
        fixture.pip.onStarted?()

        XCTAssertEqual(fixture.settingsOpens, 0)
        XCTAssertNil(fixture.guide.player)
    }

    @MainActor
    func testBackgroundBetweenPiPRequestAndDidStartCannotLaunchSettings() {
        let fixture = GuideFixture()
        fixture.guide.start(allowed: true)
        fixture.guide.attach(fixture.layer)
        XCTAssertEqual(fixture.pip.starts, 1)
        fixture.applicationState = .background
        // Protect the handoff even before SwiftUI's scene-phase callback arrives.
        fixture.pip.onStarted?()

        XCTAssertEqual(fixture.settingsOpens, 0)
        XCTAssertNil(fixture.guide.player)
        XCTAssertFalse(fixture.audio.isOwned)
    }

    @MainActor
    func testInactivePiPAnimationDoesNotCancelSettingsHandoff() {
        let fixture = GuideFixture()
        fixture.guide.start(allowed: true)
        fixture.guide.attach(fixture.layer)
        fixture.applicationState = .inactive
        fixture.pip.onStarted?()

        XCTAssertEqual(fixture.settingsOpens, 1)
        XCTAssertNotNil(fixture.guide.player)
        fixture.guide.stop()
    }

    @MainActor
    func testReadinessWhileInactiveWaitsUntilForegroundResumes() {
        let fixture = GuideFixture()
        fixture.pip.isPossible = false
        fixture.guide.start(allowed: true)
        fixture.guide.attach(fixture.layer)
        fixture.applicationState = .inactive
        fixture.pip.isPossible = true
        fixture.pip.onPossibleChanged?()
        XCTAssertEqual(fixture.pip.starts, 0)

        fixture.applicationState = .active
        fixture.guide.resumePendingHandoff()
        XCTAssertEqual(fixture.pip.starts, 1)
        fixture.pip.onStarted?()
        XCTAssertEqual(fixture.settingsOpens, 1)
        fixture.guide.stop()
    }

    @MainActor
    func testPiPFailureRequiresExplicitFallbackTap() {
        let fixture = GuideFixture()
        fixture.guide.start(allowed: true)
        fixture.guide.attach(fixture.layer)
        fixture.pip.onFailed?()

        XCTAssertEqual(fixture.settingsOpens, 0)
        XCTAssertTrue(fixture.guide.offersSettingsFallback)
        XCTAssertFalse(fixture.audio.isOwned)
        fixture.pip.onStarted?()
        XCTAssertEqual(fixture.settingsOpens, 0)
        fixture.guide.openSettingsWithoutVideo()
        XCTAssertEqual(fixture.settingsOpens, 1)
        fixture.guide.openSettingsWithoutVideo()
        XCTAssertEqual(fixture.settingsOpens, 1)
    }

    @MainActor
    func testUnavailablePiPOffersFallbackWithoutOpeningSettings() async {
        let fixture = GuideFixture()
        fixture.supportsPiP = false
        fixture.guide.start(allowed: true)
        let fallback = fixture.guide.attach(fixture.layer)
        XCTAssertNotNil(fallback)
        // Attachment must not publish SwiftUI state during make/updateUIView.
        XCTAssertNotNil(fixture.guide.player)
        XCTAssertFalse(fixture.guide.offersSettingsFallback)
        // Await the actual deferred fallback rather than relying on scheduling
        // order, a fixed sleep, or a real AVKit error callback.
        await fallback?.value

        XCTAssertNil(fixture.guide.player)
        XCTAssertTrue(fixture.guide.offersSettingsFallback)
        XCTAssertEqual(fixture.settingsOpens, 0)
        XCTAssertFalse(fixture.audio.isOwned)
    }

    @MainActor
    func testCancelledDeferredFallbackCannotChangeState() async {
        let fixture = GuideFixture()
        fixture.supportsPiP = false
        fixture.guide.start(allowed: true)
        let fallback = fixture.guide.attach(fixture.layer)
        fixture.guide.stop()
        await fallback?.value

        XCTAssertNil(fixture.guide.player)
        XCTAssertFalse(fixture.guide.offersSettingsFallback)
        XCTAssertNil(fixture.guide.message)
        XCTAssertEqual(fixture.settingsOpens, 0)
    }

    @MainActor
    func testDeferredFallbackCannotTearDownReplacementAttempt() async throws {
        let fixture = GuideFixture()
        fixture.supportsPiP = false
        fixture.guide.start(allowed: true)
        let fallback = fixture.guide.attach(fixture.layer)
        fixture.supportsPiP = true
        fixture.guide.start(allowed: true)
        fixture.guide.attach(fixture.layer)
        let replacement = try XCTUnwrap(fixture.guide.player)
        await fallback?.value

        XCTAssertTrue(fixture.guide.player === replacement)
        XCTAssertFalse(fixture.guide.offersSettingsFallback)
        XCTAssertEqual(fixture.settingsOpens, 0)
        fixture.guide.stop()
    }

    @MainActor
    func testDeferredFallbackCannotTearDownReplacementSurface() async throws {
        let fixture = GuideFixture()
        fixture.supportsPiP = false
        fixture.guide.start(allowed: true)
        let fallback = fixture.guide.attach(fixture.layer)
        fixture.supportsPiP = true
        let replacementLayer = AVPlayerLayer()
        fixture.guide.attach(replacementLayer)
        let player = try XCTUnwrap(fixture.guide.player)
        await fallback?.value

        XCTAssertTrue(fixture.guide.player === player)
        XCTAssertFalse(fixture.guide.offersSettingsFallback)
        XCTAssertEqual(fixture.pip.starts, 1)
        XCTAssertEqual(fixture.settingsOpens, 0)
        fixture.guide.stop()
    }

    @MainActor
    func testMissingVideoDoesNotAcquireAudioOrOpenSettings() {
        let audio = GuideAudioSessionSpy()
        var settingsOpens = 0
        let guide = KeyboardSetupGuidePlayback(
            videoURL: nil, audioSession: audio, applicationState: { .active }, openSettings: { settingsOpens += 1 }
        )
        guide.start(allowed: true)

        XCTAssertNil(guide.player)
        XCTAssertTrue(guide.offersSettingsFallback)
        XCTAssertEqual(audio.activations, 0)
        XCTAssertEqual(settingsOpens, 0)
    }

    @MainActor
    func testCaptureAndInactiveAppBlockStartingGuide() {
        let fixture = GuideFixture()
        fixture.guide.start(allowed: false)
        fixture.applicationState = .inactive
        fixture.guide.start(allowed: true)

        XCTAssertNil(fixture.guide.player)
        XCTAssertEqual(fixture.audio.activations, 0)
        XCTAssertEqual(fixture.settingsOpens, 0)
    }

    @MainActor
    func testFailedAudioActivationReleasesGuideOwnership() {
        let fixture = GuideFixture()
        fixture.audio.failActivation = true
        fixture.guide.start(allowed: true)

        XCTAssertNil(fixture.guide.player)
        XCTAssertTrue(fixture.guide.offersSettingsFallback)
        XCTAssertEqual(fixture.audio.releases, 1)
        XCTAssertFalse(fixture.audio.isOwned)
        XCTAssertEqual(fixture.settingsOpens, 0)
    }

    @MainActor
    func testRestorationPreservesPlaybackWhileAppIsStillBackgrounded() throws {
        let fixture = GuideFixture()
        fixture.guide.start(allowed: true)
        fixture.guide.attach(fixture.layer)
        fixture.pip.onStarted?()
        fixture.applicationState = .background
        let player = try XCTUnwrap(fixture.guide.player)
        XCTAssertEqual(fixture.pip.onRestore?(), true)
        fixture.pip.onStopped?()

        XCTAssertTrue(fixture.guide.player === player)
        XCTAssertTrue(fixture.audio.isOwned)
        fixture.guide.stop()
    }

    @MainActor
    func testClosingPiPReleasesVideoAndAudio() throws {
        let fixture = GuideFixture()
        fixture.guide.start(allowed: true)
        fixture.guide.attach(fixture.layer)
        fixture.pip.onStarted?()
        let player = try XCTUnwrap(fixture.guide.player)
        fixture.pip.onStopped?()

        XCTAssertNil(fixture.guide.player)
        XCTAssertNil(fixture.layer.player)
        XCTAssertNil(player.currentItem)
        XCTAssertEqual(fixture.audio.releases, 1)
        fixture.guide.stop()
        XCTAssertEqual(fixture.audio.releases, 1)
    }

    @MainActor
    func testCallbacksFromReplacedAttemptCannotLaunchOrStopNewGuide() throws {
        let fixture = GuideFixture()
        fixture.pip.isPossible = false
        fixture.guide.start(allowed: true)
        fixture.guide.attach(fixture.layer)
        let oldPiP = fixture.pip
        fixture.pip = GuidePiPSpy()
        fixture.guide.start(allowed: true)
        fixture.guide.attach(fixture.layer)
        let newPlayer = try XCTUnwrap(fixture.guide.player)

        oldPiP.isPossible = true
        oldPiP.onPossibleChanged?()
        oldPiP.onStarted?()
        oldPiP.onFailed?()
        oldPiP.onStopped?()
        XCTAssertEqual(oldPiP.onRestore?(), false)
        XCTAssertTrue(fixture.guide.player === newPlayer)
        XCTAssertEqual(fixture.settingsOpens, 0)
        fixture.pip.onStarted?()
        XCTAssertEqual(fixture.settingsOpens, 1)
        fixture.guide.stop()
    }
}

@MainActor
private final class GuideFixture {
    let audio = GuideAudioSessionSpy()
    var pip = GuidePiPSpy()
    let layer = AVPlayerLayer()
    var layerReady = true
    var supportsPiP = true
    var applicationState = UIApplication.State.active
    var settingsOpens = 0
    lazy var guide = KeyboardSetupGuidePlayback(
        // A real bundled asset avoids an unrelated async decoder failure while
        // deferred handoff tasks are awaited. Audio and PiP stay fully mocked.
        videoURL: Bundle.main.url(forResource: "KeyboardSetupGuide", withExtension: "mp4"),
        audioSession: audio,
        applicationState: { [unowned self] in self.applicationState },
        openSettings: { [unowned self] in self.settingsOpens += 1 },
        makePictureInPicture: { [unowned self] _ in self.supportsPiP ? self.pip : nil },
        isLayerReady: { [unowned self] _ in self.layerReady }
    )
}

@MainActor
private final class GuidePiPSpy: KeyboardSetupGuidePictureInPicture {
    var isPossible = true
    var starts = 0
    var stops = 0
    var onPossibleChanged: (() -> Void)?
    var onStarted: (() -> Void)?
    var onFailed: (() -> Void)?
    var onStopped: (() -> Void)?
    var onRestore: (() -> Bool)?
    func start() { starts += 1 }
    func stop() { stops += 1 }
}

private enum GuideTestError: Error { case failed }

@MainActor
private final class GuideAudioSessionSpy: KeyboardSetupGuideAudioSession {
    var activations = 0
    var releases = 0
    var isOwned = false
    var failActivation = false
    func activate() throws {
        activations += 1
        isOwned = true
        if failActivation { throw GuideTestError.failed }
    }
    func release() {
        guard isOwned else { return }
        releases += 1
        isOwned = false
    }
}
