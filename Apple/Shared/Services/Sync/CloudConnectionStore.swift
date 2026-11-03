import Foundation

/// Storage for the cloud storage connection blob (an opaque serialization of the core `cloudset::Connection`, including a
/// password or token).
///
/// Device-only and never carried in backups. It does not require biometrics, because first-time restore must download the
/// remote envelope before the vault is unlocked. iOS uses the Keychain (`KeychainCloudConnectionStore`); Mac uses a file
/// wrapped by the Secure Enclave (`SecureEnclaveCloudConnectionStore`, for the same reason as `SecureEnclaveVaultKeyStore`).
/// Tests use an in-memory implementation.
protocol CloudConnectionStoring: Sendable {
    func load() throws -> Data?
    func save(_ connection: Data) throws
    func remove()
}

enum CloudConnectionStoreError: LocalizedError {
    case keychain(OSStatus)
    case unreadable

    var errorDescription: String? {
        L10n.tr(coreCloudErrorL10nKey(error: .InvalidConnection))
    }
}

/// In-memory implementation for the test host and unit tests; never touches the Keychain or Secure Enclave.
final class InMemoryCloudConnectionStore: CloudConnectionStoring, @unchecked Sendable {
    private let state: Locked<Data?>

    init(_ connection: Data? = nil) {
        state = Locked(connection)
    }

    func load() throws -> Data? {
        state.value
    }

    func save(_ connection: Data) throws {
        state.value = connection
    }

    func remove() {
        state.value = nil
    }
}
