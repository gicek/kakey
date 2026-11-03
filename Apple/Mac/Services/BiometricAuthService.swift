import Foundation
@preconcurrency import LocalAuthentication

/// Thin Mac wrapper for biometrics. Authentication and error classification live in the shared `BiometricAuth` /
/// `SystemBiometricAuthenticator`; this only keeps the Touch ID prompt wording.
/// Availability is owned by `VaultStore.biometricsAvailable`: probed once at launch and again whenever the app becomes active.
enum BiometricAuthService {
    /// Uses the Mac wording for the "use password instead" button in the prompt.
    static let authenticator = SystemBiometricAuthenticator(fallbackTitleKey: "Enter Password")

    /// Allows Touch ID or the login password, for re-authentication (such as revealing a secret) that must also work on Macs
    /// without Touch ID.
    static func authenticateDeviceOwner(reason: String) async throws {
        try await authenticator.authenticate(.deviceOwner, reason: reason)
    }

    static func message(for error: Error) -> String {
        guard let code = BiometricAuth.laCode(error) else {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }

        switch code {
        case .authenticationFailed:
            return L10n.tr("Touch ID failed; try again or enter master password")
        case .userCancel, .appCancel, .systemCancel:
            return L10n.tr("Touch ID cancelled")
        case .userFallback:
            return L10n.tr("Unlock with master password")
        case .biometryNotAvailable:
            return L10n.tr("This Mac doesn’t support Touch ID or it’s unavailable")
        case .biometryNotEnrolled:
            return L10n.tr("Add Touch ID in System Settings first")
        case .biometryLockout:
            return L10n.tr("Touch ID is locked; use master password")
        case .notInteractive:
            return L10n.tr("Cannot show Touch ID prompt right now")
        default:
            return error.localizedDescription
        }
    }

    static func isUserFallback(_ error: Error) -> Bool {
        BiometricAuth.isUserFallback(error)
    }

    static func isUserCancel(_ error: Error) -> Bool {
        BiometricAuth.isUserCancel(error)
    }

    /// Cancelled by the user, the app or the system: the UI shows nothing.
    static func isCancellation(_ error: Error) -> Bool {
        BiometricAuth.isCancellation(error)
    }
}
