package com.gicek.kakey.android

import com.gicek.kakey.android.core.Account
import com.gicek.kakey.android.core.Core
import com.gicek.kakey.android.core.ParsedOtpAuth
import com.gicek.kakey.android.core.UiText
import com.gicek.kakey.android.core.VaultContents
import com.gicek.kakey.android.core.VaultException
import com.gicek.kakey.android.core.VaultSection
import com.gicek.kakey.android.domain.AutoLockMode
import com.gicek.kakey.android.domain.BackupHistoryItem
import com.gicek.kakey.android.domain.CloudConnectionStore
import com.gicek.kakey.android.domain.ConflictReviewResult
import com.gicek.kakey.android.domain.InMemoryPreferencesStore
import com.gicek.kakey.android.domain.Phase
import com.gicek.kakey.android.domain.Preferences
import com.gicek.kakey.android.domain.RemoteExpectation
import com.gicek.kakey.android.domain.SyncBackend
import com.gicek.kakey.android.domain.SyncLocation
import com.gicek.kakey.android.domain.SyncStatus
import com.gicek.kakey.android.domain.VaultRepository
import com.gicek.kakey.android.domain.VaultStore
import com.gicek.kakey.core.CorePlaceholders
import com.gicek.kakey.core.CoreRemoteVersion
import com.gicek.kakey.core.CoreTotpAlgorithm
import com.gicek.kakey.core.KakeyException
import com.gicek.kakey.core.coreCloudWebdavConnection
import com.gicek.kakey.core.coreEncodeRemoteVersion
import java.io.IOException
import java.time.Instant
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * Sync and backup orchestration ([com.gicek.kakey.android.domain.SyncCoordinator]): configuring a backup location and the
 * link check, upload / download / conflict, trusting only the local key (a remote it cannot open is neither synced nor
 * overwritten; only an explicit "restore from backup" replaces the local vault), conditional writes, first-run restore, and
 * cloud storage credentials.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class SyncCoordinatorTest : VaultStoreFixture() {
    @Test
    fun syncUploadsDownloadsAndReportsConflicts() = runTest {
        val store = store(backgroundScope)
        store.createVault(password, enableBiometrics = false)
        store.configureSync("content://folder")
        assertEquals(SyncStatus.Idle, store.state.value.syncStatus)
        assertEquals("Kakey", store.state.value.syncFolderName)
        assertNotNull("First sync uploads the local vault", sync.remote)

        // Another device changed the remote with the same password: download and reopen
        val other = VaultRepository(MemoryVaultFiles(sync.remote!!.data), { now.plusSeconds(120) }, { FAVORITES })
        val unlocked = other.unlock(password)
        other.save(unlocked.contents.copy(accounts = listOf(account("Remote"))), unlocked.key)
        sync.remote = sync.remote!!.copy(data = other.encryptedData(), version = CoreRemoteVersion.ModifiedAt(sync.clock.plusSeconds(300)))
        store.sync()
        assertEquals("Remote", store.state.value.accounts.single().issuer)

        // Both sides changed: conflict, and the user picks a direction
        store.addParsed(listOf(parsed("Local", "l", "GEZDGNBVGY3TQOJQ")))
        flush()
        sync.remote = sync.remote!!.copy(version = CoreRemoteVersion.ModifiedAt(sync.clock.plusSeconds(900)))
        store.sync()
        assertEquals(SyncStatus.Conflict, store.state.value.syncStatus)
        val historyBefore = store.state.value.syncHistory.size
        store.sync()
        assertEquals("A conflict waits for the user and is not recorded in history", historyBefore, store.state.value.syncHistory.size)
        store.resolveConflictKeepingLocal()
        assertEquals(SyncStatus.Idle, store.state.value.syncStatus)
        assertEquals(BackupHistoryItem.Direction.UPLOAD, store.state.value.syncHistory.first().direction)
        store.stopSync()
        assertNull(store.state.value.syncFolderName)
        assertEquals(1, sync.released)
    }

    /**
     * The remote read by the link check is reused by the first sync, and the backup read when the conflict was detected is
     * reused by the conflict screen, so each backup is read only once (OneDrive was observed reading it three times in a row).
     */
    @Test
    fun linkCheckReadIsReusedBySyncAndConflictReview() = runTest {
        val store = store(backgroundScope)
        store.createVault(password, enableBiometrics = false)
        store.configureSync("content://folder")
        assertNotNull("First sync uploads the local vault", sync.remote)
        assertEquals("Link check reads once and the first sync reuses it", 1, sync.reads)

        now = now.plusSeconds(60) // The local change must land in a new second for the envelope's updatedAt to change
        store.addParsed(listOf(parsed("Local", "l", "GEZDGNBVGY3TQOJQ")))
        flush()
        sync.remote = sync.remote!!.copy(version = CoreRemoteVersion.ModifiedAt(sync.clock.plusSeconds(900)))
        store.sync()
        assertEquals(SyncStatus.Conflict, store.state.value.syncStatus)
        val reads = sync.reads
        assertTrue(store.conflictReview() is ConflictReviewResult.Ready)
        assertEquals("Conflict screen reuses the backup read when the conflict was detected", reads, sync.reads)

        store.resolveConflictKeepingLocal()
        assertEquals(SyncStatus.Idle, store.state.value.syncStatus)
    }

    @Test
    fun uploadsAreConditionalAndRedecideWhenTheRemoteChangedMeanwhile() = runTest {
        val store = store(backgroundScope)
        store.createVault(password, enableBiometrics = false)
        store.configureSync("content://folder")
        assertEquals("Expects Absent when the remote has no backup", RemoteExpectation.Absent, sync.expectations.single())

        now = now.plusSeconds(60) // The local change must land in a new second for the envelope's updatedAt to change
        store.addParsed(listOf(parsed("Local", "l", "GEZDGNBVGY3TQOJQ")))
        flush()
        val seen = sync.remote!!.version!!
        sync.concurrentWriteBeforeNextWrite = sameVaultData(sync.remote!!.data, account("Remote"))
        store.sync()
        assertEquals("Expects the remote version seen when deciding", RemoteExpectation.Unchanged(seen), sync.expectations[1])
        assertEquals("Re-decides after rejection: both sides changed, conflict", SyncStatus.Conflict, store.state.value.syncStatus)
        assertEquals("Other", sync.remote!!.deviceName)

        store.resolveConflictKeepingLocal()
        assertEquals("Keep local: unconditional overwrite", RemoteExpectation.Any, sync.expectations.last())
        assertEquals(SyncStatus.Idle, store.state.value.syncStatus)
    }

    /**
     * A newer version of the same vault from another device: the remote envelope is opened with the same master password and
     * saved again, so it keeps the same salt and key and this device can still open it.
     */
    private suspend fun sameVaultData(remote: ByteArray, account: Account): ByteArray {
        val other = VaultRepository(MemoryVaultFiles(remote), { now.plusSeconds(120) }, { FAVORITES })
        val unlocked = other.unlock(password)
        other.save(unlocked.contents.copy(accounts = listOf(account)), unlocked.key)
        return other.encryptedData()
    }

    @Test
    fun conflictShowsTheDifferencesAndMergeKeepsBothSides() = runTest {
        val store = store(backgroundScope)
        store.createVault(password, enableBiometrics = false)
        store.addParsed(listOf(parsed("GitHub", "alex")))
        flush()
        store.configureSync("content://folder")
        sync.remote = sync.remote!!.copy(
            data = sameVaultData(sync.remote!!.data, account("Remote")),
            version = CoreRemoteVersion.ModifiedAt(sync.clock.plusSeconds(300)),
        )
        now = now.plusSeconds(60)
        store.addParsed(listOf(parsed("Local", "l", "GEZDGNBVGY3TQOJQ")))
        flush()
        store.sync()
        assertEquals(SyncStatus.Conflict, store.state.value.syncStatus)

        val review = (store.conflictReview() as ConflictReviewResult.Ready).review
        assertEquals("Backup holds only the other device's Remote", setOf("GitHub", "Local"), review.onlyLocal.map { it.issuer }.toSet())
        assertEquals(listOf("Remote"), review.onlyRemote.map { it.issuer })
        assertFalse("toString leaks no accounts or secrets", review.toString().contains("GEZDGNBVGY3TQOJQ"))

        val compared = sync.remote!!.version!!
        store.mergeWithBackup(review, emptySet())
        flush()
        val issuers = store.state.value.accounts.map { it.issuer }
        assertTrue("Both sides kept: $issuers", issuers.containsAll(listOf("GitHub", "Local", "Remote")))
        assertEquals(SyncStatus.Idle, store.state.value.syncStatus)
        assertEquals(BackupHistoryItem.Source.MERGE, store.state.value.syncHistory.first().source)
        assertEquals(BackupHistoryItem.Direction.UPLOAD, store.state.value.syncHistory.first().direction)
        assertArrayEquals("Merge result is also written to the backup", files.data, sync.remote!!.data)
        assertEquals("Expects the backup version that was compared", RemoteExpectation.Unchanged(compared), sync.expectations.last())
    }

    @Test
    fun linkingAFolderWithABackupThisVaultCannotOpenIsRefused() = runTest {
        val store = store(backgroundScope)
        store.createVault(password, enableBiometrics = false)
        val foreign = otherDeviceVault("someone else", account("Remote"))
        sync.remote = SyncBackend.Remote(foreign, CoreRemoteVersion.ModifiedAt(sync.clock), "Mac")
        assertEquals(UiText.Res(R.string.the_backup_here_cant_be_opened), store.configureSync("content://folder"))
        assertNull("Location is not enabled", store.state.value.preferences.syncLocation)
        assertArrayEquals("Remote is untouched", foreign, sync.remote!!.data)
        assertTrue("Nothing written", sync.expectations.isEmpty())
    }

    private fun cloudConnection() = coreCloudWebdavConnection(MemoryDavExecutor.BASE, "alice", "pw", false, null)

    @Test
    fun cloudLocationUploadsAndStopSyncSignsOut() = runTest {
        val store = store(backgroundScope)
        store.createVault(password, enableBiometrics = false)
        val location = sync.cloudSetup.location(cloudConnection(), "Kakey")
        store.configureCloudSync(location, cloudConnection())
        assertEquals(SyncStatus.Idle, store.state.value.syncStatus)
        assertEquals("WebDAV", store.state.value.syncFolderName)
        assertEquals(location, store.state.value.preferences.syncLocation)
        assertArrayEquals("Credentials go to secure storage", cloudConnection(), sync.connections.load())
        assertArrayEquals(files.data, sync.dav.data("Kakey/vault.kakeyvault"))

        store.stopSync()
        flush()
        assertNull(store.state.value.preferences.syncLocation)
        assertNull("Stopping sync deletes the local credentials", sync.connections.load())
        assertNotNull("Existing remote backup is kept", sync.dav.data("Kakey/vault.kakeyvault"))
    }

    /**
     * Changing the master password syncs immediately: the backup is replaced with an envelope encrypted with the new password,
     * and a failed sync is reported as the backup not being updated.
     */
    @Test
    fun passwordChangeUpdatesTheBackupAndReportsFailure() = runTest {
        val store = store(backgroundScope)
        store.createVault(password, enableBiometrics = false)
        store.configureCloudSync(sync.cloudSetup.location(cloudConnection(), "Kakey"), cloudConnection())
        val newPassword = "Kx7-new-master-Qm2v"
        // The envelope's updatedAt has one-second precision: the password change must land in a new second for the core to
        // see a local change
        now = now.plusSeconds(60)

        assertNull(store.changePassword(password, newPassword))
        assertTrue(store.backupUpdatedAfterPasswordChange())
        assertArrayEquals(files.data, sync.dav.data("Kakey/vault.kakeyvault"))

        val backupBefore = sync.dav.data("Kakey/vault.kakeyvault")
        sync.dav.failNext = IOException("offline")
        now = now.plusSeconds(60)
        assertNull(store.changePassword(newPassword, password))
        assertFalse(store.backupUpdatedAfterPasswordChange())
        assertArrayEquals("Sync failed: backup is still under the previous password", backupBefore, sync.dav.data("Kakey/vault.kakeyvault"))
    }

    @Test
    fun restoreFromCloudSavesConnectionOnlyAfterDownload() = runTest {
        val store = store(backgroundScope)
        val location = sync.cloudSetup.location(cloudConnection(), "Kakey")
        // The message names the selected service, not the folder; onboarding then offers to choose a folder
        assertEquals(
            UiText.Res(R.string.no_secure_kakey_backup_was_found_d79a, "WebDAV"),
            store.restoreFromCloud(location, cloudConnection()),
        )
        assertTrue(store.restoreMissedBackup)
        assertNull("No credentials saved without a retrieved backup", sync.connections.load())

        sync.dav.putExternal("Kakey/vault.kakeyvault", otherDeviceVault("remote password", account("Remote")))
        assertNull(store.restoreFromCloud(location, cloudConnection()))
        assertEquals(Phase.ONBOARDING, store.state.value.phase)
        assertNull("No credentials saved before the backup is unlocked", sync.connections.load())
        assertNull(store.completeRestore("remote password", enableBiometrics = false))
        assertArrayEquals(cloudConnection(), sync.connections.load())
        assertEquals("Remote", store.state.value.accounts.single().issuer)
    }

    /**
     * If the credentials cannot be saved the whole restore fails: no local vault is left behind, so creating a new vault from
     * onboarding cannot overwrite the one just restored.
     */
    @Test
    fun restoreFromCloudLeavesNoLocalVaultWhenTheConnectionCannotBeSaved() = runTest {
        val store = store(backgroundScope)
        val location = sync.cloudSetup.location(cloudConnection(), "Kakey")
        sync.dav.putExternal("Kakey/vault.kakeyvault", otherDeviceVault("remote password", account("Remote")))
        sync.connections = object : CloudConnectionStore {
            override fun load(): ByteArray? = null
            override fun save(connection: ByteArray) = throw IOException("keystore")
            override fun remove() = Unit
        }
        assertNull(store.restoreFromCloud(location, cloudConnection()))
        assertNotNull(store.completeRestore("remote password", enableBiometrics = false))
        assertEquals(Phase.ONBOARDING, store.state.value.phase)
        assertEquals("Still onboarding after relaunch", Phase.ONBOARDING, store(backgroundScope).state.value.phase)
    }

    @Test
    fun remoteWithAnotherPasswordStopsSyncUntilExplicitRestore() = runTest {
        val store = store(backgroundScope)
        store.createVault(password, enableBiometrics = true)
        store.addParsed(listOf(parsed("Local", "l")))
        flush()
        store.configureSync("content://folder")
        val localBefore = files.data!!.copyOf()
        val remoteData = otherDeviceVault("remote password", account("Remote"))
        sync.remote = SyncBackend.Remote(remoteData, CoreRemoteVersion.ModifiedAt(sync.clock.plusSeconds(300)), "Mac")
        store.sync()

        assertEquals("Local key cannot open it: sync stops", SyncStatus.Unreadable, store.state.value.syncStatus)
        assertEquals("No automatic download, no lock", Phase.UNLOCKED, store.state.value.phase)
        assertArrayEquals(localBefore, files.data)
        store.resolveConflictKeepingLocal()
        assertEquals("Keep local cannot overwrite a remote it cannot open", SyncStatus.Unreadable, store.state.value.syncStatus)
        assertArrayEquals(remoteData, sync.remote!!.data)

        // Explicit "restore from backup": the user enters that backup's master password first; a wrong one leaves the local vault alone
        assertNotNull(store.restoreUnreadableBackup(password))
        assertEquals(SyncStatus.Unreadable, store.state.value.syncStatus)
        assertEquals(Phase.UNLOCKED, store.state.value.phase)
        assertArrayEquals("Wrong password does not replace the local vault", localBefore, files.data)
        assertEquals("Local", store.state.value.accounts.single().issuer)

        // The right password replaces the local vault with the backup's contents and key and stays unlocked; the biometric key
        // is replaced with the new one
        val oldKey = keyStore.key?.copyOf()
        assertNull(store.restoreUnreadableBackup("remote password"))
        assertEquals(Phase.UNLOCKED, store.state.value.phase)
        assertEquals(SyncStatus.Idle, store.state.value.syncStatus)
        assertEquals("Remote", store.state.value.accounts.single().issuer)
        assertArrayEquals("Local file is the downloaded one, not re-sealed with the old key", remoteData, files.data)
        assertFalse("Biometrics holds the new key", keyStore.key.contentEquals(oldKey))
        assertEquals(BackupHistoryItem.Source.RESTORE, store.state.value.syncHistory.first().source)
        assertEquals(BackupHistoryItem.Direction.DOWNLOAD, store.state.value.syncHistory.first().direction)

        // Later changes are saved with the new key
        store.addParsed(listOf(parsed("Later", "x", "GEZDGNBVGY3TQOJQ")))
        flush()
        store.lock()
        store.unlock(password)
        assertEquals("Old password no longer works", Phase.LOCKED, store.state.value.phase)
        store.unlock("remote password")
        assertEquals(Phase.UNLOCKED, store.state.value.phase)
        assertEquals(setOf("Remote", "Later"), store.state.value.accounts.map { it.issuer }.toSet())
    }

    @Test
    fun cancellingDuringDownloadKeepsFileAndSessionConsistent() = runTest {
        val store = store(backgroundScope)
        store.createVault(password, enableBiometrics = false)
        store.configureSync("content://folder")
        val other = VaultRepository(MemoryVaultFiles(sync.remote!!.data), { now.plusSeconds(120) }, { FAVORITES })
        val unlocked = other.unlock(password)
        other.save(unlocked.contents.copy(accounts = listOf(account("Remote"))), unlocked.key)
        sync.remote = sync.remote!!.copy(data = other.encryptedData(), version = CoreRemoteVersion.ModifiedAt(sync.clock.plusSeconds(300)))

        var job: kotlinx.coroutines.Job? = null
        files.afterWrite = { job?.cancel() }
        job = launch { store.sync() }
        flush()
        files.afterWrite = {}
        assertTrue(job.isCancelled)
        assertEquals("Download is non-cancellable: contents already replaced", "Remote", store.state.value.accounts.single().issuer)
        assertEquals(SyncStatus.Idle, store.state.value.syncStatus)
        assertEquals(sync.remote!!.version?.let(::coreEncodeRemoteVersion), store.state.value.preferences.lastSyncRemoteVersion)
        store.addParsed(listOf(parsed("Local", "l", "GEZDGNBVGY3TQOJQ")))
        flush()
        assertEquals(2, VaultRepository(files, { now }, { FAVORITES }).unlock(password).contents.accounts.size)
    }

    @Test
    fun restoreCopiesTheSyncedVaultThenUnlocksWithItsPassword() = runTest {
        val store = store()
        assertEquals(UiText.Res(R.string.no_secure_kakey_backup_was_found_65f1, "Kakey"), store.restore("content://empty"))
        sync.remote = SyncBackend.Remote(otherDeviceVault(password, account("GitHub")), CoreRemoteVersion.ModifiedAt(sync.clock), "Mac")
        assertNull(store.restore("content://folder"))
        // The retrieved backup stays in memory: until it is unlocked the app stays on onboarding, with no local vault and no
        // enabled backup location
        assertEquals(Phase.ONBOARDING, store.state.value.phase)
        assertEquals(SyncLocation.Folder("content://folder"), store.pendingRestoreLocation)
        assertNull(files.data)
        assertNull(store.state.value.preferences.syncLocation)

        assertNotNull("Nothing written to disk on a wrong password", store.completeRestore("not the password", enableBiometrics = false))
        assertEquals(Phase.ONBOARDING, store.state.value.phase)
        assertNull(files.data)

        assertNull(store.completeRestore(password, enableBiometrics = false))
        assertEquals(Phase.UNLOCKED, store.state.value.phase)
        assertNull(store.pendingRestoreLocation)
        assertEquals(SyncLocation.Folder("content://folder"), store.state.value.preferences.syncLocation)
        assertEquals("Kakey", store.state.value.syncFolderName)
        assertEquals(BackupHistoryItem.Source.RESTORE, store.state.value.syncHistory.single().source)
        assertEquals(coreEncodeRemoteVersion(CoreRemoteVersion.ModifiedAt(sync.clock)), store.state.value.preferences.lastSyncRemoteVersion)
        assertEquals("GitHub", store.state.value.accounts.single().issuer)
    }

    /**
     * Going back to choose again when the backup's password is forgotten: discarding leaves nothing on the device, and a new
     * vault can still be created.
     */
    @Test
    fun discardingAFoundBackupLeavesNothingBehind() = runTest {
        val store = store()
        val remoteData = otherDeviceVault("remote password", account("Remote"))
        sync.remote = SyncBackend.Remote(remoteData, CoreRemoteVersion.ModifiedAt(sync.clock), "Mac")
        assertNull(store.restore("content://folder"))
        store.discardRestore()
        assertNull(store.pendingRestoreLocation)
        assertNotNull("Cannot be unlocked after discarding", store.completeRestore("remote password", enableBiometrics = false))
        assertEquals(Phase.ONBOARDING, store.state.value.phase)
        assertNull(files.data)

        assertTrue(store.createVault(password, enableBiometrics = false))
        assertEquals(Phase.UNLOCKED, store.state.value.phase)
        assertTrue(store.state.value.accounts.isEmpty())
        assertNull(store.state.value.preferences.syncLocation)
    }
}
