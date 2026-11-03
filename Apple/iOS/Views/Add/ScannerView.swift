@preconcurrency import AVFoundation
import SwiftUI

/// Camera scanning. Google migration codes that span several QR codes are collected one by one; the confirmation screen opens once
/// the batch is complete.
struct ScannerView: View {
    @Environment(\.dismiss) private var dismiss
    var onFinish: ([ParsedOTPAuth]) -> Void

    @State private var status: String?
    @State private var cameraError: String?
    /// The rules for collecting multi-part migration codes live in the shared `MigrationBatchCollector`.
    @State private var migrationBatches = MigrationBatchCollector()

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let cameraError {
                    ContentUnavailableView(cameraError, systemImage: "camera.fill")
                        .foregroundStyle(.white)
                } else {
                    CameraPreview(onCode: handle, onError: { cameraError = $0 })
                        .ignoresSafeArea()
                    ViewfinderOverlay()
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 6) {
                    if let progress = migrationBatches.progress {
                        Text(L10n.format("Scanned Google migration QR %1$lld / %2$lld", progress.scanned, progress.total))
                            .font(.headline)
                    }
                    Text(status ?? L10n.tr("Point the camera at the QR code"))
                        .font(.subheadline)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial.opacity(0.9), in: Capsule())
                .padding(.bottom, 16)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("Cancel")) { dismiss() }
                        .tint(.white)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
    }

    private func handle(_ payload: String) {
        let result = OTPAuthParser.parseScanResult(payload)
        guard result.hasValidAccounts else {
            status = L10n.tr("Not a valid 2FA QR code")
            return
        }
        Haptics.success()
        if case .complete(let accounts) = migrationBatches.add(result) {
            onFinish(accounts)
        }
    }
}

private struct ViewfinderOverlay: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .strokeBorder(.white.opacity(0.9), lineWidth: 3)
            .frame(width: 250, height: 250)
            .shadow(color: .black.opacity(0.3), radius: 10)
            .accessibilityHidden(true)
    }
}

/// AVCaptureSession with QR code metadata output. Camera permission follows the system flow; if denied, the user is pointed to
/// Settings.
private struct CameraPreview: UIViewControllerRepresentable {
    var onCode: (String) -> Void
    var onError: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onCode = onCode
        controller.onError = onError
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {
        controller.onCode = onCode
        controller.onError = onError
    }
}

final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    var onError: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var lastPayload: String?
    /// Each start or stop runs after the previous one, so starting and stopping never interleave.
    private var sessionTask: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    granted
                        ? self.configure()
                        : self.onError?(
                            L10n.tr("Camera access is needed to scan codes. Allow it for Kakey in Settings, or use Choose from Photos."))
                }
            }
        default:
            onError?(L10n.tr("Camera access is needed to scan codes. Allow it for Kakey in Settings, or use Choose from Photos."))
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        runOnSession { $0.stopRunning() }
    }

    /// Starting and stopping an `AVCaptureSession` blocks, so it runs in the background, serialized.
    private func runOnSession(_ work: @escaping @Sendable (AVCaptureSession) -> Void) {
        let session = session
        let previous = sessionTask
        sessionTask = Task.detached {
            await previous?.value
            work(session)
        }
    }

    private func configure() {
        guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device) else {
            onError?(L10n.tr("Can’t open the camera"))
            return
        }
        let output = AVCaptureMetadataOutput()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            onError?(L10n.tr("Can’t open the camera"))
            return
        }
        session.addInput(input)
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer
        runOnSession { $0.startRunning() }
    }

    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection
    ) {
        let payload = metadataObjects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }.first
        MainActor.assumeIsolated {
            // Handle a code only once while it stays in frame
            guard let payload, payload != lastPayload else { return }
            lastPayload = payload
            onCode?(payload)
        }
    }
}
