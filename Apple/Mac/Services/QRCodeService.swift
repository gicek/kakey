import AppKit
import CoreGraphics
import CoreImage
import Foundation

enum QRCodeService {
    static func image(for message: String, scale: CGFloat = 10) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator"),
            let data = message.data(using: .utf8)
        else {
            return nil
        }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let outputImage = filter.outputImage else { return nil }
        let transformed = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let representation = NSCIImageRep(ciImage: transformed)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }

    static func messages(in image: NSImage) -> [String] {
        guard let ciImage = CIImage(nsImage: image) else { return [] }
        return messages(in: ciImage)
    }

    static func messages(in ciImage: CIImage) -> [String] {
        let detector = CIDetector(
            ofType: CIDetectorTypeQRCode,
            context: nil,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        )
        let features = detector?.features(in: ciImage) ?? []
        return features.compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    }

    static func firstOTPAuth(in image: NSImage) -> ParsedOTPAuth? {
        firstOTPAuthScanResult(in: image)?.validAccounts.first
    }

    static func firstOTPAuthScanResult(in image: NSImage) -> OTPAuthScanResult? {
        otpAuthScanResults(in: image).first
    }

    static func otpAuthScanResults(in image: NSImage) -> [OTPAuthScanResult] {
        messages(in: image)
            .map(OTPAuthParser.parseScanResult)
            .filter { $0.hasValidAccounts }
    }
}

extension CIImage {
    convenience init?(nsImage: NSImage) {
        guard let tiffData = nsImage.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiffData)
        else {
            return nil
        }
        self.init(bitmapImageRep: bitmap)
    }
}

/// Why QR code recognition failed. Screen selection, images and the camera share the same wording across the main window, the
/// menu bar and the global shortcut. Only cases the user needs to know about are kept; `cancelled` (Esc, or closing the
/// permission guide) is the user's own action, and callers show nothing.
enum QRScanError: Equatable, LocalizedError {
    case cancelled
    /// No QR code found at all.
    case noQRCode
    /// Found a QR code, but it is not a usable TOTP / migration code (a web URL, HOTP, missing secret, unsupported parameters,
    /// and so on).
    case invalidQRCode
    case screenshotFailed
    case cameraPermission
    case cameraUnavailable

    var errorDescription: String? {
        switch self {
        case .cancelled: nil
        case .noQRCode: L10n.tr("No QR code found")
        case .invalidQRCode: L10n.tr("Not a valid 2FA QR code")
        case .screenshotFailed: L10n.tr("Screenshot failed")
        case .cameraPermission: L10n.tr("Camera access not allowed")
        case .cameraUnavailable: L10n.tr("Can’t open the camera")
        }
    }

    /// When an image has no usable code, distinguishes "no QR code at all" from "the QR code is not a verification code".
    static func unusable(_ image: NSImage) -> QRScanError {
        QRCodeService.messages(in: image).isEmpty ? .noQRCode : .invalidQRCode
    }
}

enum ScreenCaptureQRCodeService {
    static func openScreenCapturePrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }

        NSWorkspace.shared.open(url)
    }

    /// Screen-capture recognition entry point shared by the add-account sheet, the menu bar panel and the global shortcut.
    /// Without permission, the permission guide window runs first; cancelling the guide counts as cancelling the capture.
    static func captureInteractiveQRCode() async throws -> OTPAuthScanResult {
        guard await ScreenCapturePermissionController.shared.ensurePermission() else {
            throw QRScanError.cancelled
        }

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Kakey-screen-qr-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-x", fileURL.path]

        // Wait for exit without blocking the main thread: install the termination handler before launching; it only resumes the
        // continuation.
        let terminationStatus: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }

        // Esc during selection: screencapture exits normally but writes no file; treat it as a cancellation.
        guard terminationStatus == 0, FileManager.default.fileExists(atPath: fileURL.path) else {
            throw QRScanError.cancelled
        }
        guard let image = NSImage(contentsOf: fileURL) else {
            throw QRScanError.screenshotFailed
        }
        guard let parsed = QRCodeService.firstOTPAuthScanResult(in: image) else {
            throw QRScanError.unusable(image)
        }
        return parsed
    }
}
