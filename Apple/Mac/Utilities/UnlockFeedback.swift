import Foundation

/// Feedback for screen-capture recognition and import results: the desktop toast, the menu bar panel footer and queued results
/// after unlocking all take their wording and tone from here.
extension VaultStore.CaptureImportResult {
    var feedbackMessage: String {
        switch self {
        case .added(let issuer): L10n.format("Added %@", issuer)
        case .duplicate(let issuer): L10n.format("%@ already exists", issuer)
        }
    }

    var feedbackKind: DesktopToastController.Kind {
        switch self {
        case .added: .success
        case .duplicate: .error
        }
    }
}

/// Delivers results queued while locked once unlocking succeeds: QR codes recognized while locked and copy requests queued by
/// external automation. Both unlock paths (the main window lock screen and the menu bar panel) call this.
@MainActor
enum UnlockFeedback {
    static func showPendingResults(from store: VaultStore, toasts: DesktopToastController = .shared) {
        if let result = store.consumePendingCaptureImportResult() {
            toasts.show(result.feedbackMessage, kind: result.feedbackKind)
        }
        if let issuer = store.consumePendingCopyResultIssuer() {
            toasts.show(L10n.format("Copied %@'s code", issuer), kind: .success)
        }
    }
}
