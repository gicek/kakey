import AVFoundation
import AppKit
import SwiftUI

/// The "Scan QR Code" tab: three source cards (select screen area, choose image, use camera), a status line that follows the source
/// and progress, and the combined results. Google migration batch progress accumulates across sources (rules in the shared
/// `MigrationBatchCollector`).
struct QRScanPanel: View {
    @Binding var detectedItems: [ParsedOTPAuth]
    @Binding var migrationBatches: MigrationBatchCollector
    /// Scan failure (cancellation is not recorded); shown only on the left of the bottom bar, like "account already exists".
    @Binding var scanError: QRScanError?
    /// The user clicked a source card: the parent hides the "account already exists" error.
    var onSourceSelected: () -> Void

    @State private var qrCameraRequested = false
    /// The source the user clicked; nothing is preselected on open, and both the selected style and the hint below follow it.
    @State private var scanSource: ScanSource?
    /// Changes on every "Use Camera" click, rebuilding the preview and requesting camera access again.
    @State private var cameraSessionID = UUID()
    /// Shows a waiting indicator until the camera delivers frames (the system can take over a second to start the camera).
    @State private var cameraReady = false
    @State private var isProcessing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ScanSourceCard(
                    title: L10n.tr("Select on Screen"),
                    detail: L10n.tr("A QR code in a web page or another app"),
                    systemImage: "rectangle.dashed",
                    isSelected: scanSource == .screen,
                    isBusy: isProcessing
                ) {
                    select(.screen)
                    captureScreenQRCode()
                }
                ScanSourceCard(
                    title: L10n.tr("Choose Images"),
                    detail: L10n.tr("Screenshots or photos; pick several at once"),
                    systemImage: "photo.on.rectangle",
                    isSelected: scanSource == .image
                ) {
                    select(.image)
                    selectQRCodeImage()
                }
                ScanSourceCard(
                    title: L10n.tr("Use Camera"),
                    detail: L10n.tr("Point at a QR code on a phone or paper"),
                    systemImage: "camera.viewfinder",
                    isSelected: scanSource == .camera
                ) {
                    select(.camera)
                    startCamera()
                }
            }
            // Card height comes from the content, all three equal, and does not stretch as the camera area below expands or collapses.
            .fixedSize(horizontal: false, vertical: true)
            .disabled(isProcessing)

            if qrCameraRequested && shouldKeepScanningQRCode {
                cameraPreview
            }

            Label(scanStatus.text, systemImage: scanStatus.systemImage)
                .font(.system(size: 12))
                .foregroundStyle(scanStatus.color)
                .lineLimit(1)
            if !detectedItems.isEmpty {
                detectedCards(detectedItems)
            }
        }
        .animation(.easeOut(duration: 0.16), value: qrCameraRequested)
    }

    private var cameraPreview: some View {
        QRCodeCameraScanner(
            isActive: true,
            onResult: { result in
                appendScannedQRCodeResult(result)
                scanError = nil
            },
            onError: { error in
                scanError = error
                // Permission or device problem: collapse the preview instead of leaving an empty area.
                if error == .cameraPermission || error == .cameraUnavailable {
                    qrCameraRequested = false
                }
            },
            onReady: { cameraReady = true }
        )
        .id(cameraSessionID)
        .frame(height: 180)
        .background(Color.primary.opacity(0.05))
        .overlay {
            if !cameraReady {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.tr("Starting camera"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Button {
                qrCameraRequested = false
                scanSource = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .help(L10n.tr("Turn Off Camera"))
            .accessibilityLabel(L10n.tr("Turn Off Camera"))
            .padding(8)
        }
        .transition(.opacity)
    }

    private var shouldKeepScanningQRCode: Bool {
        if detectedItems.isEmpty { return true }
        return migrationBatches.isAwaitingMoreCodes
    }

    /// Opens the camera: first confirms there is a device and permission, then expands the preview; on error it stays collapsed.
    /// Once camera access has been denied the system never prompts again and it can only be enabled in System Settings, so the
    /// user is taken there directly.
    private func startCamera() {
        qrCameraRequested = false
        guard AVCaptureDevice.default(for: .video) != nil else {
            scanError = .cameraUnavailable
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            showCameraPreview()
        case .notDetermined:
            Task {
                if await AVCaptureDevice.requestAccess(for: .video) {
                    showCameraPreview()
                } else {
                    scanError = .cameraPermission
                }
            }
        default:
            scanError = .cameraPermission
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func showCameraPreview() {
        guard scanSource == .camera else { return }
        cameraReady = false
        cameraSessionID = UUID()
        qrCameraRequested = true
    }

    /// Switches source: leaving the camera stops the preview, and the previous source's error is cleared.
    private func select(_ source: ScanSource) {
        scanSource = source
        scanError = nil
        onSourceSelected()
        if source != .camera {
            qrCameraRequested = false
        }
    }

    /// The scan tab's one-line status. Recognizing, migration progress and completion take priority; otherwise it says what to do next
    /// with the selected source. Pending actions use the secondary color, an in-progress migration batch uses the accent color, and
    /// green is used only when everything is recognized.
    private var scanStatus: (text: String, systemImage: String, color: Color) {
        if isProcessing {
            return (L10n.tr("Recognizing"), "hourglass", .secondary)
        }
        if !detectedItems.isEmpty {
            if migrationBatches.isAwaitingMoreCodes, let progress = migrationBatches.progress {
                return (
                    L10n.format("Scanned Google migration QR %1$lld / %2$lld", progress.scanned, progress.total), "square.stack",
                    .accentColor
                )
            }
            return (L10n.format("Recognized %lld accounts", detectedItems.count), "checkmark.circle", .green)
        }
        switch scanSource {
        case nil:
            return (L10n.tr("Choose how to scan"), "hand.point.up.left", .secondary)
        case .screen:
            return ScreenCapturePermissionController.shared.isGranted
                ? (L10n.tr("Drag to select the QR code on screen"), "rectangle.dashed", .secondary)
                : (L10n.tr("Needs Screen Recording permission the first time"), "lock.shield", .secondary)
        case .image:
            return (L10n.tr("You can choose several images at once"), "photo.on.rectangle", .secondary)
        case .camera:
            // On error the bottom bar already explains why; here we only say how to try again.
            return scanError == nil
                ? (L10n.tr("Point the camera at the QR code"), "camera.viewfinder", .secondary)
                : (L10n.tr("Click the card to try again"), "arrow.clockwise", .secondary)
        }
    }

    private func selectQRCodeImage() {
        scanError = nil
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK else { return }

        var didRecognize = false
        var failure = QRScanError.noQRCode
        for url in panel.urls {
            guard let image = NSImage(contentsOf: url) else { continue }
            let results = QRCodeService.otpAuthScanResults(in: image)
            guard !results.isEmpty else {
                if QRScanError.unusable(image) == .invalidQRCode { failure = .invalidQRCode }
                continue
            }

            didRecognize = true
            results.forEach(appendScannedQRCodeResult)
        }

        if !didRecognize {
            scanError = failure
        }
    }

    /// Selects a screen area: results join the same list, so one migration code can be captured from the screen and the rest added
    /// from images or the camera.
    private func captureScreenQRCode() {
        scanError = nil
        qrCameraRequested = false
        isProcessing = true
        Task {
            do {
                let result = try await ScreenCaptureQRCodeService.captureInteractiveQRCode()
                appendScannedQRCodeResult(result)
            } catch QRScanError.cancelled {
                // The user pressed Esc or closed the permission guide: show nothing; clicking the card again retries.
            } catch let error as QRScanError {
                scanError = error
            } catch {
                scanError = .screenshotFailed
            }
            isProcessing = false
        }
    }

    private func appendScannedQRCodeResult(_ result: OTPAuthScanResult) {
        // Rules in `MigrationBatchCollector`: a different set of migration codes (different batchID) discards the previous progress.
        switch migrationBatches.add(result) {
        case .complete(let accounts):
            detectedItems = (detectedItems + accounts.filter(\.isValid)).deduplicatedForDisplay
        case .partial:
            detectedItems = (detectedItems + result.validAccounts).deduplicatedForDisplay
        }
    }

    private func detectedCards(_ items: [ParsedOTPAuth]) -> some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(items) { item in
                    detectedCard(item)
                }
            }
            .padding(.vertical, 1)
        }
        .frame(height: min(CGFloat(items.count), 4) * 58 + min(CGFloat(max(items.count - 1, 0)), 3) * 8 + 2)
    }

    private func detectedCard(_ item: ParsedOTPAuth) -> some View {
        HStack(spacing: 12) {
            Text(Account.monogram(for: item.issuer))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Account.color(for: item.issuer), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.issuer).font(.system(size: 13, weight: .semibold))
                Text(item.account).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer()
            Label(L10n.tr("Parsed"), systemImage: "checkmark")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.green)
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
    }
}

private enum ScanSource {
    case screen
    case image
    case camera
}

/// A source card on the scan tab: icon, name and a one-line description; only the card the user clicked shows the selected style.
private struct ScanSourceCard: View {
    var title: String
    var detail: String
    var systemImage: String
    var isSelected = false
    var isBusy = false
    var action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Group {
                    if isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: systemImage)
                            .font(.system(size: 20, weight: .regular))
                    }
                }
                .frame(height: 24)
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Height comes only from the content; the outer HStack aligns all three cards to the tallest.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(12)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(
            isSelected ? Color.accentColor.opacity(0.08) : Color.primary.opacity(isHovered && isEnabled ? 0.07 : 0.04),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.accentColor.opacity(0.8) : Color(nsColor: .separatorColor).opacity(0.6),
                    lineWidth: isSelected ? 1.5 : 1
                )
        }
        .opacity(isEnabled ? 1 : 0.6)
        .onHover { isHovered = $0 }
    }
}
