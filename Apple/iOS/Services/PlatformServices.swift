import SwiftUI
import UIKit
import UniformTypeIdentifiers
import Vision

/// Writes sensitive text to the local pasteboard only (`localOnly`, so Universal Clipboard never syncs it to other devices) and lets
/// it expire via `expirationDate` (one period for a verification code, 60 seconds for a secret).
@MainActor
final class LocalPasteboardClipboard: SecretClipboard {
    static let shared = LocalPasteboardClipboard()

    init() {}

    func copy(_ text: String, expiresAfter seconds: TimeInterval) {
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: text]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(seconds)]
        )
    }
}

/// Reads the pasteboard (pasting a setup link).
enum Clipboard {
    static var text: String? {
        UIPasteboard.general.string
    }
}

/// Privacy cover shown above every window (including sheets) in the app switcher and in the background. It is a separate `UIWindow`
/// above the presentation layer rather than an overlay on the root view; with an overlay, sheets would float above the cover and
/// the snapshot could still show a secret.
@MainActor
final class PrivacyCoverController {
    static let shared = PrivacyCoverController()

    private var windows: [ObjectIdentifier: UIWindow] = [:]

    init() {}

    func setCovered(_ covered: Bool) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            let id = ObjectIdentifier(scene)
            if covered {
                guard windows[id] == nil else { continue }
                let window = UIWindow(windowScene: scene)
                window.windowLevel = .alert + 1
                window.rootViewController = UIHostingController(rootView: PrivacyCover())
                window.isHidden = false
                windows[id] = window
            } else {
                windows[id]?.isHidden = true
                windows[id] = nil
            }
        }
        if !covered {
            for window in windows.values { window.isHidden = true }
            windows = [:]
        }
    }
}

enum Haptics {
    @MainActor static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    @MainActor static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}

/// Reads QR code content from an image (Vision, entirely on device, nothing is uploaded).
enum QRImageDecoder {
    static func payloads(in image: UIImage) async -> [String] {
        guard let cgImage = image.cgImage else { return [] }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        return await Task.detached(priority: .userInitiated) {
            let request = VNDetectBarcodesRequest()
            request.symbologies = [.qr]
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation)
            try? handler.perform([request])
            return (request.results ?? []).compactMap(\.payloadStringValue)
        }.value
    }

    static func payloads(in data: Data) async -> [String] {
        guard let image = UIImage(data: data) else { return [] }
        return await payloads(in: image)
    }
}

extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}

enum DeviceInfo {
    @MainActor static var name: String { UIDevice.current.name }
}
