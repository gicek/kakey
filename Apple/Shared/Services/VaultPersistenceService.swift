import CryptoKit
import Foundation

/// Errors from vault operations; the localization key comes from the core's `core_error_l10n_key`.
enum VaultPersistenceError: LocalizedError {
    case emptyPassword
    case unacceptablePassword
    case invalidPassword
    case corruptVault
    case keyDerivationFailed
    case invalidKey
    case cryptoFailure

    var coreError: KakeyError {
        switch self {
        case .emptyPassword: .EmptyPassword
        case .unacceptablePassword: .UnacceptablePassword
        case .invalidPassword: .InvalidPassword
        case .corruptVault: .CorruptVault
        case .keyDerivationFailed: .KeyDerivationFailed
        case .invalidKey: .InvalidKey
        case .cryptoFailure: .CryptoFailure
        }
    }

    var errorDescription: String? {
        L10n.tr(coreErrorL10nKey(error: coreError))
    }
}

/// File IO for the local encrypted vault.
///
/// The envelope format, key derivation (Argon2id) and AES-256-GCM encryption all live in the Rust core
/// (`Core/crates/kakey-core/src/vault.rs`; format in docs/SECURITY.md). This only handles file locations, the
/// last-known-good snapshot and atomic replacement. At runtime every call is serialized through the `VaultFileStore`
/// actor; tests call these synchronous methods directly.
enum VaultPersistenceService {
    private static let override = Locked<URL?>(nil)

    /// Redirects the vault to a temporary location for tests and previews.
    static var vaultURLOverride: URL? {
        get { override.value }
        set { override.value = newValue }
    }

    static var vaultURL: URL {
        if let vaultURLOverride {
            return vaultURLOverride
        }
        // The test host never touches the user's real vault directory.
        if AppEnvironment.isTestHost {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("kakey-testhost", isDirectory: true)
                .appendingPathComponent("vault.json")
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Kakey", isDirectory: true).appendingPathComponent("vault.json")
    }

    static var vaultDirectoryURL: URL {
        vaultURL.deletingLastPathComponent()
    }

    static var lastKnownGoodVaultURL: URL {
        vaultDirectoryURL.appendingPathComponent("vault.last-known-good.json")
    }

    static var vaultExists: Bool {
        FileManager.default.fileExists(atPath: vaultURL.path)
    }

    static var lastKnownGoodVaultExists: Bool {
        FileManager.default.fileExists(atPath: lastKnownGoodVaultURL.path)
    }

    static func encryptedVaultData() throws -> Data {
        try Data(contentsOf: vaultURL)
    }

    /// Envelope validation and metadata that need no password (version, KDF, creation and update times).
    static func encryptedVaultEnvelope(from data: Data) throws -> CoreEnvelopeInfo {
        do {
            return try coreVaultEnvelopeInfo(data: data)
        } catch {
            throw VaultPersistenceError.corruptVault
        }
    }

    @discardableResult
    static func replaceEncryptedVault(with data: Data) throws -> CoreEnvelopeInfo {
        let envelope = try encryptedVaultEnvelope(from: data)
        let url = vaultURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try preserveCurrentVaultAsLastKnownGood()
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return envelope
    }

    /// Recovers from a corrupt main file using the last decodable envelope: unlocks the snapshot with the master password
    /// first (proving it is usable), then replaces the main file.
    @discardableResult
    static func restoreLastKnownGoodVault(password: String) throws -> (contents: VaultContents, key: SymmetricKey) {
        let backupData = try Data(contentsOf: lastKnownGoodVaultURL)
        let unlocked = try unlock(encryptedData: backupData, password: password)
        try replaceEncryptedVault(with: backupData)
        return unlocked
    }

    /// Write times (the envelope's `updatedAt`, export file timestamps) come from the caller's clock, defaulting to now.
    /// `VaultFileStore` passes its injected clock, so tests need no real waiting to get distinct second-resolution times.
    static func openCurrentVault(key: SymmetricKey, now: Date = .now) throws -> VaultContents {
        let data = try readVaultData()
        return VaultContents(try core { try coreVaultOpen(data: data, key: key.data) })
    }

    /// Exports the selected accounts. Categories keep only those accounts (filtered by the core); empty categories are not
    /// exported.
    static func exportData(accounts: [Account], categories: [AccountCategory], password: String, now: Date = .now) throws -> Data {
        try core {
            try coreExportAccounts(accounts: accounts.map(\.core), categories: categories.map(\.core), password: password, now: now)
        }
    }

    static func export(accounts: [Account], categories: [AccountCategory], password: String, to url: URL) throws {
        let data = try exportData(accounts: accounts, categories: categories, password: password)
        try data.write(to: url, options: [.atomic])
    }

    static func createVault(password: String, accounts: [Account] = [], now: Date = .now) throws -> SymmetricKey {
        try save(VaultContents(accounts: accounts, categories: []), password: password, now: now)
    }

    /// Writes a new vault with the master password, using a fresh random salt and the current KDF (new vault, password
    /// change).
    @discardableResult
    static func save(_ contents: VaultContents, password: String, now: Date = .now) throws -> SymmetricKey {
        let created = try core { try coreVaultCreate(password: password, contents: contents.core, now: now) }
        try write(created.data)
        return SymmetricKey(data: created.key)
    }

    /// Saves while unlocked, keeping the existing envelope's salt, KDF metadata and creation time.
    static func save(_ contents: VaultContents, key: SymmetricKey, now: Date = .now) throws {
        let existing = try readVaultData()
        let data = try core { try coreVaultReseal(existing: existing, key: key.data, contents: contents.core, now: now) }
        try write(data)
    }

    static func unlock(password: String) throws -> (contents: VaultContents, key: SymmetricKey) {
        try unlock(encryptedData: try readVaultData(), password: password)
    }

    /// Unlocks a vault file from any source (main file, backup copy, last-known-good snapshot).
    static func unlock(encryptedData data: Data, password: String) throws -> (contents: VaultContents, key: SymmetricKey) {
        let unlocked = try core { try coreVaultUnlock(data: data, password: password) }
        return (VaultContents(unlocked.contents), SymmetricKey(data: unlocked.key))
    }

    /// Resets the app by deleting the vault directory (main file, last-known-good snapshot, backup history and biometric key
    /// file).
    static func removeAllFiles() {
        try? FileManager.default.removeItem(at: vaultDirectoryURL)
    }

    // The core has already re-parsed the data in memory and verified it decrypts with the same key; this keeps the previous
    // decodable envelope as last-known-good, then atomically replaces the main file.
    private static func write(_ data: Data) throws {
        let url = vaultURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try preserveCurrentVaultAsLastKnownGood()
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }

    private static func preserveCurrentVaultAsLastKnownGood() throws {
        guard FileManager.default.fileExists(atPath: vaultURL.path) else { return }

        let currentData = try Data(contentsOf: vaultURL)
        guard coreVaultIsValidEnvelope(data: currentData) else {
            return
        }

        let backupURL = lastKnownGoodVaultURL
        try FileManager.default.createDirectory(at: backupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try currentData.write(to: backupURL, options: [.atomic, .completeFileProtection])
    }

    private static func readVaultData() throws -> Data {
        do {
            return try Data(contentsOf: vaultURL)
        } catch {
            throw VaultPersistenceError.corruptVault
        }
    }

    /// Maps core errors to `VaultPersistenceError`, so UI text and callers' error handling stay the same.
    private static func core<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as KakeyError {
            throw error.vaultError
        }
    }
}

private extension SymmetricKey {
    var data: Data { withUnsafeBytes { Data($0) } }
}
