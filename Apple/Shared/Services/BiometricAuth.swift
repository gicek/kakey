import Foundation
@preconcurrency import LocalAuthentication

/// Shared biometric and device-credential authentication. Platform files keep only their own prompt text.

enum BiometricPolicy: Sendable {
    /// Biometrics only (quick unlock).
    case biometrics
    /// Biometrics or the system / device passcode (re-authentication to reveal a secret or QR code, reset, etc.).
    case deviceOwner

    var laPolicy: LAPolicy {
        switch self {
        case .biometrics: .deviceOwnerAuthenticationWithBiometrics
        case .deviceOwner: .deviceOwnerAuthentication
        }
    }
}

/// Authentication entry point; stores receive it by injection, and tests use an in-memory implementation.
protocol BiometricAuthenticating: Sendable {
    func authenticate(_ policy: BiometricPolicy, reason: String) async throws
}

/// The device's biometric capability. `canEvaluatePolicy` is a synchronous XPC call, so it is probed and cached at launch,
/// re-probed only on a background thread, and never called from a view body.
struct BiometricCapability: Sendable, Equatable {
    var isAvailable: Bool
    var biometryType: LABiometryType

    static let none = BiometricCapability(isAvailable: false, biometryType: .none)

    /// The probe result at launch, read by `KakeyApp` / `MobileVaultStore` on startup. The Mac `VaultStore` also calls
    /// `detect()` on a background thread when the app becomes active (a Touch ID keyboard may be attached or a fingerprint
    /// enrolled); iOS hardware does not change, so it does not re-probe.
    static let current: BiometricCapability = detect()

    static func detect() -> BiometricCapability {
        let context = LAContext()
        let available = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return BiometricCapability(isAvailable: available, biometryType: context.biometryType)
    }

    /// Localized name for Face ID, Touch ID or Optic ID; without biometric hardware, the platform's default name.
    var displayName: String {
        switch biometryType {
        case .touchID: L10n.tr("Touch ID")
        case .opticID: L10n.tr("Optic ID")
        case .faceID: L10n.tr("Face ID")
        default:
            #if os(macOS)
                L10n.tr("Touch ID")
            #else
                L10n.tr("Face ID")
            #endif
        }
    }

    var symbolName: String {
        switch biometryType {
        case .touchID: "touchid"
        case .opticID: "opticid"
        case .faceID: "faceid"
        default:
            #if os(macOS)
                "touchid"
            #else
                "faceid"
            #endif
        }
    }
}

enum BiometricAuth {
    static func laCode(_ error: Error) -> LAError.Code? {
        let nsError = error as NSError
        guard nsError.domain == LAError.errorDomain else { return nil }
        return LAError.Code(rawValue: nsError.code)
    }

    static func isUserCancel(_ error: Error) -> Bool {
        laCode(error) == .userCancel
    }

    /// Cancellation by the user, app or system: no message, not counted as an error.
    static func isCancellation(_ error: Error) -> Bool {
        guard let code = laCode(error) else { return false }
        return code == .userCancel || code == .appCancel || code == .systemCancel
    }

    static func isUserFallback(_ error: Error) -> Bool {
        laCode(error) == .userFallback
    }
}

/// `LocalAuthentication` implementation. `fallbackTitleKey` is the L10n key for the prompt's "use password" button (nil
/// uses the system default).
struct SystemBiometricAuthenticator: BiometricAuthenticating {
    var fallbackTitleKey: String?

    init(fallbackTitleKey: String? = nil) {
        self.fallbackTitleKey = fallbackTitleKey
    }

    func authenticate(_ policy: BiometricPolicy, reason: String) async throws {
        let context = LAContext()
        context.localizedCancelTitle = L10n.tr("Cancel")
        if let fallbackTitleKey {
            context.localizedFallbackTitle = L10n.tr(fallbackTitleKey)
        }
        _ = try await context.evaluatePolicy(policy.laPolicy, localizedReason: reason)
    }
}

/// Test double that succeeds or throws a preset error, and records every request.
final class StubBiometricAuthenticator: BiometricAuthenticating, @unchecked Sendable {
    private let state = Locked<(result: Result<Void, Error>, requests: [BiometricPolicy])>((.success(()), []))

    init() {}

    var result: Result<Void, Error> {
        get { state.value.result }
        set { state.withLock { $0.result = newValue } }
    }

    var requests: [BiometricPolicy] {
        state.value.requests
    }

    func authenticate(_ policy: BiometricPolicy, reason: String) async throws {
        try state.withLock {
            $0.requests.append(policy)
            return $0.result
        }.get()
    }
}
