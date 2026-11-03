package com.gicek.kakey.android.domain

import com.gicek.kakey.android.core.Account
import com.gicek.kakey.core.CoreAccountChange
import com.gicek.kakey.core.CoreRemoteVersion
import com.gicek.kakey.core.CoreVaultContents
import java.time.Instant

/**
 * Conflict comparison (docs/TECHNICAL.md; the counterpart of Apple's `ConflictReview`): opens the backup and compares it with
 * the local vault account by account so the UI can show the differences and the outcome of each choice. Held only in memory;
 * accounts contain secrets, so the UI shows only the service name, account name and "secret differs". The comparison rules
 * live in core `merge.rs`.
 */
data class ConflictReview(
    val localCount: Int,
    val remoteCount: Int,
    val localUpdatedAt: Instant,
    val remoteUpdatedAt: Instant,
    val remoteDevice: String?,
    val onlyLocal: List<Account>,
    val onlyRemote: List<Account>,
    val changed: List<ChangedAccount>,
    val categoriesOnlyLocal: List<String>,
    val categoriesOnlyRemote: List<String>,
    val categoriesRenamed: List<Pair<String, String>>,
    /**
     * The opened backup contents and the remote version seen at comparison time: merges are based on it, and the upload
     * requires the remote to still be this version.
     */
    val remoteContents: CoreVaultContents,
    val remoteVersion: CoreRemoteVersion?,
) {
    data class ChangedAccount(val local: Account, val remote: Account, val changes: List<CoreAccountChange>) {
        /**
         * Each side's name ("service · account") when the service or account name differs, so the UI can label which side is
         * which; null when both match.
         */
        val differingNames: Pair<String, String>? get() {
            if (local.issuer == remote.issuer && local.username == remote.username) return null
            val showUsername = local.username != remote.username
            fun name(account: Account) =
                if (showUsername && account.username.isNotEmpty()) "${account.issuer} · ${account.username}" else account.issuer
            return name(local) to name(remote)
        }
    }

    /** For accounts changed on both sides, the side saved more recently wins by default. */
    val remoteIsNewer: Boolean get() = remoteUpdatedAt.isAfter(localUpdatedAt)

    override fun toString(): String = "ConflictReview(local=$localCount, remote=$remoteCount, changed=${changed.size})"
}

/** The three conflict resolutions ("Decide later" just does nothing). */
enum class ConflictChoice { MERGE, KEEP_LOCAL, USE_BACKUP }

/** Result of opening the conflict page: the comparison, or why it failed (can't decrypt, offline, ...). */
sealed interface ConflictReviewResult {
    data class Ready(val review: ConflictReview) : ConflictReviewResult

    data class Failed(val message: com.gicek.kakey.android.core.UiText) : ConflictReviewResult
}
