import AVKit
import Observation
import SwiftUI

/// Highlights and captions are baked into the recording, including in PiP.
struct KeyboardSetupGuideView: View {
    let playbackAllowed: Bool
    var willStart: () -> Void = {}
    @Environment(\.scenePhase) private var scenePhase
    @State private var playback = KeyboardSetupGuidePlayback()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if playback.player != nil {
                // Replace the tapped button in place so the player layer is
                // visible when AVKit decides whether it can enter PiP.
                KeyboardSetupGuidePlayer(playback: playback)
                    .frame(height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("onboarding.keyboardGuidePlayer")
                HStack {
                    if playback.isPreparing { ProgressView() }
                    Button(playback.isPreparing ? "Cancel" : "Close guide", action: playback.stop)
                        .accessibilityIdentifier("onboarding.cancelKeyboardGuide")
                }
            } else {
                Button {
                    willStart()
                    playback.start(allowed: playbackAllowed)
                } label: {
                    Label("Set up keyboard", systemImage: "keyboard")
                        .font(MuesliTheme.headline())
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .disabled(!playbackAllowed)
                .accessibilityIdentifier("onboarding.setUpKeyboard")
                Text("Opens Settings with a floating guide.")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textSecondary)
            }

            if !playbackAllowed {
                Text("Turn off the microphone to start the guide.")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textSecondary)
            }
            if let message = playback.message {
                Text(message)
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .accessibilityIdentifier("onboarding.keyboardGuideMessage")
            }
            if playback.offersSettingsFallback {
                Button("Open Settings without video", action: playback.openSettingsWithoutVideo)
                    .accessibilityIdentifier("onboarding.openSettingsWithoutVideo")
            }
        }
        .onChange(of: playbackAllowed) { _, allowed in
            if !allowed { playback.stop() }
        }
        .onChange(of: scenePhase) { _, phase in
            // A delayed readiness/delegate callback must never open Settings
            // after the user leaves Muesli for another reason.
            if phase == .background { playback.cancelPendingHandoff() }
            if phase == .active { playback.resumePendingHandoff() }
        }
        .onDisappear { playback.stop() }
    }
}

@MainActor
@Observable
final class KeyboardSetupGuidePlayback {
    private(set) var player: AVPlayer?
    private(set) var message: String?
    private(set) var isPreparing = false
    private(set) var offersSettingsFallback = false
    @ObservationIgnored private weak var playerLayer: AVPlayerLayer?
    @ObservationIgnored private var pictureInPicture: (any KeyboardSetupGuidePictureInPicture)?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var layerObservation: NSKeyValueObservation?
    @ObservationIgnored private var endObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var handoffTimeout: Task<Void, Never>?
    @ObservationIgnored private let videoURL: URL?
    @ObservationIgnored private let audioSession: any KeyboardSetupGuideAudioSession
    @ObservationIgnored private let applicationState: @MainActor () -> UIApplication.State
    @ObservationIgnored private let openSettings: @MainActor () -> Void
    @ObservationIgnored private let makePictureInPicture: @MainActor (AVPlayerLayer) -> (any KeyboardSetupGuidePictureInPicture)?
    @ObservationIgnored private let isLayerReady: @MainActor (AVPlayerLayer) -> Bool
    @ObservationIgnored private var pendingSettingsLaunch = false
    @ObservationIgnored private var requestedPictureInPicture = false
    @ObservationIgnored private var restoringPictureInPicture = false
    @ObservationIgnored private var generation = UUID()

    init(
        videoURL: URL? = Bundle.main.url(forResource: "KeyboardSetupGuide", withExtension: "mp4"),
        audioSession: (any KeyboardSetupGuideAudioSession)? = nil,
        applicationState: @escaping @MainActor () -> UIApplication.State = { UIApplication.shared.applicationState },
        openSettings: @escaping @MainActor () -> Void = {
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        },
        makePictureInPicture: (@MainActor (AVPlayerLayer) -> (any KeyboardSetupGuidePictureInPicture)?)? = nil,
        isLayerReady: @escaping @MainActor (AVPlayerLayer) -> Bool = { $0.isReadyForDisplay }
    ) {
        self.videoURL = videoURL
        self.audioSession = audioSession ?? KeyboardSetupGuideSystemAudioSession()
        self.applicationState = applicationState
        self.openSettings = openSettings
        self.makePictureInPicture = makePictureInPicture ?? { KeyboardSetupGuideSystemPictureInPicture(layer: $0) }
        self.isLayerReady = isLayerReady
    }

    /// Called only by the user's Set up keyboard action, never by view appearance.
    func start(allowed: Bool) {
        guard allowed, applicationState() == .active else { return }
        stop()
        guard let url = videoURL else {
            failHandoff("The guide isn’t available. You can still set up the keyboard in Settings.")
            return
        }
        do {
            try audioSession.activate()
            pendingSettingsLaunch = true
            isPreparing = true
            let attempt = generation
            let item = AVPlayerItem(url: url)
            statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                guard item.status == .failed else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.generation == attempt else { return }
                    self.failHandoff("The guide couldn’t play. You can continue in Settings without it.")
                }
            }
            endObserver = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == attempt else { return }
                    self.stop()
                }
            }
            player = AVPlayer(playerItem: item)
            player?.play()
            handoffTimeout = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(12)) } catch { return }
                guard let self, self.generation == attempt, self.pendingSettingsLaunch else { return }
                self.failHandoff("Floating video isn’t available right now. You can continue without it.")
            }
        } catch {
            failHandoff("The guide couldn’t start. You can continue in Settings without it.")
        }
    }

    @discardableResult
    func attach(_ layer: AVPlayerLayer) -> Task<Void, Never>? {
        guard let player else { return nil }
        layer.player = player
        guard playerLayer !== layer else { return nil }
        playerLayer = layer
        let attempt = generation
        guard let pip = makePictureInPicture(layer) else {
            // Attachment occurs inside a SwiftUI representable update. Publish
            // fallback state on the next actor turn, and never tear down a new
            // attempt or replacement surface from this delayed failure.
            return Task { @MainActor [weak self, weak layer] in
                guard let self, let layer,
                      self.generation == attempt, self.playerLayer === layer else { return }
                self.failHandoff("Floating video isn’t available on this device. You can continue without it.")
            }
        }
        pictureInPicture = pip
        pip.onPossibleChanged = { [weak self] in self?.startPictureInPictureWhenReady(attempt: attempt) }
        pip.onStarted = { [weak self] in self?.pictureInPictureStarted(attempt: attempt) }
        pip.onFailed = { [weak self] in
            guard let self, self.generation == attempt else { return }
            self.failHandoff("Floating video couldn’t start. You can continue without it.")
        }
        pip.onStopped = { [weak self] in
            guard let self, self.generation == attempt else { return }
            if self.restoringPictureInPicture {
                self.restoringPictureInPicture = false
            } else {
                self.stop()
            }
        }
        pip.onRestore = { [weak self] in
            guard let self, self.generation == attempt, self.player != nil else { return false }
            self.restoringPictureInPicture = true
            return true
        }
        layerObservation = layer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.startPictureInPictureWhenReady(attempt: attempt) }
        }
        startPictureInPictureWhenReady(attempt: attempt)
        return nil
    }

    private func startPictureInPictureWhenReady(attempt: UUID) {
        guard generation == attempt, pendingSettingsLaunch, !requestedPictureInPicture else { return }
        if applicationState() == .background { stop(); return }
        guard applicationState() == .active else { return }
        guard let layer = playerLayer, isLayerReady(layer), let pip = pictureInPicture, pip.isPossible else { return }
        requestedPictureInPicture = true
        pip.start()
    }

    private func pictureInPictureStarted(attempt: UUID) {
        guard generation == attempt, pendingSettingsLaunch, requestedPictureInPicture else { return }
        // PiP animation itself may temporarily make the scene inactive.
        guard applicationState() != .background else { stop(); return }
        // Consume the handoff before opening Settings; duplicate didStart events
        // or the resulting scene transition cannot trigger a second launch.
        pendingSettingsLaunch = false
        isPreparing = false
        handoffTimeout?.cancel()
        handoffTimeout = nil
        openSettings()
    }

    func cancelPendingHandoff() {
        if pendingSettingsLaunch { stop() }
    }

    func resumePendingHandoff() {
        startPictureInPictureWhenReady(attempt: generation)
    }

    func openSettingsWithoutVideo() {
        guard offersSettingsFallback, applicationState() == .active else { return }
        stop()
        openSettings()
    }

    private func failHandoff(_ detail: String) {
        stop()
        message = detail
        offersSettingsFallback = true
    }

    func stop() {
        generation = UUID()
        pendingSettingsLaunch = false
        requestedPictureInPicture = false
        restoringPictureInPicture = false
        isPreparing = false
        handoffTimeout?.cancel()
        handoffTimeout = nil
        statusObservation = nil
        layerObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        let oldPiP = pictureInPicture
        pictureInPicture = nil
        oldPiP?.stop()
        player?.pause()
        playerLayer?.player = nil
        playerLayer = nil
        player?.replaceCurrentItem(with: nil)
        player = nil
        audioSession.release()
        message = nil
        offersSettingsFallback = false
    }
}

/// Injectable boundary keeps lifecycle tests independent of OS PiP availability.
@MainActor
protocol KeyboardSetupGuidePictureInPicture: AnyObject {
    var isPossible: Bool { get }
    var onPossibleChanged: (() -> Void)? { get set }
    var onStarted: (() -> Void)? { get set }
    var onFailed: (() -> Void)? { get set }
    var onStopped: (() -> Void)? { get set }
    var onRestore: (() -> Bool)? { get set }
    func start()
    func stop()
}

@MainActor
private final class KeyboardSetupGuideSystemPictureInPicture: NSObject,
    KeyboardSetupGuidePictureInPicture, @preconcurrency AVPictureInPictureControllerDelegate {
    var onPossibleChanged: (() -> Void)?
    var onStarted: (() -> Void)?
    var onFailed: (() -> Void)?
    var onStopped: (() -> Void)?
    var onRestore: (() -> Bool)?
    private let controller: AVPictureInPictureController
    private var possibilityObservation: NSKeyValueObservation?
    var isPossible: Bool { controller.isPictureInPicturePossible }

    init?(layer: AVPlayerLayer) {
        guard AVPictureInPictureController.isPictureInPictureSupported(),
              let controller = AVPictureInPictureController(playerLayer: layer) else { return nil }
        self.controller = controller
        super.init()
        controller.delegate = self
        // Explicit user action is the only way to arm our Settings handoff.
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        possibilityObservation = controller.observe(\.isPictureInPicturePossible, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.onPossibleChanged?() }
        }
    }

    func start() { controller.startPictureInPicture() }
    func stop() {
        possibilityObservation = nil
        controller.delegate = nil
        controller.stopPictureInPicture()
    }
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        onStarted?()
    }
    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: any Error
    ) { onFailed?() }
    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        onStopped?()
    }
    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) { completionHandler(onRestore?() ?? false) }
}

@MainActor
protocol KeyboardSetupGuideAudioSession {
    func activate() throws
    func release()
}

@MainActor
private final class KeyboardSetupGuideSystemAudioSession: KeyboardSetupGuideAudioSession {
    private var ownsSession = false
    func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        ownsSession = true
        try session.setActive(true)
    }
    func release() {
        guard ownsSession else { return }
        ownsSession = false
        let session = AVAudioSession.sharedInstance()
        if session.category == .playback, session.mode == .moviePlayback {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

private struct KeyboardSetupGuidePlayer: UIViewRepresentable {
    let playback: KeyboardSetupGuidePlayback
    func makeUIView(context: Context) -> KeyboardSetupPlayerSurface {
        let view = KeyboardSetupPlayerSurface()
        playback.attach(view.playerLayer)
        return view
    }
    func updateUIView(_ view: KeyboardSetupPlayerSurface, context: Context) { _ = playback.attach(view.playerLayer) }
    static func dismantleUIView(_ view: KeyboardSetupPlayerSurface, coordinator: ()) { view.playerLayer.player = nil }
}

private final class KeyboardSetupPlayerSurface: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    override init(frame: CGRect) {
        super.init(frame: frame)
        playerLayer.videoGravity = .resizeAspect
        backgroundColor = .black
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
