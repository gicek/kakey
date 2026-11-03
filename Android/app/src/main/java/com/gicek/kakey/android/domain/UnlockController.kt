package com.gicek.kakey.android.domain

import com.gicek.kakey.android.R
import com.gicek.kakey.android.core.UiText
import com.gicek.kakey.android.core.VaultContents
import com.gicek.kakey.android.core.VaultException
import com.gicek.kakey.core.KakeyException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Entering and leaving the locked session: creating a vault, master password and biometric unlock, locking and auto-lock,
 * and password changes. Counting consecutive failures and the resulting wait live in [VaultSession] (shared by unlock and
 * password change).
 */
internal class UnlockController(
    private val session: VaultSession,
    private val preferences: PreferencesController,
    private val sync: SyncCoordinator,
) {
    private val state get() = session.state
    private val current get() = session.current
    private var autoLockJob: Job? = null

    /**
     * Creates a vault and unlocks it; [contents] are the accounts and categories opened from an export file on restore,
     * otherwise empty.
     */
    suspend fun createVault(password: String, enableBiometrics: Boolean, contents: VaultContents = VaultContents.EMPTY): Boolean {
        session.loaded.join()
        state.update { it.copy(isWorking = true) }
        return try {
            withContext(NonCancellable) {
                val key = withContext(session.files) { session.repository.create(contents, password) }
                session.finishUnlock(contents, key)
                scheduleAutoLock()
                if (enableBiometrics) preferences.setBiometricsEnabled(true)
            }
            true
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            state.update { it.copy(unlockError = UiText.Res(R.string.unable_to_create_encrypted_vault)) }
            false
        } finally {
            state.update { it.copy(isWorking = false) }
        }
    }

    /**
     * First-run restore: opens [SyncCoordinator.pendingRestore] with the original master password, and only on success writes
     * it to disk, enables the location and unlocks (same as Apple). Returns null on success, otherwise the error to show.
     * Wrong attempts don't count toward the consecutive-failure lockout: the user already holds this ciphertext, so a counter
     * can't stop offline guessing (same as Apple).
     */
    suspend fun completeRestore(password: String, enableBiometrics: Boolean): UiText? {
        session.loaded.join()
        val pending = sync.pendingRestore ?: return UiText.Res(R.string.unable_to_restore_from_backup)
        state.update { it.copy(isWorking = true) }
        return try {
            val unlocked = withContext(session.io) { session.repository.unlock(password, pending.remote.data) }
            withContext(NonCancellable) {
                sync.commitRestore(pending)
                session.finishUnlock(unlocked.contents, unlocked.key)
                scheduleAutoLock()
                if (enableBiometrics) preferences.setBiometricsEnabled(true)
            }
            null
        } catch (error: CancellationException) {
            throw error
        } catch (error: VaultException) {
            error.text
        } catch (error: Exception) {
            syncErrorText(error)
        } finally {
            state.update { it.copy(isWorking = false) }
        }
    }

    suspend fun unlock(password: String) {
        session.loaded.join()
        if (session.lockoutRemaining() != null) return
        // Blank passwords are rejected by the core before key derivation (`EmptyPassword`, not counted as a failure); no extra rule here
        state.update { it.copy(isWorking = true) }
        try {
            val unlocked = withContext(session.files) { session.repository.unlock(password) }
            session.clearPasswordFailures()
            session.finishUnlock(unlocked.contents, unlocked.key)
            scheduleAutoLock()
            // Refresh the biometric key after a master password unlock (the key changes when another device changes the password)
            if (current.preferences.biometricsEnabled) preferences.storeBiometricKey()
            sync.scheduleSync()
        } catch (error: CancellationException) {
            throw error
        } catch (error: VaultException) {
            // Only a wrong password counts as a failure; failures unrelated to the password (corrupt file, ...) must not make
            // the user wait (same as Mac / iOS)
            if (error.error is KakeyException.InvalidPassword) session.registerPasswordFailure()
            state.update { it.copy(unlockError = error.text) }
        } catch (error: Exception) {
            state.update { it.copy(unlockError = UiText.Res(R.string.unable_to_unlock)) }
        } finally {
            state.update { it.copy(isWorking = false) }
        }
    }

    /** Biometric unlock. Returns silently if the user cancels or chooses the master password, leaving password entry in place. */
    suspend fun unlockWithBiometrics(authenticate: suspend (javax.crypto.Cipher) -> javax.crypto.Cipher) {
        session.loaded.join()
        if (!current.preferences.biometricsEnabled || current.phase != Phase.LOCKED) return
        try {
            val key = session.keyStore.load(authenticate)
            val contents = withContext(session.files) { session.repository.open(key) }
            session.finishUnlock(contents, key)
            scheduleAutoLock()
            sync.scheduleSync()
        } catch (error: CancellationException) {
            throw error
        } catch (error: BiometricCancelled) {
            return
        } catch (error: BiometricFailed) {
            state.update { it.copy(unlockError = UiText.Raw(error.reason)) }
        } catch (error: VaultException) {
            // The key doesn't match the current vault (e.g. a version encrypted with another password was restored from the
            // backup location)
            withContext(session.io) { session.keyStore.remove() }
            state.update {
                it.copy(
                    biometricKeyAvailable = false,
                    unlockError = UiText.Res(R.string.unlock_once_with_your_master_password, session.biometricName),
                )
            }
        } catch (error: Exception) {
            state.update {
                it.copy(
                    biometricKeyAvailable = false,
                    unlockError = UiText.Res(R.string.unlock_once_with_your_master_password, session.biometricName),
                )
            }
        }
    }

    /**
     * After any lock (manual, auto or screen off) the lock screen doesn't auto-prompt for biometrics and stays on the unlock
     * page; only the lock screen at launch prompts once.
     */
    fun lock() {
        autoLockJob?.cancel()
        autoLockJob = null
        sync.cancelScheduled()
        session.clearSession()
    }

    // region Auto-lock

    /**
     * The lock time is the last interaction time plus the chosen duration. Unlock, settings changes and returning to the
     * foreground all call this: if that time has passed, lock now (there was no interaction in the background, and the process
     * may have been frozen or killed and recreated so no timer ran); otherwise sleep in [VaultSession.scope] until then and
     * check again, sleeping on if there was interaction in between, locking if not.
     */
    fun scheduleAutoLock() {
        autoLockJob?.cancel()
        autoLockJob = null
        val remaining = autoLockRemainingMillis() ?: return
        if (remaining <= 0) {
            lock()
            return
        }
        autoLockJob = session.scope.launch {
            var wait = remaining
            while (wait > 0) {
                delay(wait)
                wait = autoLockRemainingMillis() ?: return@launch
            }
            lock()
        }
    }

    /** Milliseconds left until auto-lock; null when not unlocked. */
    private fun autoLockRemainingMillis(): Long? {
        val lastActivity = session.lastActivityElapsedMillis ?: return null
        if (current.phase != Phase.UNLOCKED) return null
        return lastActivity + current.preferences.autoLock.delaySeconds * MILLIS_PER_SECOND - session.elapsedMillis()
    }

    /** Only records the time without rebuilding the timer; the timer re-checks against the latest time when it wakes. */
    fun noteUserActivity() = session.noteUserActivity()

    fun onForeground() = scheduleAutoLock()

    // endregion

    /**
     * Password change: decrypts with the current password first to verify it. A wrong current password counts toward the
     * consecutive-failure lockout just like unlocking, and is rejected outright during the wait (see docs/SECURITY.md).
     */
    suspend fun changePassword(currentPassword: String, newPassword: String): UiText? {
        session.lockoutRemaining()?.let { remaining ->
            val seconds = ((remaining.toMillis() + MILLIS_PER_SECOND - 1) / MILLIS_PER_SECOND).toInt()
            return UiText.Plural(R.plurals.too_many_attempts_try_again_in, seconds)
        }
        state.update { it.copy(isWorking = true) }
        try {
            try {
                withContext(session.files) { session.repository.verify(currentPassword) }
                session.clearPasswordFailures()
            } catch (error: CancellationException) {
                throw error
            } catch (error: VaultException) {
                if (error.error is KakeyException.InvalidPassword) session.registerPasswordFailure()
                return error.text
            } catch (error: Exception) {
                return UiText.Res(R.string.err_vault_invalid_password)
            }
            val contents = VaultContents(current.accounts, current.categories)
            val biometrics = current.preferences.biometricsEnabled
            return try {
                // Writing the new file, swapping the key and re-storing the biometric key are one unit: cancellation from
                // dismissing the dialog must not cut it short
                val old = withContext(session.files + NonCancellable) {
                    val newKey = session.repository.create(contents, newPassword)
                    val old = synchronized(session.monitor) { session.installKey(newKey) }
                    if (biometrics) preferences.saveBiometricKey(newKey)
                    old
                }
                old?.fill(0)
                // The sync after a password change is run and awaited by the UI via VaultStore.backupUpdatedAfterPasswordChange
                null
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                UiText.Res(R.string.unable_to_change_master_password)
            }
        } finally {
            state.update { it.copy(isWorking = false) }
        }
    }
}
