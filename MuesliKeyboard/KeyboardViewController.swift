import SwiftUI
import UIKit

final class KeyboardViewController: UIInputViewController {
    private let controller = KeyboardController()
    private var hostingController: UIHostingController<KeyboardRootView>?
    private let launchSnapshotView = UIImageView()
    private var keyboardHeightConstraint: NSLayoutConstraint?
    private var hasEnteredAppearance = false
    private var isKeyboardPresented = false
    private var hasActivatedKeyboardRuntime = false
    private var stableGeometryFrameCount = 0
    private var launchSnapshotWidth: CGFloat = 0
    private var launchGeometryDisplayLink: CADisplayLink?
    private var launchFallbackWorkItem: DispatchWorkItem?

    override func viewDidLoad() {
        super.viewDidLoad()

        // Keep UIKit's system-created input view, but declare the keyboard's
        // settled height before its first presentation. The host temporarily
        // supplies full-screen and intermediate required heights on iOS 26;
        // this 999-priority request declares the final envelope without
        // fighting those required constraints. The launch snapshot masks the
        // transient negotiation until both model and presentation settle.
        inputView?.allowsSelfSizing = false
        inputView?.backgroundColor = .clear
        inputView?.isOpaque = false
        view.backgroundColor = .clear
        view.isOpaque = false
        if let inputView {
            let heightConstraint = inputView.heightAnchor.constraint(
                equalToConstant: KeyboardRootView.preferredHeight
            )
            heightConstraint.priority = UILayoutPriority(999)
            keyboardHeightConstraint = heightConstraint
        }

        controller.textInserter = { [weak self] text in
            self?.textDocumentProxy.insertText(text)
        }
        controller.textDeleter = { [weak self] count in
            guard count > 0 else { return }
            for _ in 0..<count {
                self?.textDocumentProxy.deleteBackward()
            }
        }
        controller.inputModeSwitcher = { [weak self] in
            self?.advanceToNextInputMode()
        }
        controller.keyboardDismisser = { [weak self] in
            self?.dismissKeyboard()
        }
        controller.prepareInitialPresentationState()

        let hostingController = UIHostingController(
            rootView: KeyboardRootView(controller: controller)
        )
        hostingController.sizingOptions = []
        hostingController.view.backgroundColor = .clear
        hostingController.view.isOpaque = false
        self.hostingController = hostingController

        addChild(hostingController)
        view.addSubview(hostingController.view)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        hostingController.didMove(toParent: self)

        launchSnapshotView.translatesAutoresizingMaskIntoConstraints = false
        launchSnapshotView.backgroundColor = .clear
        launchSnapshotView.contentMode = .scaleToFill
        launchSnapshotView.clipsToBounds = true
        launchSnapshotView.isUserInteractionEnabled = false
        launchSnapshotView.accessibilityElementsHidden = true
        view.addSubview(launchSnapshotView)
        NSLayoutConstraint.activate([
            launchSnapshotView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            launchSnapshotView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            launchSnapshotView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            launchSnapshotView.heightAnchor.constraint(equalToConstant: KeyboardRootView.preferredHeight)
        ])
        refreshLaunchSnapshot()
    }

    override func viewWillAppear(_ animated: Bool) {
        controller.isLaunchSettled = false
        controller.prepareInitialPresentationState()
        refreshLaunchSnapshot()
        launchSnapshotView.isHidden = false

        super.viewWillAppear(animated)

        isKeyboardPresented = true
        hasEnteredAppearance = true
        hasActivatedKeyboardRuntime = false
        stableGeometryFrameCount = 0
        view.setNeedsUpdateConstraints()
        inputView?.setNeedsUpdateConstraints()
        startLaunchGeometryGate()
    }

    override func updateViewConstraints() {
        super.updateViewConstraints()

        guard hasEnteredAppearance, let keyboardHeightConstraint else { return }
        keyboardHeightConstraint.constant = KeyboardRootView.preferredHeight
        if !keyboardHeightConstraint.isActive {
            keyboardHeightConstraint.isActive = true
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        let laidOutWidth = view.bounds.width
        guard isKeyboardPresented,
              !hasActivatedKeyboardRuntime,
              !launchSnapshotView.isHidden,
              laidOutWidth > 0,
              abs(laidOutWidth - launchSnapshotWidth) > 1 else { return }
        refreshLaunchSnapshot()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        isKeyboardPresented = false
        hasEnteredAppearance = false
        stopLaunchGeometryGate()
        controller.isLaunchSettled = false
        launchSnapshotView.isHidden = false

        controller.stopObservingSharedState()
    }
}

private extension KeyboardViewController {
    static let settledHeightTolerance: CGFloat = 1
    static let requiredStableGeometryFrames = 2

    func startLaunchGeometryGate() {
        stopLaunchGeometryGate()

        let displayLink = CADisplayLink(target: self, selector: #selector(evaluateLaunchGeometry))
        displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        displayLink.add(to: .main, forMode: .common)
        launchGeometryDisplayLink = displayLink

        let fallback = DispatchWorkItem { [weak self] in
            self?.activateKeyboardRuntimeIfNeeded()
        }
        launchFallbackWorkItem = fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: fallback)
    }

    func stopLaunchGeometryGate() {
        launchGeometryDisplayLink?.invalidate()
        launchGeometryDisplayLink = nil
        launchFallbackWorkItem?.cancel()
        launchFallbackWorkItem = nil
        stableGeometryFrameCount = 0
    }

    @objc
    func evaluateLaunchGeometry() {
        let targetHeight = KeyboardRootView.preferredHeight
        let modelHeight = inputView?.bounds.height ?? view.bounds.height
        let presentationHeight = inputView?.layer.presentation()?.bounds.height
            ?? view.layer.presentation()?.bounds.height
            ?? modelHeight
        let modelIsSettled = abs(modelHeight - targetHeight) <= Self.settledHeightTolerance
        let presentationIsSettled = abs(presentationHeight - targetHeight) <= Self.settledHeightTolerance

        if modelIsSettled && presentationIsSettled {
            stableGeometryFrameCount += 1
        } else {
            stableGeometryFrameCount = 0
        }

        guard stableGeometryFrameCount >= Self.requiredStableGeometryFrames else { return }
        activateKeyboardRuntimeIfNeeded()
    }

    func activateKeyboardRuntimeIfNeeded() {
        guard isKeyboardPresented, !hasActivatedKeyboardRuntime else { return }
        hasActivatedKeyboardRuntime = true
        stopLaunchGeometryGate()
        revealLiveKeyboardSurface()

        // Start App Group reads and observable updates on the next run-loop
        // turn, after the settled geometry has already been presented. Keep
        // launch animations disabled while the observer performs its first
        // reconciliation so presentation state cannot visibly cross-fade.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isKeyboardPresented, self.hasActivatedKeyboardRuntime else { return }
            self.controller.startObservingSharedState()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self, self.isKeyboardPresented, self.hasActivatedKeyboardRuntime else { return }
                self.controller.isLaunchSettled = true
            }
        }
    }

    func refreshLaunchSnapshot() {
        let width = view.bounds.width
        guard width > 0 else { return }
        launchSnapshotWidth = width

        let snapshotHost = UIHostingController(
            rootView: KeyboardRootView(controller: controller)
        )
        snapshotHost.sizingOptions = []
        snapshotHost.view.backgroundColor = .clear
        snapshotHost.view.isOpaque = false
        snapshotHost.view.frame = CGRect(
            x: 0,
            y: 0,
            width: width,
            height: KeyboardRootView.preferredHeight
        )
        snapshotHost.view.setNeedsLayout()
        snapshotHost.view.layoutIfNeeded()

        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = max(view.traitCollection.displayScale, 1)
        let renderer = UIGraphicsImageRenderer(
            size: snapshotHost.view.bounds.size,
            format: format
        )
        launchSnapshotView.image = renderer.image { context in
            snapshotHost.view.layer.render(in: context.cgContext)
        }
    }

    func revealLiveKeyboardSurface() {
        UIView.performWithoutAnimation {
            launchSnapshotView.isHidden = true
        }
    }
}
