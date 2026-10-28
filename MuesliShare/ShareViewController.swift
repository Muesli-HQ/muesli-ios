import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let status = UILabel()
    private let done = UIButton(type: .system)
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        status.text = "Saving audio… Open Muesli to transcribe."
        status.numberOfLines = 0
        status.textAlignment = .center
        done.setTitle("Done", for: .normal)
        done.addTarget(self, action: #selector(finish), for: .touchUpInside)
        done.isEnabled = false
        let stack = UIStackView(arrangedSubviews: [status, done])
        stack.axis = .vertical; stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        guard providers.count == 1, let provider = providers.first,
              let type = provider.registeredTypeIdentifiers.first(where: {
                  guard let type = UTType($0) else { return false }
                  return type.conforms(to: .audio) || type.conforms(to: .mpeg4Movie)
              }) else {
            status.text = "Share one audio file at a time."; done.isEnabled = true; return
        }
        // The provider URL is valid only within this callback; copy before returning.
        let suggestedTitle = provider.suggestedName.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
        provider.loadFileRepresentation(forTypeIdentifier: type) { [weak self] url, error in
            do {
                if let error { throw error }
                guard let url else { throw CocoaError(.fileReadUnknown) }
                _ = try AudioImportInbox.enqueue(url, title: suggestedTitle)
                // The inbox is durable now. Dismiss the extension without requiring
                // another tap; the app presents the pending import on activation.
                Task { @MainActor [weak self] in self?.finish() }
            } catch {
                let message = "Could not save audio. \(error.localizedDescription)"
                Task { @MainActor [weak self] in
                    self?.status.text = message
                    self?.done.isEnabled = true
                }
            }
        }
    }
    @objc private func finish() { extensionContext?.completeRequest(returningItems: nil) }
}
