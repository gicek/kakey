import AppKit
import Foundation

/// Writes sensitive text to the system pasteboard:
/// - Declares both `org.nspasteboard.ConcealedType` (clipboard managers neither record nor show it) and
///   `org.nspasteboard.TransientType` (kept out of history).
/// - Clears automatically when it expires: verification codes after the account's period, secrets and URIs after 60 seconds.
///   Clears only if the pasteboard still holds this write (compared by `changeCount`), so anything the user copied later is
///   left alone.
@MainActor
final class PasteboardClipboard: SecretClipboard {
    static let shared = PasteboardClipboard()

    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    private var clearTask: Task<Void, Never>?
    private var ownedChangeCount: Int?

    init() {}

    func copy(_ text: String, expiresAfter seconds: TimeInterval) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, Self.concealedType, Self.transientType], owner: nil)
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: Self.concealedType)
        pasteboard.setData(Data(), forType: Self.transientType)
        let changeCount = pasteboard.changeCount
        ownedChangeCount = changeCount

        clearTask?.cancel()
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.ownedChangeCount == changeCount,
                NSPasteboard.general.changeCount == changeCount
            else { return }
            NSPasteboard.general.clearContents()
            self.ownedChangeCount = nil
        }
    }
}
