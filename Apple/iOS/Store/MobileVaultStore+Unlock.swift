import CryptoKit
import Foundation

/// Creation and unlock, biometrics, delays after repeated failures, auto-lock, and locking.
extension MobileVaultStore {
    // MARK: - Creation and unlock

    var lockoutState: UnlockLockoutState {
        get { UnlockLockoutState(consecutiveFailures: preferences.consecutiveUnlockFailures, lockoutUntil: preferences.lockoutUntil) }
        set {
            preferences.consecutiveUnlockFailures = newValue.consecutiveFailures
            preferences.lockoutUntil = newValue.lockoutUntil
        }
    }

    var lockoutRemaining: TimeInterval? {
        UnlockLockout.remainingSeconds(lockoutState, now: now()).map(TimeInterval.init)
    }

    func createVault(password: String, enableBiometrics: Bool) async -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        defer { isWorking = false }
        do {
            let key = try await files.create(password: password)
            finishUnlock(VaultContents(accounts: [], categories: []), key: key)
            if enableBiometrics { await setBiometricsEnabled(true) }
            return true
        } catch {
            unlockError = L10n.tr("Unable to create encrypted vault")
            return false
        }
    }

    /// Unlocks with the master password; rejects a second submission while one is in progress. Empty passwords are judged by the
    /// core (`err.vault.empty_password`).
    func unlock(password: String) async {
        guard !isWorking, lockoutRemaining == nil else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let unlocked = try await files.unlock(password: password)
            lockoutState = .cleared
            finishUnlock(unlocked.contents, key: unlocked.key)
            // Refresh the biometric key after a master password unlock (it changes when another device changes the password)
            if preferences.biometricsEnabled { await storeBiometricKey() }
            scheduleSync()
        } catch {
            await handleUnlockFailure(error)
        }
    }

    /// Restores from the last-known-good snapshot and unlocks when the main file is corrupt.
    func restoreLastKnownGoodVault(password: String) async {
        guard !isWorking, lockoutRemaining == nil else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let restored = try await files.restoreLastKnownGood(password: password)
            lockoutState = .cleared
            finishUnlock(restored.contents, key: restored.key)
            if preferences.biometricsEnabled { await storeBiometricKey() }
            scheduleSync()
        } catch {
            await handleUnlockFailure(error)
        }
    }

    private func handleUnlockFailure(_ error: Error) async {
        // Only wrong passwords count as consecutive failures; failures unrelated to the password (corrupt file, unsupported
        // version) must never make the user wait (same as the Mac).
        if case VaultPersistenceError.invalidPassword = error {
            lockoutState = UnlockLockout.registeringFailure(lockoutState, now: now())
        }
        if case VaultPersistenceError.corruptVault = error {
            lastKnownGoodRestoreAvailable = await files.lastKnownGoodExists
        }
        unlockError = (error as? LocalizedError)?.errorDescription ?? L10n.tr("Unable to unlock")
        Haptics.warning()
    }

    /// Whether the lock screen prompts for biometrics automatically on appear.
    var shouldAutoPromptBiometrics: Bool {
        preferences.biometricsEnabled && biometricKeyAvailable && !autoBiometricPromptSuppressed
    }

    /// Automatic prompt on the lock screen: only once, on the lock screen after launch. After any lock it does not prompt and stays
    /// on the unlock screen.
    func autoPromptBiometricsIfNeeded() async {
        guard shouldAutoPromptBiometrics else { return }
        autoBiometricPromptSuppressed = true
        await unlockWithBiometrics()
    }

    /// Biometric unlock. If the user picks "Use Password" or cancels in the system prompt, returns silently and stays on password
    /// entry.
    func unlockWithBiometrics() async {
        guard preferences.biometricsEnabled, phase == .locked, !isWorking else { return }
        do {
            let keyData = try await keyStore.load(reason: L10n.tr("Unlock Kakey"))
            let key = SymmetricKey(data: keyData)
            isWorking = true
            defer { isWorking = false }
            let opened = try await files.open(key: key)
            finishUnlock(opened, key: key)
            scheduleSync()
        } catch let error as VaultKeyStoreError {
            keyStore.remove()
            biometricKeyAvailable = false
            unlockError = error.errorDescription
        } catch let error as VaultPersistenceError {
            // The key does not match the current vault (for example, a version encrypted with another password was restored from
            // the sync folder)
            keyStore.remove()
            biometricKeyAvailable = false
            unlockError = error.errorDescription
        } catch {
            if BiometricAuth.isCancellation(error) || BiometricAuth.isUserFallback(error) {
                autoBiometricPromptSuppressed = true
            } else {
                unlockError = BiometricService.message(for: error)
            }
        }
    }

    func finishUnlock(_ contents: VaultContents, key: SymmetricKey) {
        document = VaultDocument(contents)
        self.key = key
        unlockError = nil
        lastKnownGoodRestoreAvailable = false
        phase = .unlocked
        lastActivityAt = now()
        scheduleAutoLock()
    }

    /// Hard Lock: clears accounts, categories, and the key. The next lock screen does not prompt for biometrics and stays on the
    /// unlock screen (manual and automatic locks alike).
    func lock() {
        guard phase == .unlocked else { return }
        cancelScheduledAutoLock()
        lastActivityAt = nil
        syncDebounceTask?.cancel()
        document = VaultDocument()
        key = nil
        searchText = ""
        toast = nil
        autoBiometricPromptSuppressed = true
        phase = .locked
    }

    func clearUnlockError() {
        unlockError = nil
    }

    // MARK: - Auto-lock

    /// The lock time is the last activity plus the selected duration. Unlocking, changing settings, and returning to the foreground
    /// all call this: if the time has passed, lock now (in the background there is no activity, the process is suspended, and the
    /// timer never runs); otherwise sleep until then and check again, sleeping on if there was activity in the meantime.
    func scheduleAutoLock() {
        cancelScheduledAutoLock()
        guard let remaining = autoLockRemaining() else { return }
        guard remaining > 0 else {
            lock()
            return
        }
        autoLockTask = Task { @MainActor [weak self] in
            var wait = remaining
            while wait > 0 {
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled, let next = self?.autoLockRemaining() else { return }
                wait = next
            }
            self?.lock()
        }
    }

    /// Seconds left until auto-lock; nil when not unlocked.
    private func autoLockRemaining() -> TimeInterval? {
        guard phase == .unlocked, let lastActivityAt else { return nil }
        return lastActivityAt.addingTimeInterval(preferences.autoLock.delaySeconds).timeIntervalSince(now())
    }

    /// The user touched or pressed a key in the app: auto-lock restarts from now. Only the time is recorded; the timer re-checks
    /// against the latest time when it wakes.
    func noteUserActivity() {
        guard phase == .unlocked, lastActivityAt != nil else { return }
        lastActivityAt = now()
    }

    func cancelScheduledAutoLock() {
        autoLockTask?.cancel()
        autoLockTask = nil
    }

    func willEnterForeground() {
        scheduleAutoLock()
    }

    // MARK: - Biometric settings

    func setBiometricsEnabled(_ enabled: Bool) async {
        preferences.biometricsEnabled = enabled
        if enabled {
            await storeBiometricKey()
        } else {
            keyStore.remove()
            biometricKeyAvailable = false
        }
    }

    /// Saves only when the device supports it, the switch is on, and the vault is unlocked; the Keychain write runs in the
    /// background.
    func storeBiometricKey() async {
        guard biometrics.isAvailable, let key else { return }
        let keyStore = keyStore
        let keyData = key.withUnsafeBytes { Data($0) }
        do {
            try await Task.detached { try keyStore.save(keyData) }.value
            biometricKeyAvailable = true
        } catch {
            biometricKeyAvailable = false
            showToast((error as? LocalizedError)?.errorDescription ?? error.localizedDescription, systemImage: "exclamationmark.triangle")
        }
    }
}
