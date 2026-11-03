package com.gicek.kakey.android.domain

import com.gicek.kakey.android.R
import com.gicek.kakey.android.core.UiText
import com.gicek.kakey.android.core.VaultContents
import com.gicek.kakey.android.core.toAccount
import com.gicek.kakey.android.core.toContents
import com.gicek.kakey.android.core.toCore
import com.gicek.kakey.core.KakeyException
import com.gicek.kakey.core.coreEncodeRemoteVersion
import com.gicek.kakey.core.coreVaultDiff
import com.gicek.kakey.core.coreVaultMerge
import com.gicek.kakey.core.coreVaultOpen
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.withContext

/**
 * Comparing and merging on conflict (docs/TECHNICAL.md). "Keep This Device's Copy" and "Use the Backup's Copy" reuse
 * [SyncCoordinator]'s upload and download; this opens the backup for comparison, and for a merge saves locally first, then
 * writes the backup conditionally.
 */
internal class ConflictCoordinator(private val session: VaultSession, private val sync: SyncCoordinator) {
    private val state get() = session.state
    private val current get() = session.current

    /** Opens the backup and compares it with the local vault so the conflict page can show differences (docs/TECHNICAL.md). */
    suspend fun conflictReview(): ConflictReviewResult {
        val backend = session.configuredSyncBackend() ?: return ConflictReviewResult.Failed(UiText.Res(R.string.sync_failed))
        val key = session.key?.copyOf() ?: return ConflictReviewResult.Failed(UiText.Res(R.string.unlock_kakey_first))
        return try {
            // Reuse the backup already read when the conflict was detected; the merge upload writes conditionally on its version and is
            // rejected if it changed meanwhile
            val known = sync.conflictRemote.takeIf { current.syncStatus == SyncStatus.Conflict }
            val remote = known ?: withContext(session.io) { backend.read() } ?: return ConflictReviewResult.Failed(
                current.preferences.syncLocation?.let { withContext(session.io) { sync.missingBackupText(it) } }
                    ?: UiText.Res(R.string.no_kakey_backup_was_found_in),
            )
            val remoteContents = try {
                coreVaultOpen(remote.data, key)
            } catch (_: KakeyException) {
                state.update { it.copy(syncStatus = SyncStatus.Unreadable) }
                return ConflictReviewResult.Failed(UiText.Res(R.string.the_backup_here_cant_be_opened))
            }
            val localData = withContext(session.files) { session.repository.encryptedData() }
            val local = VaultContents(current.accounts, current.categories).toCore()
            val diff = coreVaultDiff(local, remoteContents, session.placeholders())
            ConflictReviewResult.Ready(
                ConflictReview(
                    localCount = local.accounts.size,
                    remoteCount = remoteContents.accounts.size,
                    localUpdatedAt = session.repository.envelope(localData).updatedAt,
                    remoteUpdatedAt = session.repository.envelope(remote.data).updatedAt,
                    remoteDevice = remote.deviceName,
                    onlyLocal = diff.onlyLocal.map { it.toAccount() },
                    onlyRemote = diff.onlyRemote.map { it.toAccount() },
                    changed = diff.changed.map { ConflictReview.ChangedAccount(it.local.toAccount(), it.remote.toAccount(), it.changes) },
                    categoriesOnlyLocal = diff.categoriesOnlyLocal,
                    categoriesOnlyRemote = diff.categoriesOnlyRemote,
                    categoriesRenamed = diff.categoriesRenamed.map { it.local to it.remote },
                    remoteContents = remoteContents,
                    remoteVersion = remote.version,
                ),
            )
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            ConflictReviewResult.Failed(syncErrorText(error))
        } finally {
            key.fill(0)
        }
    }

    /**
     * "Merge Both" on conflict: keeps accounts from both sides; for accounts changed on both sides, takes the backup version for
     * those in [preferRemote] (local account IDs). Saves locally first, then writes the backup conditionally.
     * If the backup changed again after the comparison it is not overwritten; a fresh sync runs instead (usually re-entering the
     * conflict so the user compares again).
     */
    suspend fun mergeWithBackup(review: ConflictReview, preferRemote: Set<String>) {
        val backend = session.configuredSyncBackend() ?: return
        val key = session.key?.copyOf() ?: return
        state.update { it.copy(syncStatus = SyncStatus.Running) }
        try {
            withContext(NonCancellable) {
                val (data, updatedAt) = withContext(session.files) {
                    val local = VaultContents(current.accounts, current.categories).toCore()
                    val merged = coreVaultMerge(local, review.remoteContents, preferRemote.toList(), session.placeholders()).toContents()
                    session.repository.save(merged, key)
                    synchronized(session.monitor) {
                        if (current.phase == Phase.UNLOCKED) session.setContents(merged.accounts, merged.categories)
                        session.generation.incrementAndGet()
                    }
                    val written = session.repository.encryptedData()
                    written to session.repository.envelope(written).updatedAt
                }
                val expecting = review.remoteVersion?.let { RemoteExpectation.Unchanged(it) } ?: RemoteExpectation.Any
                val version = withContext(session.io) { backend.write(data, updatedAt, session.deviceName(), expecting) }
                session.updatePreferences {
                    it.copy(lastSyncLocalUpdatedAt = updatedAt, lastSyncRemoteVersion = version?.let(::coreEncodeRemoteVersion))
                }
                state.update { it.copy(syncStatus = SyncStatus.Idle) }
                session.recordSync(BackupHistoryItem.Source.MERGE, data.size.toLong(), direction = BackupHistoryItem.Direction.UPLOAD)
            }
        } catch (_: RemoteChanged) {
            state.update { it.copy(syncStatus = SyncStatus.Idle) }
            sync.sync(BackupHistoryItem.Source.SYNC)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            state.update { it.copy(syncStatus = SyncStatus.Failed(syncErrorText(error))) }
            session.recordSync(BackupHistoryItem.Source.MERGE, 0, isFailure = true)
        } finally {
            key.fill(0)
        }
    }
}
