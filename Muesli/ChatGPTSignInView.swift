import SafariServices
import SwiftUI

struct ChatGPTSignInView: View {
    @Environment(\.dismiss) private var dismiss
    let onSignedIn: () -> Void
    @State private var code: ChatGPTDeviceCode?
    @State private var errorMessage: String?
    @State private var showBrowser = false
    @State private var attempt = UUID()

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(MuesliTheme.title1())
                if let code {
                    Text("Enter this code on the ChatGPT sign-in page.")
                        .multilineTextAlignment(.center)
                    Text(code.userCode)
                        .font(.title.monospaced().bold())
                        .textSelection(.enabled)
                        .accessibilityLabel("Sign-in code: \(code.userCode)")
                    Button("Copy Code & Continue") {
                        UIPasteboard.general.string = code.userCode
                        showBrowser = true
                    }
                    .buttonStyle(.borderedProminent)
                    Text("Return here after approving. The code expires in 15 minutes.")
                        .font(MuesliTheme.callout())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else if errorMessage == nil {
                    ProgressView("Starting sign-in…")
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Try Again") { attempt = UUID() }
                } else if code != nil {
                    ProgressView("Waiting for approval…")
                }
                Spacer()
            }
            .padding(24)
            .navigationTitle("Sign in to ChatGPT")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .sheet(isPresented: $showBrowser) {
                ChatGPTSignInBrowser(url: ChatGPTDeviceCode.verificationURL)
            }
            .task(id: attempt) {
                code = nil
                errorMessage = nil
                do {
                    try await ChatGPTAuthManager.shared.signIn { code = $0 }
                    try Task.checkCancellation()
                    showBrowser = false
                    onSignedIn()
                    dismiss()
                } catch is CancellationError {
                    // Dismissing the sheet cancels polling without replacing credentials.
                } catch {
                    guard !Task.isCancelled else { return }
                    showBrowser = false
                    code = nil
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

private struct ChatGPTSignInBrowser: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
