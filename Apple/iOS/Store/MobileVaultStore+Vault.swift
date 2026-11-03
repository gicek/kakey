import Foundation

/// Master password and data: change master password, encrypted export, reset.
extension MobileVaultStore {
    // MARK: - Master password and data

    /// Changes the master password: waits for queued saves and syncs to finish, then re-encrypts the latest file contents in the
    /// background. A wrong current password counts toward consecutive failures, just like unlocking.
    func changePassword(current: String, new: String) async -> String? {
        guard !isWorking else { return L10n.tr("Unable to change master password") }
        if let remaining = lockoutRemaining {
            return L10n.format("Too many attempts. Try again in %lld seconds", Int(remaining.rounded(.up)))
        }
        isWorking = true
        defer { isWorking = false }
        syncDebounceTask?.cancel()
        await persistence.drain()
        do {
            let rekeyed = try await files.rekey(currentPassword: current, newPassword: new)
            lockoutState = .cleared
            finishUnlock(rekeyed.contents, key: rekeyed.key)
            if preferences.biometricsEnabled { await storeBiometricKey() }
            return nil
        } catch VaultPersistenceError.invalidPassword {
            lockoutState = UnlockLockout.registeringFailure(lockoutState, now: now())
            return VaultPersistenceError.invalidPassword.errorDescription
        } catch {
            return L10n.tr("Unable to change master password")
        }
    }

    /// Syncs right after a master password change and returns whether the backup now uses the new password. True when no backup
    /// is set up; false on failure, conflict, or a backup that cannot be decrypted, in which case the UI warns that the backup still
    /// holds the vault encrypted with the old password.
    func backupUpdatedAfterPasswordChange() async -> Bool {
        guard syncLocation != nil else { return true }
        await sync(sourceKey: "icloud.hist.auto")
        return syncStatus == .idle
    }

    /// Encrypted export (its own password, salt, and nonce); the key is derived on a background actor.
    func exportBackup(password: String) async throws -> Data {
        isWorking = true
        defer { isWorking = false }
        return try await files.exportData(accounts: accounts, categories: categories, password: password)
    }

    /// "Reset App" in Settings: even when unlocked, requires Face ID / Touch ID or the device passcode on the spot, so someone with
    /// brief access to an unlocked device cannot wipe the data. Without a device passcode (`passcodeNotSet`) the system cannot
    /// verify, and only the confirmation dialog stands in the way.
    func resetApplicationAfterAuthentication() async -> Bool {
        do {
            try await authenticator.authenticate(.deviceOwner, reason: L10n.tr("Reset Kakey and erase local data"))
        } catch {
            guard BiometricAuth.laCode(error) == .passcodeNotSet else { return false }
        }
        syncDebounceTask?.cancel()
        await persistence.drain()
        resetApplication()
        return true
    }

    /// Clears the local vault (including the last-known-good snapshot and backup history), the biometric key, cloud storage
    /// credentials, and settings; the remote backup is not affected.
    func resetApplication() {
        lock()
        disconnectCloud()
        // iCloud: only cancel this device's change subscription; the backup in iCloud stays (same as other locations)
        if syncLocation?.isICloud == true { disableICloudPush() }
        VaultPersistenceService.removeAllFiles()
        keyStore.remove()
        MobilePreferences.remove(from: settings)
        preferences = MobilePreferences()
        syncHistory = []
        syncStatus = .notConfigured
        syncBackend = nil
        syncBackendLocation = nil
        biometricKeyAvailable = false
        lastKnownGoodRestoreAvailable = false
        autoBiometricPromptSuppressed = false
        phase = .onboarding
    }
}
