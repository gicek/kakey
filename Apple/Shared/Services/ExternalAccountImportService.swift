import Foundation

/// Failure categories for importing a backup file. Kakey exports and Authenticator backups share the same wording, and
/// import never shows the vault-unlock messages ("incorrect master password", "invalid vault file format").
enum ExternalAccountImportError: LocalizedError, Equatable {
    case passwordRequired
    /// Wrong format, corrupt or unreadable file.
    case invalidFile
    case wrongPassword
    case noSupportedAccounts
    /// System failure, e.g. in the crypto layer.
    case failed

    /// The localization key comes from the core's `core_error_l10n_key`; `.failed` uses platform wording (the core has no
    /// matching error).
    var errorDescription: String? {
        switch self {
        case .passwordRequired: L10n.tr(coreErrorL10nKey(error: .PasswordRequired))
        case .invalidFile: L10n.tr(coreErrorL10nKey(error: .InvalidFile))
        case .wrongPassword: L10n.tr(coreErrorL10nKey(error: .WrongPassword))
        case .noSupportedAccounts: L10n.tr(coreErrorL10nKey(error: .NoSupportedAccounts))
        case .failed: L10n.tr("Import failed. Try again.")
        }
    }
}

/// Imports a backup file: tries Kakey's own encrypted export first, then the Authenticator formats (plaintext JSON and v3
/// encrypted JSON). Parsing and decryption live in the Rust core (`Core/crates/kakey-core/src/authenticator.rs`,
/// `vault.rs`). The result is not yet deduplicated against existing accounts; `VaultDocument.insert` handles insertion.
/// Categories in an export file come back as-is; pinned Authenticator entries go into the Favorites category. The only
/// import entry point on Mac and iOS.
enum ExternalAccountImportService {
    static func importAccounts(from data: Data, password: String) throws -> VaultContents {
        do {
            return VaultContents(adoptingPinned: try coreImportBackup(data: data, password: password, now: .now, placeholders: .current))
        } catch let error as KakeyError {
            throw error.importError
        }
    }

    static func importAccounts(from url: URL, password: String) throws -> VaultContents {
        guard let data = try? ExternalFileLimits.read(contentsOf: url) else {
            throw ExternalAccountImportError.invalidFile
        }
        return try importAccounts(from: data, password: password)
    }
}

/// A Kakey encrypted export file chosen for first-time restore (same behavior on all three platforms). Kept in memory only;
/// once decrypted with the export password, a new vault is created with the master password. The master password is set
/// separately by default, or is the export password when the user checks "use as master password".
struct PendingOnboardingExport {
    var data: Data
    var fileName: String

    /// Reads the file and returns nil unless it is a Kakey encrypted export. URLs from the iOS file picker need
    /// security-scoped access.
    init?(contentsOf url: URL) {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? ExternalFileLimits.read(contentsOf: url), coreIsKakeyExport(data: data) else { return nil }
        self.data = data
        fileName = url.lastPathComponent
    }

    /// Decrypts with the export password and builds the new vault's contents (categories merged by name, deduplicated as on
    /// import). Refuses to create the vault if the master password breaks the rules: the UI already enforces them for a
    /// separately set password, so this mainly catches "use as master password" with a noncompliant export password.
    func restoredContents(password: String, masterPassword: String, files: VaultFileStore, now: Date) async throws -> VaultContents {
        let imported = try await files.importBackup(data, password: password)
        guard PasswordPolicy.isAcceptableMasterPassword(masterPassword) else { throw OnboardingExportError.unusableMasterPassword }
        var document = VaultDocument()
        document.insert(imported.importCandidates, addedBy: AccountProvenance.imported, now: now)
        return document.contents
    }
}

enum OnboardingExportError: LocalizedError {
    case notAnExport
    case unusableMasterPassword

    var errorDescription: String? {
        switch self {
        case .notAnExport: L10n.tr("This file isn’t a Kakey export")
        case .unusableMasterPassword:
            L10n.tr("This export password can’t be used as a master password. Turn off “Use as Master Password” and set one.")
        }
    }
}

extension VaultContents {
    /// Converts the import result into insertion candidates (core `candidates_from_import`): each account carries the names
    /// of its categories and keeps its original creation time.
    var importCandidates: [CoreAccountCandidate] {
        (try? coreCandidatesFromImport(imported: core)) ?? []
    }
}
