package com.gicek.kakey.android.domain

import com.gicek.kakey.android.core.Account
import com.gicek.kakey.android.core.AccountCategory
import com.gicek.kakey.android.core.UiText
import com.gicek.kakey.android.core.VaultSection
import com.gicek.kakey.android.core.accountsIn
import java.time.Duration

/** Seconds-to-milliseconds factor (auto-lock and the post-failure wait both run on a millisecond monotonic clock). */
internal const val MILLIS_PER_SECOND = 1_000L

/** `LOADING`: settings and vault existence are still being read at startup; the splash screen stays until it ends. */
enum class Phase { LOADING, ONBOARDING, LOCKED, UNLOCKED }

sealed interface SyncStatus {
    data object NotConfigured : SyncStatus
    data object Idle : SyncStatus
    data object Running : SyncStatus
    data object Conflict : SyncStatus

    /** The local key can't open the remote backup: sync stops, and the only way out is "Restore from Backup". */
    data object Unreadable : SyncStatus
    data class Failed(val message: UiText) : SyncStatus
}

/** All state [VaultStore] exposes. */
data class VaultState(
    val phase: Phase,
    val accounts: List<Account> = emptyList(),
    val categories: List<AccountCategory> = emptyList(),
    val section: VaultSection = VaultSection.All,
    val searchText: String = "",
    val isWorking: Boolean = false,
    val unlockError: UiText? = null,
    val syncStatus: SyncStatus = SyncStatus.NotConfigured,
    /** Display name of the sync folder (queried once when chosen and cached here; null when the grant is lost). */
    val syncFolderName: String? = null,
    val syncHistory: List<BackupHistoryItem> = emptyList(),
    /** After biometrics are invalidated (re-enrollment, ...), one master password unlock is needed before re-enabling. */
    val biometricKeyAvailable: Boolean = false,
    /**
     * True after any lock: the lock screen doesn't auto-prompt for biometrics and just focuses the password field (same as Mac
     * / iOS); cleared on unlock.
     */
    val autoBiometricSuppressed: Boolean = false,
    val preferences: Preferences = Preferences(),
) {
    val sectionAccounts: List<Account>
        get() = when (section) {
            VaultSection.All -> accounts
            is VaultSection.Category -> categories.accountsIn(section.id, accounts)
        }

    val sectionCategory: AccountCategory? get() = section.categoryId?.let { id -> categories.firstOrNull { it.id == id } }

    val visibleAccounts: List<Account>
        get() {
            val query = searchText.trim()
            return if (query.isEmpty()) sectionAccounts else sectionAccounts.filter { it.matchesSearch(query) }
        }

    fun account(id: String?): Account? = accounts.firstOrNull { it.id == id }

    fun isAccount(accountId: String, categoryId: String): Boolean =
        categories.firstOrNull { it.id == categoryId }?.accountIds?.contains(accountId) == true

    /**
     * How long until another attempt is allowed after repeated failures; null outside a wait. Computed on the monotonic clock
     * (`elapsedMillis` injected into [VaultStore]) so changing system time can't skip the wait. A timestamp in the future
     * (the monotonic clock restarts from zero after a reboot) counts as the full delay, and [VaultStore] resets the start to
     * now at launch.
     */
    fun lockoutRemaining(elapsedMillis: Long): Duration? {
        val seconds = preferences.lockoutSeconds ?: return null
        val started = preferences.lockoutStartedElapsedMillis ?: return null
        val total = seconds * MILLIS_PER_SECOND
        val remaining = if (elapsedMillis < started) total else total - (elapsedMillis - started)
        return if (remaining <= 0) null else Duration.ofMillis(remaining)
    }
}
