package com.gicek.kakey.android.domain

import com.gicek.kakey.android.R
import com.gicek.kakey.android.core.Account
import com.gicek.kakey.android.core.AccountCategory
import com.gicek.kakey.android.core.UiText
import com.gicek.kakey.android.core.VaultContents
import com.gicek.kakey.android.core.VaultSection
import com.gicek.kakey.core.CorePlaceholders
import com.gicek.kakey.core.coreUnlockLockoutSeconds
import java.time.Duration
import java.time.Instant
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.flow.updateAndGet
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Session shared by [VaultStore] and its collaborators ([UnlockController], [AccountEditor], [SyncCoordinator],
 * [PreferencesController], [BackupController]): the state flow, one-shot messages, the in-memory vault key, the file
 * generation, startup loading, and injected platform capabilities. Collaborators get only this object, so [VaultStore]'s
 * members don't have to be made public.
 *
 * See the [VaultStore] class comment for the threading model. [key] is replaced and zeroed only under the [monitor] lock;
 * background threads read a copy.
 */
@Suppress("LongParameterList") // The same injected dependencies as VaultStore
internal class VaultSession(
    val repository: VaultRepository,
    val keyStore: VaultKeyStore,
    val preferencesStore: PreferencesStore,
    val historyStore: BackupHistoryStore,
    val syncBackends: SyncBackends,
    val scope: CoroutineScope,
    /** Parallel background work: Argon2id for import / export, Keystore, backup folder IO. */
    val io: CoroutineDispatcher,
    /** All vault file reads and writes: single concurrency, in call order (`Dispatchers.IO.limitedParallelism(1)` in the app). */
    val files: CoroutineDispatcher,
    val placeholders: () -> CorePlaceholders,
    val deviceName: () -> String,
    val now: () -> Instant,
    /** Monotonic clock (milliseconds) for auto-lock; unaffected by changes to system time or time zone (`SystemClock.elapsedRealtime`). */
    val elapsedMillis: () -> Long,
    /** Biometric name used in messages (fingerprint / face / biometrics, provided by the platform per device). */
    val biometricName: UiText = UiText.Res(R.string.biometrics),
) {
    val state = MutableStateFlow(VaultState(phase = Phase.LOADING))

    /** One-shot messages (Snackbar). */
    val messages = MutableSharedFlow<UiText>(extraBufferCapacity = 4, onBufferOverflow = BufferOverflow.DROP_OLDEST)

    /** The current vault key; null while locked. Replaced and zeroed only under the [monitor] lock; background threads read a copy. */
    @Volatile
    var key: ByteArray? = null
        private set

    /** Guards [key] and unlock / lock state transitions. */
    val monitor = Any()

    /** File generation: incremented when the file is replaced wholesale; save snapshots queued earlier see the change and give up. */
    val generation = AtomicLong()

    /** Async load at startup: settings, backup history, whether a vault exists, and whether the biometric key is still there. */
    val loaded: Job = scope.launch {
        val preferences = withContext(io) { preferencesStore.load() }
        val history = withContext(io) { historyStore.load() }
        val exists = withContext(files) { repository.vaultExists }
        val hasKey = preferences.biometricsEnabled && withContext(io) { keyStore.hasKey() }
        val folderName = when (val location = preferences.syncLocation) {
            null -> null
            is SyncLocation.Folder -> withContext(io) { syncBackends.folder(location.uri).displayName() }
            is SyncLocation.Cloud -> location.provider.displayName
        }
        // A wait start in the future means the device rebooted (the monotonic clock restarts from zero): restart the full
        // delay from now so a reboot can't skip the wait
        val restarted = preferences.lockoutStartedElapsedMillis?.let { started -> started > elapsedMillis() } == true
        val normalized = if (restarted) preferences.copy(lockoutStartedElapsedMillis = elapsedMillis()) else preferences
        if (restarted) preferencesStore.save(normalized)
        state.update {
            it.copy(
                phase = if (exists) Phase.LOCKED else Phase.ONBOARDING,
                preferences = normalized,
                syncHistory = history,
                syncStatus = if (preferences.syncLocation == null) SyncStatus.NotConfigured else SyncStatus.Idle,
                syncFolderName = folderName,
                biometricKeyAvailable = hasKey,
            )
        }
    }

    val current: VaultState get() = state.value

    /** Atomic read-modify-write on the state flow (called from the main thread and from downloads on [files]), then persisted. */
    fun updatePreferences(transform: (Preferences) -> Preferences) {
        val updated = state.updateAndGet { it.copy(preferences = transform(it.preferences)) }.preferences
        preferencesStore.save(updated)
    }

    /** How long until the master password can be tried again (shared by unlock and password change); null outside a wait. */
    fun lockoutRemaining(): Duration? = current.lockoutRemaining(elapsedMillis())

    /**
     * A wrong master password (only `InvalidPassword` counts, see docs/SECURITY.md): unlock and password change share one
     * count and wait.
     */
    fun registerPasswordFailure() {
        val failures = current.preferences.consecutiveUnlockFailures + 1
        val delay = coreUnlockLockoutSeconds(failures.toUInt())?.toLong()
        updatePreferences {
            it.copy(
                consecutiveUnlockFailures = failures,
                lockoutSeconds = delay,
                lockoutStartedElapsedMillis = delay?.let { elapsedMillis() },
            )
        }
    }

    fun clearPasswordFailures() =
        updatePreferences { it.copy(consecutiveUnlockFailures = 0, lockoutSeconds = null, lockoutStartedElapsedMillis = null) }

    fun setContents(accounts: List<Account>, categories: List<AccountCategory>) {
        state.update { state ->
            // Fall back to "All" when the current section's category was deleted (including disappearing after a sync download)
            val section =
                state.section.categoryId?.takeIf { id -> categories.none { it.id == id } }?.let { VaultSection.All } ?: state.section
            state.copy(accounts = accounts, categories = categories, section = section)
        }
    }

    fun message(text: UiText) {
        messages.tryEmit(text)
    }

    /**
     * Monotonic clock (milliseconds) at the last interaction: the unlock time at first, refreshed on every touch / key press;
     * auto-lock is computed from it. Null while locked.
     */
    @Volatile
    var lastActivityElapsedMillis: Long? = null
        private set

    /** The user interacted with the app: when unlocked, records now as the last interaction time; nothing while locked. */
    fun noteUserActivity() {
        synchronized(monitor) {
            if (lastActivityElapsedMillis != null && current.phase == Phase.UNLOCKED) {
                lastActivityElapsedMillis = elapsedMillis()
            }
        }
    }

    fun finishUnlock(contents: VaultContents, key: ByteArray) {
        synchronized(monitor) {
            installKey(key)?.fill(0)
            setContents(contents.accounts, contents.categories)
            lastActivityElapsedMillis = elapsedMillis()
            state.update { it.copy(unlockError = null, phase = Phase.UNLOCKED, autoBiometricSuppressed = false) }
        }
    }

    /**
     * Installs a new vault key and increments the file generation; call only under the [monitor] lock. Returns the old key for
     * the caller to zero.
     */
    fun installKey(newKey: ByteArray?): ByteArray? {
        val old = key
        key = newKey
        generation.incrementAndGet()
        return old
    }

    /**
     * Hard Lock: zeroes the key and clears in-memory accounts. Locking doesn't touch the file; queued saves still complete
     * with their own key copies.
     */
    fun clearSession() {
        synchronized(monitor) {
            if (current.phase != Phase.UNLOCKED) return
            key?.fill(0)
            key = null
            lastActivityElapsedMillis = null
            state.update {
                it.copy(
                    phase = Phase.LOCKED,
                    accounts = emptyList(),
                    categories = emptyList(),
                    searchText = "",
                    section = VaultSection.All,
                    autoBiometricSuppressed = true,
                )
            }
        }
    }
}
