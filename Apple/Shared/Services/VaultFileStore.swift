import CryptoKit
import Foundation

/// The single entry point for reading and writing the vault file.
///
/// All disk operations run serially on this actor, so the Argon2id work in unlock, password change, import and export stays
/// off the main thread, and the two writers (UI saves and sync downloads) never interleave on the same file. The envelope
/// format, last-known-good snapshot and atomic replace live in `VaultPersistenceService` (synchronous static methods that
/// tests call directly); the Mac and iOS stores only update in-memory state on the main actor. Write times come from an
/// injected clock (the current time by default), so tests can space out the envelope's second-resolution `updatedAt`.
actor VaultFileStore {
    static let shared = VaultFileStore()

    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    var vaultExists: Bool {
        VaultPersistenceService.vaultExists
    }

    var lastKnownGoodExists: Bool {
        VaultPersistenceService.lastKnownGoodVaultExists
    }

    func create(password: String, contents: VaultContents = VaultContents(accounts: [], categories: [])) throws -> SymmetricKey {
        try VaultPersistenceService.save(contents, password: password, now: now())
    }

    func unlock(password: String) throws -> (contents: VaultContents, key: SymmetricKey) {
        try VaultPersistenceService.unlock(password: password)
    }

    func unlock(encryptedData: Data, password: String) throws -> (contents: VaultContents, key: SymmetricKey) {
        try VaultPersistenceService.unlock(encryptedData: encryptedData, password: password)
    }

    func open(key: SymmetricKey) throws -> VaultContents {
        try VaultPersistenceService.openCurrentVault(key: key, now: now())
    }

    func save(_ contents: VaultContents, key: SymmetricKey) throws {
        try VaultPersistenceService.save(contents, key: key, now: now())
    }

    /// Changes the master password: decrypts the latest file contents with the current password, then rewrites everything
    /// with the new one; callers swap the in-memory key only after this returns. The file is the source of truth rather than
    /// a caller's in-memory snapshot, so saves queued earlier are never lost.
    func rekey(currentPassword: String, newPassword: String) throws -> (contents: VaultContents, key: SymmetricKey) {
        let now = now()
        let unlocked = try VaultPersistenceService.unlock(password: currentPassword)
        let key = try VaultPersistenceService.save(unlocked.contents, password: newPassword, now: now)
        return (unlocked.contents, key)
    }

    /// The local encrypted envelope, or nil when there is no vault.
    func encryptedData() throws -> Data? {
        guard VaultPersistenceService.vaultExists else { return nil }
        return try VaultPersistenceService.encryptedVaultData()
    }

    @discardableResult
    func replaceEncryptedVault(with data: Data) throws -> CoreEnvelopeInfo {
        try VaultPersistenceService.replaceEncryptedVault(with: data)
    }

    func restoreLastKnownGood(password: String) throws -> (contents: VaultContents, key: SymmetricKey) {
        try VaultPersistenceService.restoreLastKnownGoodVault(password: password)
    }

    func exportData(accounts: [Account], categories: [AccountCategory], password: String) throws -> Data {
        try VaultPersistenceService.exportData(accounts: accounts, categories: categories, password: password, now: now())
    }

    func importBackup(_ data: Data, password: String) throws -> VaultContents {
        try ExternalAccountImportService.importAccounts(from: data, password: password)
    }

    /// Reset: deletes every file in the vault directory (main file, last-known-good snapshot, backup history, biometric key
    /// file).
    func removeAllFiles() {
        VaultPersistenceService.removeAllFiles()
    }
}
