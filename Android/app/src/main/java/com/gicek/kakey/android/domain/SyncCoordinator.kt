package com.gicek.kakey.android.domain

import com.gicek.kakey.android.R
import com.gicek.kakey.android.core.UiText
import com.gicek.kakey.android.core.VaultException
import com.gicek.kakey.android.core.text
import com.gicek.kakey.core.CoreCloudException
import com.gicek.kakey.core.CoreLocalSnapshot
import com.gicek.kakey.core.CoreRemoteSnapshot
import com.gicek.kakey.core.CoreRemoteVersion
import com.gicek.kakey.core.CoreSyncDecision
import com.gicek.kakey.core.CoreSyncMarks
import com.gicek.kakey.core.coreDecideSync
import com.gicek.kakey.core.coreDecodeRemoteVersion
import com.gicek.kakey.core.coreEncodeRemoteVersion
import com.gicek.kakey.core.coreVaultOpensWithKey
import java.time.Instant
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** A completed remote read ([remote] is null when there is no remote backup), handed to the next step so it isn't downloaded again. */
internal class RemoteRead(val remote: SyncBackend.Remote?)

/**
 * Sync backend configuration, queued auto-sync, upload / download / conflict decisions, first-run restore and backup history.
 * The decisions themselves are in core `sync.rs`.
 */
@Suppress("TooManyFunctions") // One function per sync use case (first-run restore has two steps); splitting further leaves only forwarders
internal class SyncCoordinator(private val session: VaultSession) {
    private companion object {
        /** Delay after a save before auto-sync, so a burst of edits uploads only once. */
        const val AUTO_SYNC_DELAY_MILLIS = 2_000L
    }

    private val state get() = session.state
    private val current get() = session.current
    private var pendingSync: Job? = null

    /**
     * The backup read when the latest conflict was detected: while the state is still conflict, the conflict page compares
     * against it without downloading again (the merge upload writes conditionally on its version).
     */
    var conflictRemote: SyncBackend.Remote? = null
        private set

    /**
     * Enables or changes the backup location. A link check runs first (read-only, using only the local key): if the remote
     * already has a backup that differs from the local vault and the local key can't open it, nothing is enabled and the error
     * text is returned. Once it passes, cloud storage saves the connection blob first; leaving the old location releases the
     * folder grant or revokes cloud storage authorization and deletes its credentials; then one sync runs right away (uploads
     * if the remote has no backup; if it opens but differs, the core reports a conflict and the user picks a direction).
     * Returns null on success.
     */
    suspend fun configure(location: SyncLocation, connection: ByteArray? = null): UiText? {
        val checked = try {
            checkLink(location, connection)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            return syncErrorText(error)
        }
        cancelScheduled()
        try {
            withContext(session.io) { switchConnection(location, connection) }
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            state.update { it.copy(syncStatus = SyncStatus.Failed(syncErrorText(error))) }
            return syncErrorText(error)
        }
        val name = withContext(session.io) { displayName(location) }
        session.updatePreferences { it.copy(syncLocation = location, lastSyncLocalUpdatedAt = null, lastSyncRemoteVersion = null) }
        state.update { it.copy(syncStatus = SyncStatus.Idle, syncFolderName = name) }
        // The link check just read the remote: the first sync reuses it instead of downloading again
        sync(BackupHistoryItem.Source.SYNC, prefetched = checked)
        return null
    }

    /**
     * Cloud storage saves the new connection blob first; leaving the old location releases the folder grant, or revokes cloud
     * storage authorization and deletes credentials (keeping the just-saved connection when the new location is also cloud
     * storage).
     */
    private fun switchConnection(location: SyncLocation, connection: ByteArray?) {
        if (location is SyncLocation.Cloud) {
            session.syncBackends.connections.save(connection ?: throw CloudSyncException(CoreCloudException.ReauthRequired()))
        }
        current.preferences.syncLocation?.takeIf { it != location }?.let {
            releaseLocation(it, keepConnection = location is SyncLocation.Cloud)
        }
    }

    /**
     * Link check: throws [RemoteUnreadable] if the remote has a backup that differs from the local vault and the local key
     * can't open it. Read-only, changes no state. Returns what it read.
     */
    private suspend fun checkLink(location: SyncLocation, connection: ByteArray?): RemoteRead {
        val candidate = when (location) {
            is SyncLocation.Folder -> session.syncBackends.folder(location.uri)
            is SyncLocation.Cloud -> session.syncBackends.cloud(location.folder, InMemoryCloudConnectionStore(connection))
        }
        val remote = withContext(session.io) { candidate.read() } ?: return RemoteRead(null)
        val local = withContext(session.files) { if (session.repository.vaultExists) session.repository.encryptedData() else null }
        if (!remote.data.contentEquals(local) && !opensWithLocalKey(remote)) throw RemoteUnreadable()
        return RemoteRead(remote)
    }

    /**
     * The remote changed since the last sync ([seen]), differs from the local vault, and the local key can't open it: must not
     * overwrite.
     */
    private fun isUnseenAndUnreadable(remote: SyncBackend.Remote, local: ByteArray, seen: CoreRemoteVersion?): Boolean {
        val unseen = remote.version == null || remote.version != seen
        return unseen && !remote.data.contentEquals(local) && !opensWithLocalKey(remote)
    }

    /**
     * Whether the current local vault key opens the remote (authenticated decryption only, no KDF); with no key while locked,
     * treated as unopenable.
     */
    private fun opensWithLocalKey(remote: SyncBackend.Remote): Boolean {
        val key = session.key?.copyOf() ?: return false
        return try {
            coreVaultOpensWithKey(remote.data, key)
        } finally {
            key.fill(0)
        }
    }

    /**
     * Turns off backup: releases the folder grant, or revokes cloud storage authorization and deletes local credentials;
     * existing remote backups are kept.
     */
    fun stopSync() {
        cancelScheduled()
        current.preferences.syncLocation?.let { releaseLocation(it, keepConnection = false) }
        session.updatePreferences { it.copy(syncLocation = null, lastSyncLocalUpdatedAt = null, lastSyncRemoteVersion = null) }
        state.update { it.copy(syncStatus = SyncStatus.NotConfigured, syncFolderName = null) }
    }

    /**
     * Leaves a location: folders release the SAF grant; cloud storage deletes local credentials immediately and revokes
     * server-side authorization best effort in the background (so being offline never blocks the UI).
     * [keepConnection] is true when the new location is also cloud storage and the just-saved connection must stay.
     */
    fun releaseLocation(location: SyncLocation, keepConnection: Boolean) {
        when (location) {
            is SyncLocation.Folder -> session.syncBackends.folder(location.uri).release()
            is SyncLocation.Cloud -> if (!keepConnection) {
                val connection = session.syncBackends.connections.load()
                session.syncBackends.connections.remove()
                connection?.let { session.scope.launch(session.io) { session.syncBackends.cloudSetup.revoke(it) } }
            }
        }
    }

    /**
     * Location name shown in settings and at startup: the folder name for folders (null when the grant is lost), the provider
     * name for cloud storage.
     */
    private fun displayName(location: SyncLocation): String? = when (location) {
        is SyncLocation.Folder -> session.syncBackends.folder(location.uri).displayName()
        is SyncLocation.Cloud -> location.provider.displayName
    }

    /**
     * Message when a location has no Kakey backup (matching Apple's `SyncLocation.missingBackupMessage`): cloud storage names only
     * the service, not the folder; folders name the folder. Reading the folder name is IO, so callers call this on
     * [VaultSession.io].
     */
    fun missingBackupText(location: SyncLocation): UiText = when (location) {
        is SyncLocation.Cloud -> UiText.Res(R.string.no_secure_kakey_backup_was_found_d79a, location.provider.displayName)
        is SyncLocation.Folder -> displayName(location)?.let { UiText.Res(R.string.no_secure_kakey_backup_was_found_65f1, it) }
            ?: UiText.Res(R.string.no_kakey_backup_was_found_in)
    }

    /**
     * The last first-run restore failed because the location had no backup: onboarding then offers "Choose Folder" next to
     * cloud storage.
     */
    var restoreMissedBackup = false
        private set

    /** Cancels a queued auto-sync (on lock or when sync is turned off). */
    fun cancelScheduled() {
        pendingSync?.cancel()
    }

    fun scheduleSync() {
        if (current.preferences.syncLocation == null) return
        pendingSync?.cancel()
        pendingSync = session.scope.launch {
            delay(AUTO_SYNC_DELAY_MILLIS)
            sync(BackupHistoryItem.Source.AUTO)
        }
    }

    /**
     * Uploads, downloads or reports a conflict per the decision in core `sync.rs`; the user picks a direction for conflicts in
     * settings. If another device changed the remote during upload (conditional write rejected, [RemoteChanged]), reads and
     * decides once more. [prefetched] is a remote just read (by the link check) and is used only for the first decision; writes
     * are still conditional, so a change in between is rejected and read again.
     */
    suspend fun sync(source: BackupHistoryItem.Source = BackupHistoryItem.Source.MANUAL, prefetched: RemoteRead? = null) {
        val backend = session.configuredSyncBackend() ?: return
        // Deciding needs the local key to try opening the remote; while locked, skip sync (one runs after unlock)
        if (session.key == null) return
        if (current.syncStatus == SyncStatus.Running) return
        state.update { it.copy(syncStatus = SyncStatus.Running) }
        try {
            try {
                syncOnce(backend, source, prefetched)
            } catch (_: RemoteChanged) {
                syncOnce(backend, source, prefetched = null)
            }
        } catch (error: CancellationException) {
            // The next auto-sync cancels the previously queued one: being interrupted while reading is not a failure
            state.update { if (it.syncStatus == SyncStatus.Running) it.copy(syncStatus = SyncStatus.Idle) else it }
            throw error
        } catch (_: RemoteUnreadable) {
            state.update { it.copy(syncStatus = SyncStatus.Unreadable) }
        } catch (error: Exception) {
            state.update { it.copy(syncStatus = SyncStatus.Failed(syncErrorText(error))) }
            session.recordSync(source, 0, isFailure = true)
        }
    }

    @Suppress("CyclomaticComplexMethod") // The core's five decisions plus empty local / remote; splitting would just pass state around
    private suspend fun syncOnce(backend: SyncBackend, source: BackupHistoryItem.Source, prefetched: RemoteRead?) {
        val remote = if (prefetched != null) prefetched.remote else withContext(session.io) { backend.read() }
        conflictRemote = null
        val localData = withContext(session.files) { if (session.repository.vaultExists) session.repository.encryptedData() else null }
        val localInfo = localData?.let(session.repository::envelope)
        val decision = coreDecideSync(
            local = if (localData != null && localInfo != null) CoreLocalSnapshot(localData, localInfo.updatedAt) else null,
            remote = remote?.let { CoreRemoteSnapshot(it.data, it.version, opensWithLocalKey(it)) },
            marks = CoreSyncMarks(
                current.preferences.lastSyncLocalUpdatedAt,
                current.preferences.lastSyncRemoteVersion?.let(::coreDecodeRemoteVersion),
            ),
        )
        when (decision) {
            CoreSyncDecision.NO_LOCAL_VAULT -> state.update { it.copy(syncStatus = SyncStatus.Idle) }
            CoreSyncDecision.UPLOAD -> if (localData != null &&
                localInfo != null
            ) {
                val expecting = when {
                    remote == null -> RemoteExpectation.Absent
                    remote.version != null -> RemoteExpectation.Unchanged(remote.version)
                    else -> RemoteExpectation.Any
                }
                upload(backend, localData, localInfo.updatedAt, source, expecting)
            }
            CoreSyncDecision.DOWNLOAD -> if (remote != null) download(remote, source)
            CoreSyncDecision.UP_TO_DATE -> {
                session.updatePreferences {
                    it.copy(
                        lastSyncLocalUpdatedAt = localInfo?.updatedAt,
                        lastSyncRemoteVersion = remote?.version?.let(::coreEncodeRemoteVersion),
                    )
                }
                state.update { it.copy(syncStatus = SyncStatus.Idle) }
                // Auto-sync finding both sides identical records no history; a user-tapped "Back Up Now" must show a result
                // (same on all platforms)
                if (source != BackupHistoryItem.Source.AUTO && remote != null) {
                    session.recordSync(
                        source,
                        remote.data.size.toLong(),
                        direction = BackupHistoryItem.Direction.UNCHANGED,
                        remoteDevice = remote.deviceName,
                    )
                }
            }
            CoreSyncDecision.CONFLICT -> {
                conflictRemote = remote
                // Conflict and "can't open" are states awaiting the user with no data transfer, so no history; only the
                // resolution is recorded
                state.update { it.copy(syncStatus = SyncStatus.Conflict) }
            }
            CoreSyncDecision.UNREADABLE -> state.update { it.copy(syncStatus = SyncStatus.Unreadable) }
        }
    }

    /**
     * On conflict, overwrites the remote with the local vault. Refused if the remote changed since the last sync and the local
     * key can't open it, so someone else's backup is never overwritten.
     */
    suspend fun resolveConflictKeepingLocal() {
        val backend = session.configuredSyncBackend() ?: return
        try {
            val data = withContext(session.files) { session.repository.encryptedData() }
            val remote = withContext(session.io) { backend.read() }
            val seen = current.preferences.lastSyncRemoteVersion?.let(::coreDecodeRemoteVersion)
            if (remote != null && isUnseenAndUnreadable(remote, data, seen)) {
                state.update { it.copy(syncStatus = SyncStatus.Unreadable) }
                return
            }
            state.update { it.copy(syncStatus = SyncStatus.Running) }
            upload(backend, data, session.repository.envelope(data).updatedAt, BackupHistoryItem.Source.MANUAL, RemoteExpectation.Any)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            state.update { it.copy(syncStatus = SyncStatus.Failed(syncErrorText(error))) }
        }
    }

    /** On conflict, overwrites the local vault with the version in the backup location. */
    suspend fun resolveConflictUsingRemote() {
        val backend = session.configuredSyncBackend() ?: return
        try {
            val remote = withContext(session.io) { backend.read() }
            if (remote == null) {
                val location = current.preferences.syncLocation
                val text =
                    location?.let { withContext(session.io) { missingBackupText(it) } } ?: UiText.Res(R.string.no_kakey_backup_was_found_in)
                state.update { it.copy(syncStatus = SyncStatus.Failed(text)) }
                return
            }
            state.update { it.copy(syncStatus = SyncStatus.Running) }
            download(remote, BackupHistoryItem.Source.RESTORE)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            state.update { it.copy(syncStatus = SyncStatus.Failed(syncErrorText(error))) }
        }
    }

    /**
     * "Restore from Backup" when the backup can't be opened (same on all platforms): first opens that backup in memory with its
     * master password, and only on success overwrites the local vault, switching to its contents and key and staying unlocked.
     * On a wrong password or an unreadable backup the local vault is untouched and the state stays "can't open backup".
     * Returns null on success. Opening before overwriting means a forgotten backup password never leaves the user stuck at the
     * lock screen with the local vault already replaced.
     * Wrong attempts don't count toward the consecutive-failure lockout: the ciphertext already sits in the backup location, so
     * a counter can't stop offline guessing (same as first-run restore). The caller renews the biometric key.
     */
    suspend fun restoreUnreadableBackup(password: String): UiText? {
        val backend = session.configuredSyncBackend() ?: return null
        val location = current.preferences.syncLocation ?: return null
        if (session.key == null) return null
        return try {
            val remote = withContext(session.io) { backend.read() } ?: return withContext(session.io) { missingBackupText(location) }
            val unlocked = withContext(session.io) { session.repository.unlock(password, remote.data) }
            // Replace the file, swap key and contents and bump the generation in one go (as in [download]); queued saves see
            // the generation change and give up
            withContext(NonCancellable) {
                withContext(session.files) {
                    val info = session.repository.replace(remote.data)
                    synchronized(session.monitor) {
                        if (current.phase == Phase.UNLOCKED) {
                            session.installKey(unlocked.key)?.fill(0)
                            session.setContents(unlocked.contents.accounts, unlocked.contents.categories)
                        } else {
                            // Locked meanwhile: the next unlock uses this backup's master password
                            unlocked.key.fill(0)
                            session.generation.incrementAndGet()
                        }
                    }
                    session.updatePreferences {
                        it.copy(
                            lastSyncLocalUpdatedAt = info.updatedAt,
                            lastSyncRemoteVersion = remote.version?.let(::coreEncodeRemoteVersion),
                        )
                    }
                }
                state.update { it.copy(syncStatus = SyncStatus.Idle) }
                session.recordSync(
                    BackupHistoryItem.Source.RESTORE,
                    remote.data.size.toLong(),
                    direction = BackupHistoryItem.Direction.DOWNLOAD,
                    remoteDevice = remote.deviceName,
                )
            }
            null
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            syncErrorText(error)
        }
    }

    /**
     * A backup fetched for first-run restore (same as Apple): held only in memory, and written to disk with the location enabled
     * by [commitRestore] only after it is opened with its original master password on the restore page. Keeping it in memory
     * lets a user who can't remember the password go back to onboarding and pick another source or start fresh.
     */
    class PendingRestore(val remote: SyncBackend.Remote, val location: SyncLocation, val connection: ByteArray?)

    /** Setting this to null abandons the found backup and returns to the location list to pick another source or start fresh. */
    var pendingRestore: PendingRestore? = null

    /**
     * First run: fetches the encrypted vault from the chosen location into [pendingRestore]; the restore page then opens it with
     * the original master password. Returns null when a backup was found.
     * The cloud storage connection blob is kept only in memory until the backup is opened.
     */
    suspend fun restore(location: SyncLocation, connection: ByteArray? = null): UiText? {
        session.loaded.join()
        restoreMissedBackup = false
        state.update { it.copy(isWorking = true) }
        try {
            val fetched = InMemoryCloudConnectionStore(connection)
            val backend = when (location) {
                is SyncLocation.Folder -> session.syncBackends.folder(location.uri)
                is SyncLocation.Cloud -> session.syncBackends.cloud(location.folder, fetched)
            }
            val remote = withContext(session.io) { backend.read() }
            if (remote == null) {
                restoreMissedBackup = true
                return withContext(session.io) { missingBackupText(location) }
            }
            // The access token may have been refreshed while fetching (the runner writes the new blob back to this in-memory
            // copy): save the latest one, not the stale one passed in
            pendingRestore = PendingRestore(remote, location, connection?.let { fetched.load() ?: it })
            return null
        } catch (error: CancellationException) {
            throw error
        } catch (error: VaultException) {
            return error.text
        } catch (error: Exception) {
            return syncErrorText(error)
        } finally {
            state.update { it.copy(isWorking = false) }
        }
    }

    /**
     * The backup has been opened with its original master password: saves the credentials, overwrites the local vault, enables
     * this location and records a history entry. The caller wraps this in `NonCancellable` and then unlocks the session.
     * Credentials are saved before overwriting the local vault and deleted if the overwrite fails: if credentials can't be
     * stored the whole restore fails and no local vault is left behind.
     */
    suspend fun commitRestore(pending: PendingRestore) {
        val name = withContext(session.io) { displayName(pending.location) }
        if (pending.connection != null) withContext(session.io) { session.syncBackends.connections.save(pending.connection) }
        val info = try {
            withContext(session.files) { session.repository.replace(pending.remote.data) }
        } catch (failure: Exception) {
            if (pending.connection != null) withContext(session.io) { session.syncBackends.connections.remove() }
            throw failure
        }
        pendingRestore = null
        session.updatePreferences {
            it.copy(
                syncLocation = pending.location,
                lastSyncLocalUpdatedAt = info.updatedAt,
                lastSyncRemoteVersion = pending.remote.version?.let(::coreEncodeRemoteVersion),
            )
        }
        state.update { it.copy(syncStatus = SyncStatus.Idle, syncFolderName = name) }
        session.recordSync(
            BackupHistoryItem.Source.RESTORE,
            pending.remote.data.size.toLong(),
            direction = BackupHistoryItem.Direction.DOWNLOAD,
            remoteDevice = pending.remote.deviceName,
        )
    }

    private suspend fun upload(
        backend: SyncBackend,
        data: ByteArray,
        updatedAt: Instant,
        source: BackupHistoryItem.Source,
        expecting: RemoteExpectation,
    ) {
        withContext(NonCancellable) {
            val version = withContext(session.io) { backend.write(data, updatedAt, session.deviceName(), expecting) }
            session.updatePreferences {
                it.copy(lastSyncLocalUpdatedAt = updatedAt, lastSyncRemoteVersion = version?.let(::coreEncodeRemoteVersion))
            }
            state.update { it.copy(syncStatus = SyncStatus.Idle) }
            session.recordSync(source, data.size.toLong(), direction = BackupHistoryItem.Direction.UPLOAD)
        }
    }

    /**
     * Download: replaces the file, then immediately opens it with the current key; if that fails (the remote uses a different
     * master password), locks and asks for that password. Replacing the file, swapping contents / locking and bumping the
     * generation happen in one go on `files`, so saves queued from the main thread meanwhile give up on the generation change.
     */
    private suspend fun download(remote: SyncBackend.Remote, source: BackupHistoryItem.Source) {
        withContext(NonCancellable) {
            val key = session.key?.copyOf()
            val mismatch = try {
                withContext(session.files) {
                    val info = session.repository.replace(remote.data)
                    val opened = key?.let { runCatching { session.repository.open(it) }.getOrNull() }
                    synchronized(session.monitor) {
                        when {
                            current.phase != Phase.UNLOCKED -> Unit // Locked meanwhile: the next unlock reads the new file
                            opened != null -> session.setContents(opened.accounts, opened.categories)
                            else -> session.clearSession()
                        }
                        session.generation.incrementAndGet()
                    }
                    session.updatePreferences {
                        it.copy(
                            lastSyncLocalUpdatedAt = info.updatedAt,
                            lastSyncRemoteVersion = remote.version?.let(::coreEncodeRemoteVersion),
                        )
                    }
                    key != null && opened == null
                }
            } finally {
                key?.fill(0)
            }
            if (mismatch) {
                withContext(session.io) { session.keyStore.remove() }
                state.update {
                    it.copy(biometricKeyAvailable = false, unlockError = UiText.Res(R.string.downloaded_the_backup_unlock_again_with))
                }
            }
            state.update { it.copy(syncStatus = SyncStatus.Idle) }
            session.recordSync(
                source,
                remote.data.size.toLong(),
                direction = BackupHistoryItem.Direction.DOWNLOAD,
                remoteDevice = remote.deviceName,
            )
        }
    }
}

/** Backend for the backup location saved in settings; null when sync is off. */
internal fun VaultSession.configuredSyncBackend(): SyncBackend? = when (val location = current.preferences.syncLocation) {
    null -> null
    is SyncLocation.Folder -> syncBackends.folder(location.uri)
    is SyncLocation.Cloud -> syncBackends.cloud(location.folder)
}

/**
 * Records a backup history entry (keeping at most [BackupHistoryStore.MAX_ENTRIES]). [remoteDevice]: for downloads and
 * conflicts, the device that wrote that backup; the recorded device is where the data now in effect came from (this device for
 * uploads and failures; the location name when the backup has no device name). [direction]: upload, download or already in sync.
 */
@Suppress("LongParameterList") // Fields of one history entry; every call site uses named arguments, so a wrapper object adds nothing
internal suspend fun VaultSession.recordSync(
    source: BackupHistoryItem.Source,
    size: Long,
    isFailure: Boolean = false,
    direction: BackupHistoryItem.Direction? = null,
    remoteDevice: String? = null,
) {
    val device = if (direction == BackupHistoryItem.Direction.UPLOAD || isFailure) {
        deviceName()
    } else {
        remoteDevice ?: current.syncFolderName ?: deviceName()
    }
    val item = BackupHistoryItem(now(), device, size, source, isFailure, direction, current.syncFolderName)
    val history = (listOf(item) + current.syncHistory).take(BackupHistoryStore.MAX_ENTRIES)
    state.update { it.copy(syncHistory = history) }
    withContext(io) { historyStore.save(history) }
}

/** Text for a sync failure. */
internal fun syncErrorText(error: Exception): UiText = when (error) {
    is SyncFolderUnavailable -> UiText.Res(R.string.cant_access_the_sync_folder_choose)
    is RemoteUnreadable -> UiText.Res(R.string.the_backup_here_cant_be_opened)
    // A changed certificate gets no one-tap trust: it may be a man-in-the-middle, so the user must re-check on the connection page
    is CloudCertificateException.Changed -> UiText.Res(R.string.the_servers_certificate_has_changed_set)
    is CloudCertificateException.Untrusted -> UiText.Res(R.string.the_servers_certificate_cant_be_verified)
    is java.io.IOException -> UiText.Res(R.string.cant_reach_the_server_check_the)
    is VaultException -> error.text
    is CloudSyncException -> error.text
    is RemoteChanged -> CloudSyncException(CoreCloudException.Conflict()).text
    else -> UiText.Res(R.string.sync_failed)
}
