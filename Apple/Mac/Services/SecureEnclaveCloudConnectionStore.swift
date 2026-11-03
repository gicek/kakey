import Foundation
import Security

/// Stores the cloud storage connection blob, wrapped by the Secure Enclave, in `cloud-connection.json` (next to the vault; deleted
/// when the app is reset). The enclave key requires only `.privateKeyUsage` with `AfterFirstUnlockThisDeviceOnly`: no Touch ID
/// prompt (background sync needs it), but the blob cannot be opened on any other Mac.
struct SecureEnclaveCloudConnectionStore: CloudConnectionStoring {
    static let fileName = "cloud-connection.json"
    private static let info = Data("com.gicek.kakey.cloud-connection".utf8)

    init() {}

    private var url: URL {
        VaultPersistenceService.vaultDirectoryURL.appendingPathComponent(Self.fileName)
    }

    func load() throws -> Data? {
        let file: SecureEnclaveSealing.File
        do {
            file = try SecureEnclaveSealing.read(from: url)
        } catch SecureEnclaveSealing.Failure.missing {
            return nil
        } catch {
            throw CloudConnectionStoreError.unreadable
        }
        do {
            return try SecureEnclaveSealing.open(file, info: Self.info)
        } catch {
            throw CloudConnectionStoreError.unreadable
        }
    }

    func save(_ connection: Data) throws {
        let createdAt = (try? SecureEnclaveSealing.read(from: url).createdAt) ?? .now
        do {
            let file = try SecureEnclaveSealing.seal(
                connection, accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, flags: .privateKeyUsage, info: Self.info,
                createdAt: createdAt)
            try SecureEnclaveSealing.write(file, to: url)
        } catch {
            throw CloudConnectionStoreError.keychain(errSecIO)
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
