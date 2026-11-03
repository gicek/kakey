import Foundation
@preconcurrency import LocalAuthentication

/// Thin iOS wrapper for biometrics. Authentication and error classification live in the shared `BiometricAuth` /
/// `SystemBiometricAuthenticator`; device capability is cached in `MobileVaultStore.biometrics`, so views never call
/// `canEvaluatePolicy`.
enum BiometricService {
    static let authenticator = SystemBiometricAuthenticator()

    /// Biometrics or device passcode, for re-authentication ("Show Secret", "Export QR Code") that must also work on devices without
    /// biometrics.
    static func authenticateOwner(reason: String) async throws {
        try await authenticator.authenticate(.deviceOwner, reason: reason)
    }

    static func isCancellation(_ error: Error) -> Bool {
        BiometricAuth.isCancellation(error)
    }

    static func message(for error: Error) -> String {
        let name = BiometricCapability.current.displayName
        guard let code = BiometricAuth.laCode(error) else { return error.localizedDescription }
        switch code {
        case .biometryLockout:
            return L10n.format("%@ is locked. Enter your master password.", name)
        case .biometryNotAvailable, .biometryNotEnrolled, .passcodeNotSet:
            return L10n.format("%@ isn’t available. Check that it’s set up in Settings.", name)
        default:
            return L10n.format("%@ didn’t recognize you. Try again or enter your master password.", name)
        }
    }
}
