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
 * Orchestration tests for the Android state source. They call the same Rust core compiled for the host through JNA (the
 * rules themselves are covered by `make test-core`) and verify the platform side: the lock session, persistence, categories,
 * applying sync decisions, and error mapping.
 *
 * Saves run serially in the background: after changing in-memory state, call [flush] once for the file to be updated.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class VaultStoreTest : VaultStoreFixture() {
    @Test
    fun freshInstallStartsInOnboarding() = runTest {
        assertEquals(Phase.ONBOARDING, store().state.value.phase)
    }

    @Test
    fun startsLoadingUntilPreferencesAndVaultAreRead() = runTest {
        files.data = otherDeviceVault(password)
        preferences.save(Preferences(autoLock = AutoLockMode.THIRTY_MINUTES, syncLocation = SyncLocation.Folder("content://folder")))
        val dispatcher = StandardTestDispatcher(testScheduler)
        val store = VaultStore(
            VaultRepository(files, { now }, { FAVORITES }), keyStore, preferences, history, sync, this, dispatcher, dispatcher,
            { CorePlaceholders("Unknown service", "No account") }, { "Test Device" }, { now }, { elapsed },
        )
        assertEquals("Stays on the launch screen until loading finishes", Phase.LOADING, store.state.value.phase)
        flush()
        assertEquals(Phase.LOCKED, store.state.value.phase)
        assertEquals(AutoLockMode.THIRTY_MINUTES, store.state.value.preferences.autoLock)
        assertEquals("Sync folder name is looked up once at launch", "Kakey", store.state.value.syncFolderName)
        assertEquals(SyncStatus.Idle, store.state.value.syncStatus)
    }

    @Test
    fun createLockAndUnlockKeepsAccounts() = runTest {
        val store = store()
        assertTrue(store.createVault(password, enableBiometrics = false))
        assertNull(store.addManual("GitHub", "alex", "mzxw 6ytb-oi", CoreTotpAlgorithm.SHA1, 6, 30))
        flush()
        store.lock()
        assertEquals(Phase.LOCKED, store.state.value.phase)
        assertTrue("Locking must clear accounts from memory", store.state.value.accounts.isEmpty())

        val reopened = store()
        assertEquals(Phase.LOCKED, reopened.state.value.phase)
        reopened.unlock(password)
        assertEquals(Phase.UNLOCKED, reopened.state.value.phase)
        assertEquals("MZXW6YTBOI", reopened.state.value.accounts.single().secret)
        assertNotNull("Every save keeps the previous version as last-known-good", files.lastKnownGood)
    }

    @Test
    fun editsRightBeforeLockingStillReachTheFile() = runTest {
        val store = store()
        store.createVault(password, enableBiometrics = false)
        store.addParsed(listOf(parsed("GitHub", "alex")))
        store.lock() // The save is still queued; locking zeroes the in-memory key, but the queued save has its own copy
        flush()
        val reopened = store()
        reopened.unlock(password)
        assertEquals("GitHub", reopened.state.value.accounts.single().issuer)
    }

    @Test
    fun wrongPasswordsCountTowardsLockout() = runTest {
        store().createVault(password, enableBiometrics = false)
        val store = store()
        repeat(5) { store.unlock("wrong password") }
        assertEquals(5, preferences.load().consecutiveUnlockFailures)
        assertEquals("30-second wait after 5 consecutive failures", 30L, store.lockoutRemaining()?.seconds)
        store.unlock(password)
        assertEquals("No unlock attempt during the wait", Phase.LOCKED, store.state.value.phase)
        now = now.plusSeconds(3_600)
        store.unlock(password)
        assertEquals("Changing the system time cannot skip the wait", Phase.LOCKED, store.state.value.phase)
        elapsed += 29_000
        assertEquals(1L, store.lockoutRemaining()?.seconds)
        elapsed += 1_000
        assertNull(store.lockoutRemaining())
        store.unlock(password)
        assertEquals(Phase.UNLOCKED, store.state.value.phase)
        assertEquals(0, preferences.load().consecutiveUnlockFailures)
        assertNull(preferences.load().lockoutSeconds)
    }

    @Test
    fun lockoutRestartsAfterRebootAndSurvivesProcessRestart() = runTest {
        store().createVault(password, enableBiometrics = false)
        val store = store()
        repeat(5) { store.unlock("wrong password") }
        elapsed += 20_000
        assertEquals("After a process restart the remaining 10 seconds still apply", 10L, store().lockoutRemaining()?.seconds)

        // Device reboot: the monotonic clock restarts from zero, which must not skip the wait; the full 30 seconds restart now
        elapsed = 5_000
        val rebooted = store()
        assertEquals(30L, rebooted.lockoutRemaining()?.seconds)
        assertEquals("Start point reset to now and persisted", 5_000L, preferences.load().lockoutStartedElapsedMillis)
        elapsed += 30_000
        assertNull(rebooted.lockoutRemaining())
        rebooted.unlock(password)
        assertEquals(Phase.UNLOCKED, rebooted.state.value.phase)
    }

    @Test
    fun wrongCurrentPasswordWhenChangingCountsTowardsLockout() = runTest {
        val store = store()
        store.createVault(password, enableBiometrics = false)
        repeat(4) { assertNotNull(store.changePassword("wrong password", "another horse battery")) }
        assertEquals(4, preferences.load().consecutiveUnlockFailures)
        assertNull("No wait before the 5th failure", store.lockoutRemaining())
        assertNotNull(store.changePassword("wrong password", "another horse battery"))
        assertEquals(30L, store.lockoutRemaining()?.seconds)
        // During the wait even the correct current password is rejected, and the file is not modified
        val writes = files.writes
        assertTrue(store.changePassword(password, "another horse battery") is UiText.Plural)
        assertEquals(writes, files.writes)
        assertEquals("Attempts during the wait are not counted", 5, preferences.load().consecutiveUnlockFailures)
        elapsed += 30_000
        assertNull(store.changePassword(password, "another horse battery"))
        assertEquals("Successful password change resets the count", 0, preferences.load().consecutiveUnlockFailures)
        store.lock()
        store.unlock("another horse battery")
        assertEquals(Phase.UNLOCKED, store.state.value.phase)
    }

    @Test
    fun duplicatesAreSkippedAndInvalidSecretsRejected() = runTest {
        val store = store()
        store.createVault(password, enableBiometrics = false)
        assertNull(store.addManual("GitHub", "alex", "JBSWY3DPEHPK3PXP", CoreTotpAlgorithm.SHA1, 6, 30))
        assertNotNull(
            "Adding the same account again is a duplicate",
            store.addManual(" github ", "ALEX", "jbsw y3dp ehpk 3pxp", CoreTotpAlgorithm.SHA1, 6, 30),
        )
        assertNotNull(store.addManual("X", "y", "not base32!", CoreTotpAlgorithm.SHA1, 6, 30))
        assertEquals(1, store.state.value.accounts.size)
    }

    @Test
    fun addingInsideCategoryAlsoJoinsThatCategory() = runTest {
        val store = store()
        store.createVault(password, enableBiometrics = false)
        val work = store.createCategory("Work")
        store.setSection(VaultSection.Category(work.id))
        assertEquals(1, store.addParsed(listOf(parsed("GitHub", "alex"))))
        val github = store.state.value.accounts.single()
        assertTrue(store.state.value.isAccount(github.id, work.id))
        assertEquals(listOf(github.id), store.state.value.visibleAccounts.map(Account::id))

        store.setSection(VaultSection.All)
        assertNull(store.addManual("Google", "alex", "GEZDGNBVGY3TQOJQ", CoreTotpAlgorithm.SHA1, 6, 30))
        val google = store.state.value.accounts.first { it.issuer == "Google" }
        assertFalse(store.state.value.isAccount(google.id, work.id))
    }

    @Test
    fun setAccountCategoriesAppliesTheWholeChangeInOneWrite() = runTest {
        val store = store()
        store.createVault(password, enableBiometrics = false)
        store.addParsed(listOf(parsed("A", "a")))
        val id = store.state.value.accounts.single().id
        val work = store.createCategory("Work")
        val home = store.createCategory("Home")
        val misc = store.createCategory("Misc")
        store.toggleAccount(id, work.id)
        flush()
        val writes = files.writes
        store.setAccountCategories(id, setOf(home.id, misc.id))
        flush()
        assertFalse("Unchecked category is removed", store.state.value.isAccount(id, work.id))
        assertTrue("Newly checked category is added", store.state.value.isAccount(id, home.id))
        assertTrue(store.state.value.isAccount(id, misc.id))
        assertEquals("The whole change is written once", writes + 1, files.writes)
        store.setAccountCategories(id, setOf(home.id, misc.id))
        flush()
        assertEquals("No change, no write", writes + 1, files.writes)
    }

    @Test
    fun categoriesFollowMoveAndDeletion() = runTest {
        val store = store()
        store.createVault(password, enableBiometrics = false)
        store.addParsed(listOf(parsed("A", "a"), parsed("B", "b", "GEZDGNBVGY3TQOJQ"), parsed("C", "c", "MZXW6YTBOI")))
        val ids = store.state.value.accounts.map(Account::id)
        val category = store.createCategory("Work")
        ids.forEach { store.toggleAccount(it, category.id) }
        store.setSection(VaultSection.Category(category.id))
        flush()
        val writesBeforeDrag = files.writes
        store.move(0, 1)
        store.move(1, 2)
        assertEquals(listOf(ids[1], ids[2], ids[0]), store.state.value.sectionAccounts.map(Account::id))
        assertEquals("Reordering within a category does not affect All", ids, store.state.value.accounts.map(Account::id))
        flush()
        assertEquals("Dragging only previews and does not write", writesBeforeDrag, files.writes)
        store.commitOrder()
        flush()
        assertEquals("Saved once on release", writesBeforeDrag + 1, files.writes)
        val reopened = VaultRepository(files, { now }, { FAVORITES }).unlock(password).contents
        assertEquals(listOf(ids[1], ids[2], ids[0]), reopened.categories.single().accountIds)

        store.delete(store.state.value.account(ids[1])!!)
        assertEquals(listOf(ids[2], ids[0]), store.state.value.categories.single().accountIds)

        try {
            store.createCategory(" work ")
            fail("Names must be unique case-insensitively")
        } catch (expected: VaultException) {
            assertTrue(expected.error is KakeyException.DuplicateCategoryName)
        }
        store.deleteCategory(category.id)
        assertEquals("Deleting the current category returns to All", VaultSection.All, store.state.value.section)
        assertEquals(2, store.state.value.accounts.size)
    }

    @Test
    fun biometricUnlockUsesStoredKeyAndRefreshesAfterPasswordChange() = runTest {
        val store = store()
        store.createVault(password, enableBiometrics = true)
        store.addParsed(listOf(parsed("GitHub", "alex")))
        val firstKey = keyStore.key!!.copyOf()
        flush()
        store.lock()
        store.unlockWithBiometrics { it }
        assertEquals(Phase.UNLOCKED, store.state.value.phase)
        assertEquals(1, keyStore.authenticated)

        assertNull(store.changePassword(password, "another horse battery"))
        assertFalse("Password change re-wraps the new vault key", firstKey.contentEquals(keyStore.key!!))
        assertNotNull(store.changePassword("wrong", "x"))
        store.lock()
        store.unlock("another horse battery")
        assertEquals(1, store.state.value.accounts.size)
    }

    @Test
    fun cancellingPasswordChangeAfterTheFileIsWrittenStillSwapsTheKey() = runTest {
        val store = store()
        store.createVault(password, enableBiometrics = false)
        store.addParsed(listOf(parsed("GitHub", "alex")))
        flush()
        val newPassword = "another horse battery"
        var job: kotlinx.coroutines.Job? = null
        // Cancel the caller (the dialog is dismissed) right after the new file is written but before the in-memory key is
        // swapped: the critical section is non-cancellable and must run to completion
        files.afterWrite = { job?.cancel() }
        job = launch { store.changePassword(password, newPassword) }
        flush()
        files.afterWrite = {}
        assertTrue(job.isCancelled)
        assertFalse(store.state.value.isWorking)
        assertEquals(Phase.UNLOCKED, store.state.value.phase)

        // The in-memory key matches the file: subsequent saves are sealed with the same key
        assertNull(store.addManual("Google", "alex", "GEZDGNBVGY3TQOJQ", CoreTotpAlgorithm.SHA1, 6, 30))
        flush()
        assertExactlyOnePasswordOpens(newPassword, password, expectedAccounts = 2)
    }

    @Test
    fun cancellingPasswordChangeWhileQueuedStillCompletesTheQueuedWrite() = runTest {
        val manual = ManualDispatcher()
        val store = store(filesDispatcher = manual)
        settle(manual)
        launch { store.createVault(password, enableBiometrics = false) }
        settle(manual)
        store.addParsed(listOf(parsed("GitHub", "alex")))
        settle(manual)

        val job = launch { store.changePassword(password, "another horse battery") }
        flush()
        manual.runAll() // Verify the current password
        flush() // The new file's write is queued but has not run yet
        assertEquals(1, manual.pending)
        job.cancel()
        settle(manual)
        assertEquals(Phase.UNLOCKED, store.state.value.phase)
        assertNull(store.addManual("Google", "alex", "GEZDGNBVGY3TQOJQ", CoreTotpAlgorithm.SHA1, 6, 30))
        settle(manual)
        // Once queued, the non-cancellable critical section runs to completion; either way the file and in-memory key agree
        assertExactlyOnePasswordOpens("another horse battery", password, expectedAccounts = 2)
    }

    private fun assertExactlyOnePasswordOpens(first: String, second: String, expectedAccounts: Int) {
        val repository = VaultRepository(files, { now }, { FAVORITES })
        val opened = listOf(first, second).mapNotNull { candidate -> runCatching { repository.unlock(candidate) }.getOrNull() }
        assertEquals("Exactly one password opens the vault", 1, opened.size)
        assertEquals(expectedAccounts, opened.single().contents.accounts.size)
    }

    @Test
    fun importingAnAuthenticatorBackupPutsPinnedEntriesInFavorites() = runTest {
        val store = store()
        store.createVault(password, enableBiometrics = false)
        val imports = JSONObject(repoRoot.resolve("Core/golden/authenticator.json").readText()).getJSONArray("imports")
        val sample = (0 until imports.length()).map(imports::getJSONObject).first { it.getString("name") == "plaintext" }
        val expected = sample.getJSONObject("expected").getJSONArray("accounts")
        assertEquals(expected.length(), store.importBackup(sample.getString("file").encodeToByteArray(), sample.getString("password")))
        val favorites = store.state.value.categories.single()
        assertEquals("Pinned entries go into the Favorites category", FAVORITES, favorites.name)
        val pinnedIssuers = (0 until expected.length()).map(expected::getJSONObject).filter {
            it.getBoolean("pinned")
        }.map { it.getString("issuer") }
        assertEquals(pinnedIssuers, favorites.accountIds.map { id -> store.state.value.account(id)!!.issuer })
    }

    @Test
    fun importingAMacExportKeepsAccountsWithoutCategories() = runTest {
        val store = store()
        store.createVault(password, enableBiometrics = false)
        val exports = JSONObject(repoRoot.resolve("Core/golden/vault.json").readText()).getJSONArray("exports")
        val sample = (0 until exports.length()).map(exports::getJSONObject).first { it.getString("name") == "export-v2" }
        val expected = sample.getJSONArray("accounts")
        assertEquals(expected.length(), store.importBackup(sample.getString("file").encodeToByteArray(), sample.getString("password")))
        assertTrue("An export without categories imports without categories", store.state.value.categories.isEmpty())
    }

    @Test
    fun exportImportRoundTripMergesCategories() = runTest {
        val source = store()
        source.createVault(password, enableBiometrics = false)
        source.addParsed(listOf(parsed("GitHub", "alex")))
        val category = source.createCategory("Work")
        source.toggleAccount(source.state.value.accounts.single().id, category.id)
        val exported = source.exportBackup("Kx7-export-Qm2v")
        flush()

        files.deleteAll()
        val target = store()
        val messages = mutableListOf<UiText>()
        backgroundScope.launch { target.messages.collect { messages += it } }
        target.createVault(password, enableBiometrics = false)
        try {
            target.importBackup(exported, "")
            fail("Encrypted export requires a password")
        } catch (expected: VaultException) {
            assertTrue(expected.error is KakeyException.EmptyPassword || expected.error is KakeyException.PasswordRequired)
        }
        assertEquals(1, target.importBackup(exported, "Kx7-export-Qm2v"))
        assertEquals("Work", target.state.value.categories.single().name)
        assertEquals(0, target.importBackup(exported, "Kx7-export-Qm2v"))
        flush()
        assertEquals(
            "All duplicates: reports that every account already exists",
            UiText.Res(R.string.all_accounts_in_this_file_already),
            messages.last(),
        )
    }

    /**
     * First-run restore from a Kakey export file (same as Apple): after the export password opens it, a new vault is created
     * with the chosen master password, categories are restored too, and no backup location is enabled. By default the master
     * password is set separately; with "use as master password" checked it is the export password. A master password that
     * fails the password rules creates nothing.
     */
    @Test
    fun restoreFromExportUsesTheChosenMasterPassword() = runTest {
        val source = store()
        source.createVault(password, enableBiometrics = false)
        source.addParsed(listOf(parsed("GitHub", "alex")))
        val category = source.createCategory("Work")
        source.toggleAccount(source.state.value.accounts.single().id, category.id)
        val exported = source.exportBackup("Kx7-export-Qm2v")
        flush()

        files.deleteAll()
        val target = store()
        try {
            target.restoreFromExport(exported, "wrong-Password-9", "Kx7-master-Qm2v", enableBiometrics = false)
            fail("Wrong password")
        } catch (expected: VaultException) {
            assertEquals(Phase.ONBOARDING, target.state.value.phase)
        }
        assertEquals(
            UiText.Res(R.string.this_export_password_cant_be_used),
            target.restoreFromExport(exported, "Kx7-export-Qm2v", "12345678", enableBiometrics = false),
        )
        assertEquals(Phase.ONBOARDING, target.state.value.phase)
        assertNull(target.restoreFromExport(exported, "Kx7-export-Qm2v", "Kx7-master-Qm2v", enableBiometrics = false))
        assertEquals(Phase.UNLOCKED, target.state.value.phase)
        assertEquals("GitHub", target.state.value.accounts.single().issuer)
        assertEquals("Work", target.state.value.categories.single().name)
        assertNull(target.state.value.preferences.syncLocation)
        flush()

        target.lock()
        target.unlock("Kx7-export-Qm2v")
        assertEquals("With a separate master password, the export password cannot unlock", Phase.LOCKED, target.state.value.phase)
        target.unlock("Kx7-master-Qm2v")
        assertEquals(Phase.UNLOCKED, target.state.value.phase)

        // "Use as master password" checked: the export password becomes the new master password
        target.resetApplication()
        assertNull(target.restoreFromExport(exported, "Kx7-export-Qm2v", "Kx7-export-Qm2v", enableBiometrics = false))
        target.lock()
        target.unlock("Kx7-export-Qm2v")
        assertEquals("Export password is the new master password", Phase.UNLOCKED, target.state.value.phase)
    }

    /**
     * Auto-lock counts from the last user activity on the monotonic clock, regardless of foreground or background; returning
     * to the foreground re-checks the deadline.
     */
    @Test
    fun autoLockCountsFromLastActivityOnTheMonotonicClock() = runTest {
        val store = store()
        store.createVault(password, enableBiometrics = false)
        store.setAutoLock(AutoLockMode.ONE_MINUTE)
        now = now.plusSeconds(3_600) // Changing the system time does not count
        elapsed += 59_000
        store.onForeground()
        assertEquals("1 minute: back in the foreground at 59 seconds, not locked", Phase.UNLOCKED, store.state.value.phase)
        elapsed += 1_000
        store.onForeground()
        assertEquals("No activity since unlocking, 1 minute reached", Phase.LOCKED, store.state.value.phase)
        assertTrue("After auto-lock the unlock screen does not prompt for biometrics", store.state.value.autoBiometricSuppressed)

        // Shortening the duration re-checks against the last activity: lock immediately if already idle longer than that
        store.unlock(password)
        store.setAutoLock(AutoLockMode.THIRTY_MINUTES)
        elapsed += 6 * 60_000
        store.onForeground()
        assertEquals(Phase.UNLOCKED, store.state.value.phase)
        store.setAutoLock(AutoLockMode.FIVE_MINUTES)
        assertEquals("Idle for 6 minutes, switching to 5 minutes locks", Phase.LOCKED, store.state.value.phase)
    }

    /**
     * Continuous use never locks: every activity pushes the lock deadline back, and only a full idle period locks. Activity
     * while locked does not restart the timer.
     */
    @Test
    fun userActivityPostponesAutoLock() = runTest {
        val store = store()
        store.createVault(password, enableBiometrics = false)
        store.setAutoLock(AutoLockMode.ONE_MINUTE)
        repeat(5) {
            elapsed += 50_000
            store.noteUserActivity()
            store.onForeground()
            assertEquals("Unlocked for over 1 minute, but active every 50 seconds", Phase.UNLOCKED, store.state.value.phase)
        }
        elapsed += 59_000
        store.onForeground()
        assertEquals(Phase.UNLOCKED, store.state.value.phase)
        elapsed += 1_000
        store.onForeground()
        assertEquals("Idle for 1 minute after the last activity", Phase.LOCKED, store.state.value.phase)

        store.noteUserActivity()
        store.unlock(password)
        elapsed += 60_000
        store.onForeground()
        assertEquals("Activity while locked does not count; the timer starts at unlock", Phase.LOCKED, store.state.value.phase)
    }

    /**
     * When the foreground timer fires it re-checks against the latest activity: if there was activity it sleeps again,
     * otherwise it locks.
     */
    @Test
    fun foregroundTimerHonorsActivityDuringTheWait() = runTest {
        val store = store()
        store.createVault(password, enableBiometrics = false)
        store.setAutoLock(AutoLockMode.ONE_MINUTE)
        testScheduler.advanceTimeBy(30_000)
        store.noteUserActivity()
        testScheduler.advanceTimeBy(30_000)
        testScheduler.runCurrent()
        assertEquals("Timer wakes only 30 seconds after the last activity", Phase.UNLOCKED, store.state.value.phase)
        testScheduler.advanceTimeBy(30_000)
        testScheduler.runCurrent()
        assertEquals(Phase.LOCKED, store.state.value.phase)
    }

    /** Staying in the foreground without activity still locks on time: the timer runs in the state source's scope. */
    @Test
    fun autoLockFiresInTheForeground() = runTest {
        val store = store()
        store.createVault(password, enableBiometrics = false)
        store.setAutoLock(AutoLockMode.FIVE_MINUTES)
        testScheduler.advanceTimeBy(5 * 60_000 - 1)
        testScheduler.runCurrent()
        assertEquals(Phase.UNLOCKED, store.state.value.phase)
        elapsed += 5 * 60_000
        testScheduler.advanceTimeBy(1)
        testScheduler.runCurrent()
        assertEquals(Phase.LOCKED, store.state.value.phase)
        assertTrue("Locking must clear accounts from memory", store.state.value.accounts.isEmpty())
    }

    @Test
    fun resetErasesLocalDataButNotTheSyncFolder() = runTest {
        val store = store(backgroundScope)
        store.createVault(password, enableBiometrics = true)
        store.configureSync("content://folder")
        store.addParsed(listOf(parsed("GitHub", "alex"))) // The save is still queued
        store.resetApplication()
        flush()

        assertEquals(Phase.ONBOARDING, store.state.value.phase)
        assertNull("Queued save finishes before deletion and does not write the file back", files.data)
        assertNull(keyStore.key)
        assertEquals(Preferences(), preferences.load())
        assertTrue(history.items.isEmpty())
        assertTrue(store.state.value.syncHistory.isEmpty())
        assertEquals(1, sync.released)
        assertNotNull("Backup in the sync folder is untouched", sync.remote)
        assertTrue("A new vault can be created after reset", store.createVault("fresh horse battery", enableBiometrics = false))
    }

    @Test
    fun lastKnownGoodOnlyKeepsDecodableEnvelopes() = runTest {
        val garbage = "not a vault".encodeToByteArray()
        files.write(garbage)
        assertNull(files.lastKnownGood)
        val valid = otherDeviceVault(password)
        files.write(valid)
        assertNull("A corrupt file never becomes the last-known-good snapshot", files.lastKnownGood)
        val store = store()
        store.unlock(password)
        store.addParsed(listOf(parsed("GitHub", "alex")))
        flush()
        assertArrayEquals(valid, files.lastKnownGood)
    }

    @Test
    fun totpMatchesGoldenVectors() {
        val vectors = org.json.JSONArray(repoRoot.resolve("Core/golden/totp.json").readText())
        for (index in 0 until vectors.length()) {
            val vector = vectors.getJSONObject(index)
            val account = Account(
                "00000000-0000-4000-8000-000000000000", "x", "y", vector.getString("secret"),
                CoreTotpAlgorithm.valueOf(vector.getString("algorithm")), vector.getInt("digits"), vector.getInt("period"),
                Instant.EPOCH, "manual",
            )
            val at = Instant.ofEpochSecond(vector.getLong("time"))
            assertEquals(vector.toString(), vector.getString("code"), Core.code(account, at))
            assertEquals(vector.getString("formatted"), Core.formatted(vector.getString("code")))
        }
    }

    /**
     * Only the lock screen after launch prompts for biometrics automatically. Any lock while running (manual or automatic)
     * suppresses the prompt, and unlocking clears the flag.
     */
    @Test
    fun anyLockSuppressesTheAutomaticBiometricPrompt() = runTest {
        val store = store()
        assertTrue(store.createVault(password, enableBiometrics = false))
        flush()
        store.lock()
        assertTrue("No prompt after manual lock", store.state.value.autoBiometricSuppressed)
        store.unlock(password)
        flush()
        assertFalse(store.state.value.autoBiometricSuppressed)
        elapsed += 5 * 60_000
        store.onForeground()
        assertEquals(Phase.LOCKED, store.state.value.phase)
        assertTrue("No prompt after auto-lock either", store.state.value.autoBiometricSuppressed)
        assertFalse("Lock screen after launch prompts once", store().state.value.autoBiometricSuppressed)
    }
}
