import Foundation
@preconcurrency import LocalAuthentication
import Security

/// Storage for the vault key used by biometric quick unlock, shared by Mac and iOS.
///
/// Loading performs one explicit biometric check and then reads the key with the same `LAContext`, so the user is
/// prompted only once. iOS uses the Keychain (`KeychainVaultKeyStore`), Mac the Secure Enclave
/// (`SecureEnclaveVaultKeyStore`); tests use an in-memory implementation.
protocol VaultKeyStoring: Sendable {
    func save(_ key: Data) throws
    func load(reason: String) async throws -> Data
    func remove()
    func hasKey() -> Bool
}

enum VaultKeyStoreError: LocalizedError {
    case keychain(OSStatus)
    case missingKey
    case invalidKeyMaterial

    var errorDescription: String? {
        switch self {
        case .keychain, .missingKey, .invalidKeyMaterial:
            L10n.format("Unlock once with your master password to re-enable %@.", BiometricCapability.current.displayName)
        }
    }
}

/// Keychain generic password item with access control `.biometryCurrentSet` (invalidated when a face or fingerprint is
/// added or removed) and `WhenPasscodeSetThisDeviceOnly` (unavailable without a device passcode, never carried to other
/// devices by backup or migration). iOS only: on macOS, items with biometric access control must live in the data
/// protection Keychain, which needs a Team-signed application-identifier that local ad-hoc builds lack (see the Mac
/// `SecureEnclaveVaultKeyStore`).
struct KeychainVaultKeyStore: VaultKeyStoring {
    private let service = "com.gicek.kakey.vault-key"
    private let account = "biometric-unlock"

    init() {}

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func save(_ key: Data) throws {
        remove()
        var error: Unmanaged<CFError>?
        guard
            let access = SecAccessControlCreateWithFlags(
                nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .biometryCurrentSet, &error
            )
        else {
            throw VaultKeyStoreError.keychain(errSecParam)
        }
        var query = baseQuery
        query[kSecValueData as String] = key
        query[kSecAttrAccessControl as String] = access
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw VaultKeyStoreError.keychain(status) }
    }

    func load(reason: String) async throws -> Data {
        let context = LAContext()
        context.localizedCancelTitle = L10n.tr("Cancel")
        context.localizedFallbackTitle = L10n.tr("Enter Master Password")
        try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
        let query = baseQuery
        return try await Task.detached {
            var request = query
            request[kSecReturnData as String] = true
            request[kSecUseAuthenticationContext as String] = context
            var result: CFTypeRef?
            let status = SecItemCopyMatching(request as CFDictionary, &result)
            switch status {
            case errSecSuccess:
                guard let data = result as? Data else { throw VaultKeyStoreError.missingKey }
                return data
            case errSecItemNotFound:
                throw VaultKeyStoreError.missingKey
            default:
                throw VaultKeyStoreError.keychain(status)
            }
        }.value
    }

    func remove() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    /// Checks without any prompt whether the key still exists (the system invalidates it when biometrics change).
    func hasKey() -> Bool {
        let context = LAContext()
        context.interactionNotAllowed = true
        var request = baseQuery
        request[kSecUseAuthenticationContext as String] = context
        let status = SecItemCopyMatching(request as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }
}

/// In-memory implementation for the test host and unit tests; never touches the Keychain or Secure Enclave. `failLoad`
/// simulates an invalidated key.
final class InMemoryVaultKeyStore: VaultKeyStoring, @unchecked Sendable {
    private let state = Locked<(key: Data?, failLoad: Bool, loadError: Error?)>((nil, false, nil))

    init() {}

    var failLoad: Bool {
        get { state.value.failLoad }
        set { state.withLock { $0.failLoad = newValue } }
    }

    /// When non-nil, `load` throws this error (simulating an `LAError` such as user cancel or fallback to password).
    var loadError: Error? {
        get { state.value.loadError }
        set { state.withLock { $0.loadError = newValue } }
    }

    func save(_ key: Data) throws {
        state.withLock { $0.key = key }
    }

    func load(reason: String) async throws -> Data {
        let (key, failLoad, loadError) = state.value
        if let loadError { throw loadError }
        guard !failLoad, let key else { throw VaultKeyStoreError.missingKey }
        return key
    }

    func remove() {
        state.withLock { $0.key = nil }
    }

    func hasKey() -> Bool {
        state.value.key != nil
    }
}
