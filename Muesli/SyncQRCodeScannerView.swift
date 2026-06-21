@preconcurrency import AVFoundation
import SwiftUI

struct SyncQRCodeScannerView: View {
    let isSyncAlreadyEnabled: Bool
    let onOpenSyncURL: (URL) -> Void
    let onEnableSyncURL: (URL) -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var cameraAuthorization = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var statusText: String?
    @State private var scanResult: ScanResult?
    @State private var pendingSyncURL: URL?

    init(
        isSyncAlreadyEnabled: Bool = false,
        onOpenSyncURL: @escaping (URL) -> Void,
        onEnableSyncURL: @escaping (URL) -> Bool
    ) {
        self.isSyncAlreadyEnabled = isSyncAlreadyEnabled
        self.onOpenSyncURL = onOpenSyncURL
        self.onEnableSyncURL = onEnableSyncURL
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    Text("Scan Mac QR")
                        .font(MuesliTheme.title1())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text("Point your iPhone at the QR code shown in Muesli on your Mac. The code only opens setup; private iCloud does the sync.")
                        .font(MuesliTheme.callout())
                        .foregroundStyle(MuesliTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                scannerSurface

                if let statusText {
                    Text(statusText)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(MuesliTheme.spacing20)
            .background(MuesliTheme.backgroundBase)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .task {
                await refreshCameraAuthorization()
            }
        }
    }

    @ViewBuilder
    private var scannerSurface: some View {
        switch cameraAuthorization {
        case .authorized:
            QRCodeScannerRepresentable { payload in
                handleScannedPayload(payload)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 340)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerLarge))
            .overlay {
                RoundedRectangle(cornerRadius: MuesliTheme.cornerLarge)
                    .stroke(MuesliTheme.surfaceBorder, lineWidth: 1)
            }
            .overlay(alignment: .center) {
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .stroke(MuesliTheme.accent, lineWidth: 3)
                    .frame(width: 190, height: 190)
            }
            .overlay {
                if let scanResult {
                    scanResultSurface(scanResult)
                        .padding(MuesliTheme.spacing20)
                }
            }
        case .notDetermined:
            permissionSurface(
                icon: "camera",
                title: "Camera access",
                detail: "Allow camera access to scan the setup QR from your Mac.",
                buttonTitle: "Allow Camera"
            ) {
                Task { await requestCameraAccess() }
            }
        case .denied, .restricted:
            permissionSurface(
                icon: "camera.fill",
                title: "Camera access is off",
                detail: "Turn on Camera access for Muesli in Settings, then return here to scan your Mac setup QR.",
                buttonTitle: "Open Settings"
            ) {
                openAppSettings()
            }
        @unknown default:
            permissionSurface(
                icon: "exclamationmark.triangle",
                title: "Camera unavailable",
                detail: "Use the iPhone Camera app to scan the setup QR instead.",
                buttonTitle: "Done"
            ) {
                dismiss()
            }
        }
    }

    private func permissionSurface(
        icon: String,
        title: String,
        detail: String,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        MuesliSurface(cornerRadius: MuesliTheme.cornerLarge) {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                Image(systemName: icon)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(MuesliTheme.accent)

                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    Text(title)
                        .font(MuesliTheme.headline())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text(detail)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button(action: action) {
                    Text(buttonTitle)
                        .font(MuesliTheme.headline())
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(MuesliTheme.accent)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            }
            .padding(MuesliTheme.spacing16)
        }
    }

    private func scanResultSurface(_ result: ScanResult) -> some View {
        VStack(spacing: MuesliTheme.spacing12) {
            Image(systemName: result.icon)
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(result.tint)

            VStack(spacing: MuesliTheme.spacing4) {
                Text(result.title)
                    .font(MuesliTheme.title2())
                    .foregroundStyle(MuesliTheme.textPrimary)
                    .multilineTextAlignment(.center)
                Text(result.detail)
                    .font(MuesliTheme.callout())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                handleScanResultAction(result)
            } label: {
                Text(result.buttonTitle)
                    .font(MuesliTheme.headline())
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .foregroundStyle(.white)
                    .background(result.tint)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                    .contentShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            }
            .buttonStyle(.plain)
        }
        .padding(MuesliTheme.spacing20)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerLarge))
        .overlay {
            RoundedRectangle(cornerRadius: MuesliTheme.cornerLarge)
                .stroke(result.tint.opacity(0.45), lineWidth: 1)
        }
    }

    private func handleScanResultAction(_ result: ScanResult) {
        switch result {
        case .readyToEnable:
            guard let pendingSyncURL else { return }
            if onEnableSyncURL(pendingSyncURL) {
                self.pendingSyncURL = nil
                scanResult = .syncStarted
            } else {
                scanResult = .needsICloud
            }
        case .alreadySynced, .syncStarted, .needsICloud:
            dismiss()
        }
    }

    private func refreshCameraAuthorization() async {
        cameraAuthorization = AVCaptureDevice.authorizationStatus(for: .video)
    }

    private func requestCameraAccess() async {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        cameraAuthorization = granted ? .authorized : AVCaptureDevice.authorizationStatus(for: .video)
    }

    private func handleScannedPayload(_ payload: String) -> Bool {
        guard let url = URL(string: payload),
              url.scheme == MuesliAppConstants.urlScheme,
              url.host == MuesliAppConstants.syncHost
        else {
            statusText = "That QR code is not a Muesli sync setup code."
            scanResult = nil
            return false
        }

        onOpenSyncURL(url)
        if isSyncAlreadyEnabled {
            statusText = nil
            scanResult = .alreadySynced
        } else {
            pendingSyncURL = url
            statusText = nil
            scanResult = .readyToEnable
        }
        return true
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

private enum ScanResult {
    case alreadySynced
    case readyToEnable
    case syncStarted
    case needsICloud

    var icon: String {
        switch self {
        case .alreadySynced:
            return "checkmark.circle.fill"
        case .readyToEnable:
            return "icloud.and.arrow.up"
        case .syncStarted:
            return "checkmark.icloud.fill"
        case .needsICloud:
            return "exclamationmark.icloud.fill"
        }
    }

    var title: String {
        switch self {
        case .alreadySynced:
            return "Already synced"
        case .readyToEnable:
            return "Ready to sync"
        case .syncStarted:
            return "Sync is on"
        case .needsICloud:
            return "iCloud needs attention"
        }
    }

    var detail: String {
        switch self {
        case .alreadySynced:
            return "You are all set. This iPhone and your Mac are already sharing text history through private iCloud."
        case .readyToEnable:
            return "This QR is valid. Turn on private iCloud sync to share dictations, meeting transcripts, notes, and summaries with your Mac."
        case .syncStarted:
            return "Muesli is syncing your text history through private iCloud. Audio recordings stay local."
        case .needsICloud:
            return "Sign in to iCloud on this iPhone, then scan the Mac QR again."
        }
    }

    var tint: Color {
        switch self {
        case .alreadySynced, .syncStarted:
            return MuesliTheme.success
        case .readyToEnable:
            return MuesliTheme.accent
        case .needsICloud:
            return MuesliTheme.recording
        }
    }

    var buttonTitle: String {
        switch self {
        case .readyToEnable:
            return "Turn on private iCloud sync"
        case .alreadySynced, .syncStarted, .needsICloud:
            return "Done"
        }
    }
}

private struct QRCodeScannerRepresentable: UIViewControllerRepresentable {
    let onCodeScanned: (String) -> Bool

    func makeUIViewController(context: Context) -> QRCodeScannerViewController {
        QRCodeScannerViewController(onCodeScanned: onCodeScanned)
    }

    func updateUIViewController(_ uiViewController: QRCodeScannerViewController, context: Context) {}
}

private final class QRCodeScannerViewController: UIViewController, @preconcurrency AVCaptureMetadataOutputObjectsDelegate {
    private let session = AVCaptureSession()
    private let previewLayer = AVCaptureVideoPreviewLayer()
    private let sessionQueue = DispatchQueue(label: "com.muesli.qr-scanner.session")
    private let onCodeScanned: (String) -> Bool
    private var didScanCode = false

    init(onCodeScanned: @escaping (String) -> Bool) {
        self.onCodeScanned = onCodeScanned
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer.frame = view.bounds
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        sessionQueue.async { [session] in
            guard !session.isRunning else { return }
            session.startRunning()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sessionQueue.async { [session] in
            guard session.isRunning else { return }
            session.stopRunning()
        }
    }

    private func configureSession() {
        guard let videoDevice = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: videoDevice),
              session.canAddInput(input)
        else { return }

        session.addInput(input)

        let metadataOutput = AVCaptureMetadataOutput()
        guard session.canAddOutput(metadataOutput) else { return }
        session.addOutput(metadataOutput)
        metadataOutput.setMetadataObjectsDelegate(self, queue: .main)
        metadataOutput.metadataObjectTypes = [.qr]
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !didScanCode,
              let metadataObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let payload = metadataObject.stringValue
        else { return }

        didScanCode = onCodeScanned(payload)
    }
}
