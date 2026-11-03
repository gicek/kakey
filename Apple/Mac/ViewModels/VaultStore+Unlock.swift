import AppKit
import CryptoKit
import Foundation

/// Master password and Touch ID unlock, the delay after repeated failures, creating the vault and changing the master password.
extension VaultStore {
    // MARK: - Unlock

    func unlock(password: String) async -> Bool {
        vaultError = nil
        guard !isUnlocking else { return false }
        if let waitSeconds = remainingLockoutSeconds() {
            vaultError = L10n.format("Too many attempts. Try again in %lld seconds", waitSeconds)
            return false
        }

        isUnlocking = true
        isWorking = true
        defer {
            isUnlocking = false
            isWorking = false
        }
        do {
            let unlocked = try await files.unlock(password: password)
            finishUnlock(unlocked.contents, key: unlocked.key)
            clearFailedUnlocks()
            await persistKeyForTouchID()
            return true
        } catch {
            await handleUnlockFailure(error)
            return false
        }
    }

    /// Restores from the last-known-good snapshot and unlocks when the main file is corrupt (offered by the lock screen when
    /// `lastKnownGoodRestoreAvailable`).
    func restoreLastKnownGoodVault(password: String) async -> Bool {
        vaultError = nil
        guard !isUnlocking else { return false }
        if let waitSeconds = remainingLockoutSeconds() {
            vaultError = L10n.format("Too many attempts. Try again in %lld seconds", waitSeconds)
            return false
        }
        isUnlocking = true
        isWorking = true
        defer {
            isUnlocking = false
            isWorking = false
        }
        do {
            let restored = try await files.restoreLastKnownGood(password: password)
            lastKnownGoodRestoreAvailable = false
            finishUnlock(restored.contents, key: restored.key)
            clearFailedUnlocks()
            await persistKeyForTouchID()
            return true
        } catch {
            await handleUnlockFailure(error)
            return false
        }
    }

    private func handleUnlockFailure(_ error: Error) async {
        if case VaultPersistenceError.invalidPassword = error {
            registerFailedUnlock()
        }
        if case VaultPersistenceError.corruptVault = error {
            lastKnownGoodRestoreAvailable = await files.lastKnownGoodExists
        }
        vaultError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private var lockoutState: UnlockLockoutState {
        get {
            UnlockLockoutState(
                consecutiveFailures: settings.integer(forKey: Self.failedUnlockCountKey),
                lockoutUntil: settings.date(forKey: Self.lockoutUntilKey)
            )
        }
        set {
            settings.set(newValue.consecutiveFailures == 0 ? nil : newValue.consecutiveFailures, forKey: Self.failedUnlockCountKey)
            settings.set(newValue.lockoutUntil, forKey: Self.lockoutUntilKey)
        }
    }

    func remainingLockoutSeconds() -> Int? {
        guard lockoutDelayEnabled else { return nil }
        return UnlockLockout.remainingSeconds(lockoutState, now: now())
    }

    private func registerFailedUnlock() {
        guard lockoutDelayEnabled else { return }
        lockoutState = UnlockLockout.registeringFailure(lockoutState, now: now())
    }

    private func clearFailedUnlocks() {
        settings.removeObject(forKey: Self.failedUnlockCountKey)
        settings.removeObject(forKey: Self.lockoutUntilKey)
    }

    /// Turning off the failure delay weakens brute-force protection, so it requires Touch ID or the system password on the spot;
    /// turning it on does not.
    func setLockoutDelayEnabled(_ enabled: Bool) async {
        guard enabled != lockoutDelayEnabled else { return }
        if !enabled {
            do {
                try await authenticator.authenticate(.deviceOwner, reason: L10n.tr("turn off the delay after failed attempts"))
            } catch {
                return
            }
            clearFailedUnlocks()
        }
        lockoutDelayEnabled = enabled
        settings.set(enabled, forKey: Self.lockoutDelayEnabledKey)
    }

    func unlockWithTouchID(reason: String) async -> Bool {
        vaultError = nil
        lastTouchIDErrorWasUserFallback = false
        guard touchIDEnabled else {
            vaultError = L10n.tr("Touch ID is turned off in Settings")
            return false
        }
        guard biometricsAvailable else {
            vaultError = L10n.tr("Touch ID is unavailable on this Mac")
            return false
        }

        do {
            let key = SymmetricKey(data: try await keyStore.load(reason: reason))
            let contents = try await files.open(key: key)
            finishUnlock(contents, key: key)
            clearFailedUnlocks()
            return true
        } catch let error as VaultKeyStoreError {
            // Material missing, invalidated (fingerprints changed) or corrupt: delete it and fall back to the master password.
            keyStore.remove()
            biometricKeyAvailable = false
            vaultError = error.errorDescription
            return false
        } catch let error as VaultPersistenceError {
            // The key does not match the current vault (for example, a version encrypted with another password was restored from
            // iCloud).
            keyStore.remove()
            biometricKeyAvailable = false
            vaultError = error.errorDescription
            return false
        } catch {
            lastTouchIDErrorWasUserFallback = BiometricAuth.isUserFallback(error)
            // After the user cancels or switches to the password, lock screens stop prompting Touch ID automatically until the next
            // natural lock.
            if lastTouchIDErrorWasUserFallback || BiometricAuth.isCancellation(error) {
                autoTouchIDSuppressed = true
            }
            vaultError = BiometricAuthService.message(for: error)
            return false
        }
    }

    /// Common wrap-up after a successful unlock: load contents, fulfill queued requests, refresh the index, and start the auto-lock
    /// count from now (unlocking counts as activity).
    func finishUnlock(_ contents: VaultContents, key: SymmetricKey) {
        document = VaultDocument(contents)
        vaultKey = key
        isLocked = false
        lastKnownGoodRestoreAvailable = false
        if syncLocation != nil {
            startAutomaticSync()
        }
        importPendingCaptureAccountsAfterUnlockIfNeeded()
        resolvePendingCopyAfterUnlockIfNeeded()
        refreshSearchIndex()
        lastActivityAt = now()
        scheduleAutoLock()
    }

    // MARK: - Master password

    func createVault(masterPassword: String) async -> Bool {
        guard !isFetchingOnboardingRestore else { return false }
        vaultError = nil
        isWorking = true
        defer { isWorking = false }
        do {
            pendingOnboardingRestore = nil
            pendingOnboardingExport = nil
            let key = try await files.create(password: masterPassword, contents: document.contents)
            hasCompletedOnboarding = true
            finishUnlock(document.contents, key: key)
            await persistKeyForTouchID()
            return true
        } catch {
            vaultError = error.localizedDescription
            return false
        }
    }

    /// Changes the master password: waits for queued saves and syncs to finish, then re-encrypts the latest file contents on a
    /// background actor. A wrong current password counts toward consecutive failures, as with unlocking.
    func changeMasterPassword(currentPassword: String, newPassword: String) async -> Bool {
        vaultError = nil
        guard !isRekeying else { return false }
        if let waitSeconds = remainingLockoutSeconds() {
            vaultError = L10n.format("Too many attempts. Try again in %lld seconds", waitSeconds)
            return false
        }
        isRekeying = true
        isWorking = true
        defer {
            isRekeying = false
            isWorking = false
        }
        syncDebounceTask?.cancel()
        await persistence.drain()
        do {
            let rekeyed = try await files.rekey(currentPassword: currentPassword, newPassword: newPassword)
            clearFailedUnlocks()
            finishUnlock(rekeyed.contents, key: rekeyed.key)
            await persistKeyForTouchID()
            return true
        } catch {
            if case VaultPersistenceError.invalidPassword = error {
                registerFailedUnlock()
            }
            vaultError = error.localizedDescription
            return false
        }
    }

    /// Whether the backup was updated with the new password after a password change: `finishUnlock` has queued a sync, and this waits
    /// for it. True when backups are off; false on failure, conflict or an unreadable backup, in which case the UI warns that the
    /// backup still holds the vault encrypted with the old password.
    func backupUpdatedAfterPasswordChange() async -> Bool {
        guard syncLocation != nil else { return true }
        await persistence.drain()
        if case .enabled = backupStatus { return true }
        return false
    }

    /// Saves the material only when Touch ID is available, the switch is on and the vault is unlocked; saving runs in the background
    /// (Secure Enclave wrapping).
    func persistKeyForTouchID() async {
        guard touchIDEnabled, biometricsAvailable, let vaultKey else { return }
        let keyStore = keyStore
        let keyData = vaultKey.withUnsafeBytes { Data($0) }
        do {
            try await Task.detached { try keyStore.save(keyData) }.value
            biometricKeyAvailable = true
        } catch {
            biometricKeyAvailable = false
            vaultError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

// MARK: - Touch ID availability re-check

extension VaultStore {
    /// Re-checks Touch ID availability whenever the app becomes active, covering "enroll a fingerprint in System Settings / pair a
    /// keyboard with Touch ID, then switch back to Kakey". The system posts no availability change notification and nothing polls, so
    /// a keyboard connected while Kakey stays frontmost is picked up only after switching away and back.
    func observeAppActivationForBiometrics() {
        appActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshBiometricsAvailability() }
        }
    }

    /// Probes once on a background thread (`canEvaluatePolicy` is a synchronous XPC call) and updates the UI gating when the result
    /// changes. Triggers while a probe is still running are ignored.
    func refreshBiometricsAvailability() {
        guard biometricsRefreshTask == nil else { return }
        let detect = detectBiometrics
        biometricsRefreshTask = Task { [weak self] in
            let available = await Task.detached(priority: .utility) { detect() }.value
            guard let self else { return }
            biometricsRefreshTask = nil
            await applyBiometricsAvailability(available)
        }
    }

    /// Changes only the gating, never the user's Touch ID preference, and does not delete saved material, so a transient
    /// unavailability (lid closed with an external keyboard, and so on) works normally again once it recovers.
    /// When it becomes available while unlocked, the material is saved so the next lock can use Touch ID without first unlocking
    /// with the master password.
    func applyBiometricsAvailability(_ available: Bool) async {
        guard available != biometricsAvailable else { return }
        biometricsAvailable = available
        if available, !isLocked, vaultKey != nil, touchIDEnabled, !keyStore.hasKey() {
            await persistKeyForTouchID()
        } else {
            biometricKeyAvailable = available && touchIDEnabled && keyStore.hasKey()
        }
    }
}
