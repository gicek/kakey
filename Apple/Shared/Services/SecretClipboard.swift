import Foundation

/// Clipboard for sensitive text (verification codes, secrets, otpauth URIs).
///
/// Both implementations mark the content as local-only / excluded from history and clear it after `seconds` (only if it
/// still holds what was written). Verification codes expire with the account period; secrets and URIs use
/// `ClipboardExpiry.secret`.
@MainActor
protocol SecretClipboard: AnyObject {
    func copy(_ text: String, expiresAfter seconds: TimeInterval)
}

enum ClipboardExpiry {
    /// For content that never expires on its own, such as secrets and otpauth URIs.
    static let secret: TimeInterval = 60
}

/// Test double that records the text and expiry without touching the system clipboard.
@MainActor
final class RecordingClipboard: SecretClipboard {
    struct Entry: Equatable {
        var text: String
        var expiresAfter: TimeInterval
    }

    private(set) var entries: [Entry] = []

    init() {}

    func copy(_ text: String, expiresAfter seconds: TimeInterval) {
        entries.append(Entry(text: text, expiresAfter: seconds))
    }
}
