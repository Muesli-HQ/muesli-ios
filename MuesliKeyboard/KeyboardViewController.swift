import SwiftUI
import UIKit

final class KeyboardViewController: UIInputViewController {
    private let controller = KeyboardController()
    private var hostingController: UIHostingController<KeyboardRootView>?

    override func viewDidLoad() {
        super.viewDidLoad()

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
        let rootView = KeyboardRootView(controller: controller)
        let hostingController = UIHostingController(rootView: rootView)
        self.hostingController = hostingController

        addChild(hostingController)
        view.addSubview(hostingController.view)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 292)
        ])
        hostingController.didMove(toParent: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        controller.markKeyboardVisible()
        controller.startPolling()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        controller.startPolling()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        controller.stopPolling()
    }
}
