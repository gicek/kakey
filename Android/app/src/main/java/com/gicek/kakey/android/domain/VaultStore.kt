package com.gicek.kakey.android.domain

import com.gicek.kakey.android.R
import com.gicek.kakey.android.core.Account
import com.gicek.kakey.android.core.AccountCategory
import com.gicek.kakey.android.core.ParsedOtpAuth
import com.gicek.kakey.android.core.UiText
import com.gicek.kakey.android.core.VaultException
import com.gicek.kakey.android.core.VaultSection
import com.gicek.kakey.core.CoreAccountCandidate
import com.gicek.kakey.core.CorePlaceholders
import com.gicek.kakey.core.CoreTotpAlgorithm
import java.time.Duration
import java.time.Instant
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update

/**
 * The single source of truth on Android: the locked session, account edits, auto-lock, sync, and import / export (the
 * counterpart of iOS's `MobileVaultStore`).
 *
 * Business rules (normalization, deduplication, encryption, sync decisions) all live in the Rust core; this only orchestrates
 * state and platform capabilities. Files, key storage, settings, backup locations and clocks are all injected, so JVM unit
 * tests never touch the real system.
 *
 * Work is split across collaborators by responsibility and this class keeps only the public API and wiring: shared state is
 * in [VaultSession] (state flow, messages, key, file generation, startup loading), unlock / lock / password change in
 * [UnlockController], accounts and categories in [AccountEditor], sync and restore in [SyncCoordinator], settings and the
 * biometric key in [PreferencesController], and import / export and reset in [BackupController]. Collaborators are all
 * `internal`; the UI goes through this class only.
 *
 * Threading model:
 * - Public methods are called on the main thread; account and category edits update in-memory state first, then queue a
 *   snapshot on [files] to be written serially in the background.
 * - Every vault file read and write runs on [files] in call order, so queued saves never interleave with password changes or
 *   downloads.
 * - Operations that replace the file wholesale (create, password change, download, restore), together with swapping the key,
 *   run in `NonCancellable`: they complete even if the calling coroutine is canceled (dialog dismissed, UI recreated);
 *   otherwise the file and in-memory key would disagree and the next save would write a vault nobody can decrypt.
 * - Replacing the file wholesale increments the file generation; save snapshots queued earlier see the change and give up,
 *   and the next save of in-memory state catches up.
 */
// Public facade: the UI goes only through this class, so the function count equals the use-case count; dependencies are
// hand-written constructor injection of interfaces, and a parameter object would just add another wrapper
@Suppress("TooManyFunctions", "LongParameterList")
class VaultStore(
    repository: VaultRepository,
    keyStore: VaultKeyStore,
    preferencesStore: PreferencesStore,
    historyStore: BackupHistoryStore,
    syncBackends: SyncBackends,
    scope: CoroutineScope,
    /** Parallel background work: Argon2id for import / export, Keystore, backup folder IO. */
    io: CoroutineDispatcher,
    /** All vault file reads and writes: single concurrency, in call order (`Dispatchers.IO.limitedParallelism(1)` in the app). */
    files: CoroutineDispatcher,
    placeholders: () -> CorePlaceholders,
    deviceName: () -> String,
    now: () -> Instant = Instant::now,
    /** Monotonic clock (milliseconds) for auto-lock; unaffected by changes to system time or time zone (`SystemClock.elapsedRealtime`). */
    elapsedMillis: () -> Long,
    /** Biometric name used in messages (fingerprint / face / biometrics), injected by the app per device. */
    biometricName: UiText = UiText.Res(R.string.biometrics),
) {
    private val session = VaultSession(
        repository, keyStore, preferencesStore, historyStore, syncBackends, scope, io, files, placeholders, deviceName, now, elapsedMillis,
        biometricName,
    )
    private val preferences = PreferencesController(session)
    private val sync = SyncCoordinator(session)
    private val conflicts = ConflictCoordinator(session, sync)
    private val unlocking = UnlockController(session, preferences, sync)
    private val editor = AccountEditor(session, sync)
    private val backups = BackupController(session, editor, unlocking, sync)

    val state: StateFlow<VaultState> = session.state.asStateFlow()

    /** One-shot messages (Snackbar). */
    val messages: SharedFlow<UiText> = session.messages

    /** How long until the master password can be tried again (shared by unlock and password change); null outside a wait. */
    fun lockoutRemaining(): Duration? = session.lockoutRemaining()

    // region List

    fun setSection(section: VaultSection) = session.state.update { it.copy(section = section) }

    fun setSearchText(text: String) = session.state.update { it.copy(searchText = text) }

    // endregion

    // region Create and unlock

    suspend fun createVault(password: String, enableBiometrics: Boolean): Boolean = unlocking.createVault(password, enableBiometrics)

    suspend fun unlock(password: String) = unlocking.unlock(password)

    /** Biometric unlock. Returns silently if the user cancels or chooses the master password, leaving password entry in place. */
    suspend fun unlockWithBiometrics(authenticate: suspend (javax.crypto.Cipher) -> javax.crypto.Cipher) =
        unlocking.unlockWithBiometrics(authenticate)

    fun lock() = unlocking.lock()

    fun clearUnlockError() = session.state.update { it.copy(unlockError = null) }

    // endregion

    // region Auto-lock

    /** Re-checks on returning to the foreground: the process may have been frozen in the background, so an overdue lock happens here. */
    fun onForeground() = unlocking.onForeground()

    /** The user touched the app or pressed a key ([MainActivity.onUserInteraction]): restarts the auto-lock countdown from now. */
    fun noteUserActivity() = unlocking.noteUserActivity()

    // endregion

    // region Settings

    fun setAppearance(mode: AppearanceMode) = preferences.setAppearance(mode)

    fun setAutoLock(mode: AutoLockMode) {
        preferences.setAutoLock(mode)
        unlocking.scheduleAutoLock()
    }

    suspend fun setBiometricsEnabled(enabled: Boolean) = preferences.setBiometricsEnabled(enabled)

    // endregion

    // region Accounts

    /** The single insert path (core `dedup.rs`): skips invalid and duplicate entries, puts new accounts first. Returns the number added. */
    fun insert(candidates: List<CoreAccountCandidate>, addedBy: String, categoryId: String? = null): Int =
        editor.insert(candidates, addedBy, categoryId)

    /** Manual add; returns null on success, otherwise the error to show. Adding inside a category also adds the account to it. */
    @Suppress("LongParameterList") // The six parameters are the six otpauth fields
    fun addManual(issuer: String, username: String, secret: String, algorithm: CoreTotpAlgorithm, digits: Int, period: Int): UiText? =
        editor.addManual(issuer, username, secret, algorithm, digits, period)

    /**
     * Results from a scan, photo or paste (all started on the main screen; inside a category they also join it).
     * If every result is a duplicate, shows "account already exists".
     */
    fun addParsed(parsed: List<ParsedOtpAuth>): Int = editor.addParsed(parsed)

    /**
     * Imports a backup file (a Kakey encrypted export or an Authenticator backup). Categories in the file are merged by name; if
     * every account is a duplicate, shows "all accounts in the file already exist" (see docs/DESIGN.md). Throws [VaultException]
     * (`PasswordRequired` / `EmptyPassword`) when a password is needed; the UI asks for it and retries.
     */
    suspend fun importBackup(data: ByteArray, password: String): Int = backups.importBackup(data, password)

    /**
     * First-run restore from a Kakey export file: opens it with the export password, then creates a vault with [masterPassword]
     * (the export password when "use as master password" is checked). Returns null on success, otherwise the error to show;
     * throws [VaultException] for a wrong password and similar.
     */
    suspend fun restoreFromExport(data: ByteArray, password: String, masterPassword: String, enableBiometrics: Boolean): UiText? =
        backups.restoreFromExport(data, password, masterPassword, enableBiometrics)

    fun update(account: Account) = editor.update(account)

    fun delete(account: Account) = editor.delete(account)

    /**
     * Drag-to-reorder preview: moves the account at [from] in the current section to [to], in memory only and affecting only
     * the current section (all accounts or one category). Called once per item passed while dragging; [commitOrder] saves once
     * on release.
     */
    fun move(from: Int, to: Int) = editor.move(from, to)

    /** End of a drag: writes the order previewed by [move] / [moveCategory] to disk. */
    fun commitOrder() = editor.commitOrder()

    // endregion

    // region Categories

    /** Creates a category; throws [VaultException] for an invalid name. */
    fun createCategory(name: String): AccountCategory = editor.createCategory(name)

    fun renameCategory(id: String, name: String) = editor.renameCategory(id, name)

    /** Deletes only the category itself; its accounts stay in "All". */
    fun deleteCategory(id: String) = editor.deleteCategory(id)

    /** Category drag-to-reorder preview (in memory only); [commitOrder] on release. */
    fun moveCategory(from: Int, to: Int) = editor.moveCategory(from, to)

    /** Toggles a checkmark in "Add to": removes the account if it is already in the category, otherwise appends it. */
    fun toggleAccount(accountId: String, categoryId: String) = editor.toggleAccount(accountId, categoryId)

    /** Saves the "Add to" sheet: sets the account's category membership to [categoryIds] in one go, writing to disk once. */
    fun setAccountCategories(accountId: String, categoryIds: Set<String>) = editor.setAccountCategories(accountId, categoryIds)

    // endregion

    // region Master password and data

    /**
     * Password change: decrypts with the current password first to verify it. A wrong current password counts toward the
     * consecutive-failure lockout just like unlocking, and is rejected outright during the wait (see docs/SECURITY.md).
     * Returns null on success.
     */
    suspend fun changePassword(currentPassword: String, newPassword: String): UiText? =
        unlocking.changePassword(currentPassword, newPassword)

    /**
     * Syncs right after a master password change and returns whether the backup now uses the new password. True when backup
     * is off; false on failure, conflict or an unopenable backup, in which case the UI warns that the backup is still encrypted
     * with the old password. Waits for any running sync to finish first, otherwise this one would be skipped.
     */
    suspend fun backupUpdatedAfterPasswordChange(): Boolean {
        if (state.value.preferences.syncLocation == null) return true
        state.first { it.syncStatus != SyncStatus.Running }
        sync.sync(BackupHistoryItem.Source.AUTO)
        return state.value.syncStatus == SyncStatus.Idle
    }

    /** Encrypted export (separate password, salt and nonce). */
    suspend fun exportBackup(password: String): ByteArray = backups.exportBackup(password)

    /** Clears the local vault, biometric key, cloud storage credentials, settings and backup history; remote backups are untouched. */
    suspend fun resetApplication() = backups.resetApplication()

    // endregion

    // region Sync

    /**
     * Enables a sync folder and syncs once right away; returns error text when the link check fails (e.g. the local key can't
     * open the remote backup), null on success.
     */
    suspend fun configureSync(folderUri: String): UiText? = sync.configure(SyncLocation.Folder(folderUri))

    /**
     * Enables a cloud storage location (connection blob from [SyncBackends.cloudSetup]); returns error text when the link
     * check fails, null on success.
     */
    suspend fun configureCloudSync(location: SyncLocation.Cloud, connection: ByteArray): UiText? = sync.configure(location, connection)

    /** One-off operations while connecting cloud storage (form, browser sign-in, folder picking). */
    val cloudSetup: CloudSetup get() = session.syncBackends.cloudSetup

    fun stopSync() = sync.stopSync()

    /**
     * Uploads, downloads or reports a conflict per the decision in core `sync.rs`; the user picks a direction for conflicts in
     * settings.
     */
    suspend fun sync(source: BackupHistoryItem.Source = BackupHistoryItem.Source.MANUAL) = sync.sync(source)

    /** On conflict, overwrites the backup with the local vault. */
    suspend fun resolveConflictKeepingLocal() = sync.resolveConflictKeepingLocal()

    /** On conflict, overwrites the local vault with the backup's version. */
    suspend fun resolveConflictUsingRemote() = sync.resolveConflictUsingRemote()

    /**
     * "Restore from Backup" when the backup can't be opened: only after opening that backup with its master password does it
     * replace the local vault and stay unlocked, with a new biometric key. Returns null on success, otherwise the error to show
     * (the local vault is untouched).
     */
    suspend fun restoreUnreadableBackup(password: String): UiText? {
        val error = sync.restoreUnreadableBackup(password)
        if (error == null && state.value.preferences.biometricsEnabled) preferences.storeBiometricKey()
        return error
    }

    /** Conflict page: opens the backup and compares it with the local vault. */
    suspend fun conflictReview(): ConflictReviewResult = conflicts.conflictReview()

    /** Merges both sides on conflict: [preferRemote] lists account IDs changed on both sides for which the backup's version wins. */
    suspend fun mergeWithBackup(review: ConflictReview, preferRemote: Set<String>) = conflicts.mergeWithBackup(review, preferRemote)

    /**
     * First run: fetches the encrypted vault from a sync folder and keeps it only in memory; [completeRestore] then opens it with
     * the original master password. Returns null when a backup was found.
     */
    suspend fun restore(folderUri: String): UiText? = sync.restore(SyncLocation.Folder(folderUri))

    suspend fun restoreFromCloud(location: SyncLocation.Cloud, connection: ByteArray): UiText? = sync.restore(location, connection)

    /** Location of the found backup awaiting its original master password; null when there is none. */
    val pendingRestoreLocation: SyncLocation? get() = sync.pendingRestore?.location

    /**
     * The connection blob, refreshed if the access token was refreshed while fetching: onboarding updates the remembered
     * authorization with it.
     */
    val pendingRestoreConnection: ByteArray? get() = sync.pendingRestore?.connection

    /**
     * Opens the found backup with the original master password; only on success writes it, enables the location and unlocks.
     * Returns null on success, otherwise the error to show.
     */
    suspend fun completeRestore(password: String, enableBiometrics: Boolean): UiText? =
        unlocking.completeRestore(password, enableBiometrics)

    /** Abandons the found backup and returns to the location list to pick another source or start fresh. */
    fun discardRestore() {
        sync.pendingRestore = null
    }

    /**
     * The last first-run restore failed because the location had no backup: onboarding then offers "Choose Folder" next to
     * cloud storage.
     */
    val restoreMissedBackup: Boolean get() = sync.restoreMissedBackup

    // endregion
}
