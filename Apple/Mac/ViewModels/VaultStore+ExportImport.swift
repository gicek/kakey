import Foundation

/// Backup file import and encrypted export.
extension VaultStore {
    /// Imports a backup file (Kakey encrypted export, Authenticator plain text / v3 encrypted). Parsing and Argon2id run on a
    /// background actor. Categories in the file merge into existing ones by name (created if missing); accounts skipped as
    /// duplicates keep their existing membership.
    func importBackupFile(at url: URL, password: String) async throws -> (inserted: Int, skipped: Int) {
        guard canWriteVault() else { throw ExternalAccountImportError.failed }
        guard let data = try? ExternalFileLimits.read(contentsOf: url) else { throw ExternalAccountImportError.invalidFile }
        isWorking = true
        defer { isWorking = false }
        let imported = try await files.importBackup(data, password: password)
        guard canWriteVault() else { throw ExternalAccountImportError.failed }
        let inserted = document.insert(imported.importCandidates, addedBy: AccountProvenance.imported, now: now())
        if inserted > 0 {
            saveVault()
        }
        return (inserted, imported.accounts.count - inserted)
    }

    /// Exports the selected accounts to an encrypted file (separate password, salt and nonce).
    func exportAccounts(_ selected: [Account], password: String, to url: URL) async throws {
        isWorking = true
        defer { isWorking = false }
        let data = try await files.exportData(accounts: selected, categories: categories, password: password)
        try data.write(to: url, options: [.atomic])
    }

    // MARK: - First run: restore from an export file

    /// The user picked a file for first-run restore: only confirm it is a Kakey encrypted export; decrypt once the export password
    /// is entered.
    func prepareOnboardingExport(from url: URL) -> OnboardingRestoreOutcome {
        vaultError = nil
        pendingOnboardingRestore = nil
        pendingOnboardingExport = PendingOnboardingExport(contentsOf: url)
        guard pendingOnboardingExport != nil else {
            vaultError = OnboardingExportError.notAnExport.errorDescription
            return .failed
        }
        return .found
    }

    /// Opens the file with the export password and creates a vault with `masterPassword`; when "Use as master password" is checked,
    /// that is the export password. Does not create a vault if the master password fails the rules. Enables no backup location.
    func completeExportOnboarding(password: String, masterPassword: String) async -> Bool {
        vaultError = nil
        guard let pending = pendingOnboardingExport else {
            vaultError = L10n.tr("Unable to restore from backup")
            return false
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let contents = try await pending.restoredContents(password: password, masterPassword: masterPassword, files: files, now: now())
            let key = try await files.create(password: masterPassword, contents: contents)
            pendingOnboardingExport = nil
            hasCompletedOnboarding = true
            finishUnlock(contents, key: key)
            await persistKeyForTouchID()
            return true
        } catch {
            vaultError = error.localizedDescription
            return false
        }
    }
}
