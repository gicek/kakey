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
 * Shared setup for [VaultStore] tests: in-memory files, key storage, settings, history and sync backend, plus a controllable
 * wall clock and monotonic clock. Sync scenarios live in [SyncCoordinatorTest].
 */
@OptIn(ExperimentalCoroutinesApi::class)
abstract class VaultStoreFixture {
    protected val password = "correct-horse-battery"
    protected val files = MemoryVaultFiles()
    protected val keyStore = MemoryKeyStore()
    protected val preferences = InMemoryPreferencesStore()
    protected val history = MemoryHistory()
    protected val sync = MemorySyncFolder()
    protected var now = Instant.parse("2026-10-27T08:00:00Z")

    /**
     * Manual offset of the monotonic clock. The actual reading also adds the test scheduler's virtual time (see [store]), so
     * it advances with `delay` just like on a device.
     */
    protected var elapsed = 1_000_000L

    companion object {
        const val FAVORITES = "Favorites"
    }

    protected fun TestScope.store(scope: CoroutineScope = this, filesDispatcher: CoroutineDispatcher? = null): VaultStore {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val store = VaultStore(
            repository = VaultRepository(files, { now }, { FAVORITES }),
            keyStore = keyStore,
            preferencesStore = preferences,
            historyStore = history,
            syncBackends = sync,
            scope = scope,
            io = dispatcher,
            files = filesDispatcher ?: dispatcher,
            placeholders = { CorePlaceholders("Unknown service", "No account") },
            deviceName = { "Test Device" },
            now = { now },
            elapsedMillis = { elapsed + testScheduler.currentTime },
        )
        if (filesDispatcher == null) flush()
        return store
    }

    /**
     * Runs the tasks queued at the current virtual time (background saves, the launch load) without advancing time, so the
     * automatic sync 2 seconds later does not fire.
     */
    protected fun TestScope.flush() = testScheduler.runCurrent()

    /** Alternates between the manual dispatcher and the test scheduler until neither has pending tasks. */
    protected fun TestScope.settle(manual: ManualDispatcher) {
        while (true) {
            testScheduler.runCurrent()
            if (manual.pending == 0) return
            manual.runAll()
        }
    }

    protected fun parsed(issuer: String, account: String, secret: String = "JBSWY3DPEHPK3PXP") =
        ParsedOtpAuth(issuer, account, secret, CoreTotpAlgorithm.SHA1, 6, 30, null)

    protected fun account(issuer: String, secret: String = "JBSWY3DPEHPK3PXP") = Account(
        "A1B2C3D4-0000-4000-8000-00000000000${issuer.length}",
        issuer,
        issuer.lowercase(),
        secret,
        CoreTotpAlgorithm.SHA1,
        6,
        30,
        now,
        "manual",
    )

    /** Writes a vault file as another device would (with its own salt). */
    protected fun otherDeviceVault(password: String, vararg accounts: Account): ByteArray {
        val other = MemoryVaultFiles()
        VaultRepository(other, { now.plusSeconds(120) }, { FAVORITES }).create(VaultContents(accounts.toList(), emptyList()), password)
        return other.data!!
    }
}
