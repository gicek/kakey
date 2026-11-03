import Foundation
import Security

/// Stores the cloud storage connection blob as a Keychain generic password item with `AfterFirstUnlockThisDeviceOnly`, so it
/// never travels with backups or device migration. No biometric gate: the first restore needs it before the vault is unlocked.
struct KeychainCloudConnectionStore: CloudConnectionStoring {
    private let service = "com.gicek.kakey.cloud-connection"
    private let account = "default"

    init() {}

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func load() throws -> Data? {
        var request = baseQuery
        request[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw CloudConnectionStoreError.unreadable }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw CloudConnectionStoreError.keychain(status)
        }
    }

    func save(_ connection: Data) throws {
        remove()
        var query = baseQuery
        query[kSecValueData as String] = connection
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw CloudConnectionStoreError.keychain(status) }
    }

    func remove() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
