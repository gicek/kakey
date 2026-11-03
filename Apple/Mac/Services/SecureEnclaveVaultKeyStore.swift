import Foundation
@preconcurrency import LocalAuthentication
import Security

/// Stores the vault key for Touch ID unlock.
///
/// Why not the Keychain: on macOS, items with biometric access control must live in the data protection Keychain
/// (`kSecUseDataProtectionKeychain`), which requires a team-signed application-identifier; local ad-hoc builds without a
/// Developer ID certificate get errSecMissingEntitlement (-34018). The Secure Enclave is used instead (every supported Mac is
/// Apple silicon):
/// - Generate a P-256 key with access control `.privateKeyUsage | .biometryCurrentSet`: the private key never leaves the enclave,
///   every use requires Touch ID on the spot, and adding or removing a fingerprint invalidates it permanently.
/// - Wrap the 32-byte vault key ECIES-style: ECDH between an ephemeral P-256 key and the enclave public key -> HKDF-SHA256 ->
///   AES-256-GCM.
/// - Only the enclave-exported key handle (usable only by this Mac's enclave), the ephemeral public key and the ciphertext are
///   written to disk; other processes cannot open the file.
/// Touch ID is passed explicitly before unwrapping, and the same `LAContext` restores the handle for key agreement, so the user
/// is prompted only once. Wrapping and storage live in `SecureEnclaveSealing`.
struct SecureEnclaveVaultKeyStore: VaultKeyStoring {
    static let fileName = "biometric-key.json"
    private static let hkdfInfo = Data("com.gicek.kakey.biometric-vault-key".utf8)

    init() {}

    private var url: URL {
        VaultPersistenceService.vaultDirectoryURL.appendingPathComponent(Self.fileName)
    }

    func save(_ key: Data) throws {
        let createdAt = (try? readFile().createdAt) ?? .now
        do {
            let file = try SecureEnclaveSealing.seal(
                key, accessibility: kSecAttrAccessibleWhenUnlockedThisDeviceOnly, flags: [.privateKeyUsage, .biometryCurrentSet],
                info: Self.hkdfInfo, createdAt: createdAt)
            try SecureEnclaveSealing.write(file, to: url)
        } catch SecureEnclaveSealing.Failure.unavailable {
            throw VaultKeyStoreError.keychain(errSecNotAvailable)
        } catch SecureEnclaveSealing.Failure.accessControl {
            throw VaultKeyStoreError.keychain(errSecParam)
        } catch SecureEnclaveSealing.Failure.io {
            throw VaultKeyStoreError.keychain(errSecIO)
        } catch {
            throw VaultKeyStoreError.keychain(errSecInternalError)
        }
    }

    func load(reason: String) async throws -> Data {
        let file = try readFile()
        let context = LAContext()
        context.localizedCancelTitle = L10n.tr("Cancel")
        context.localizedFallbackTitle = L10n.tr("Enter Password")
        _ = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)

        return try await Task.detached {
            // An invalidated handle (fingerprints changed) or a corrupt file both count as stale material: the caller deletes it
            // and falls back to the master password.
            guard let opened = try? SecureEnclaveSealing.open(file, info: Self.hkdfInfo, context: context), opened.count == 32 else {
                throw VaultKeyStoreError.invalidKeyMaterial
            }
            return opened
        }.value
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    func hasKey() -> Bool {
        (try? readFile()) != nil
    }

    private func readFile() throws -> SecureEnclaveSealing.File {
        do {
            return try SecureEnclaveSealing.read(from: url)
        } catch SecureEnclaveSealing.Failure.missing {
            throw VaultKeyStoreError.missingKey
        } catch {
            throw VaultKeyStoreError.invalidKeyMaterial
        }
    }
}
