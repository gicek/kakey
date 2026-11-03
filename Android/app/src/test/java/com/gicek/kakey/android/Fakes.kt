package com.gicek.kakey.android

import com.gicek.kakey.android.domain.BackupHistoryItem
import com.gicek.kakey.android.domain.BackupHistoryStore
import com.gicek.kakey.android.domain.CloudConnectionStore
import com.gicek.kakey.android.domain.CloudSetup
import com.gicek.kakey.android.domain.CloudSyncBackend
import com.gicek.kakey.android.domain.InMemoryCloudConnectionStore
import com.gicek.kakey.android.domain.RemoteChanged
import com.gicek.kakey.android.domain.RemoteExpectation
import com.gicek.kakey.android.domain.SyncBackend
import com.gicek.kakey.android.domain.SyncBackends
import com.gicek.kakey.android.domain.VaultFiles
import com.gicek.kakey.android.domain.VaultKeyStore
import com.gicek.kakey.core.CoreRemoteVersion
import com.gicek.kakey.core.coreVaultIsValidEnvelope
import java.io.File
import java.time.Instant
import javax.crypto.Cipher
import kotlin.coroutines.CoroutineContext
import kotlinx.coroutines.CoroutineDispatcher

/**
 * In-memory test implementations that never touch real files, the Keystore or SAF (see AGENTS.md).
 * The last-known-good snapshot follows the same rule as `FileVaultFiles`: the current file is kept only if it is a valid envelope.
 */
class MemoryVaultFiles(var data: ByteArray? = null) : VaultFiles {
    var lastKnownGood: ByteArray? = null
    var writes = 0

    /** Called after every file write; tests use it to cancel the caller after the file is written but before the in-memory key changes. */
    var afterWrite: () -> Unit = {}
    override val vaultExists get() = data != null
    override fun read() = data ?: error("no vault")
    override fun write(data: ByteArray) {
        this.data?.let { current -> if (coreVaultIsValidEnvelope(current)) lastKnownGood = current }
        this.data = data
        writes++
        afterWrite()
    }

    override fun deleteAll() {
        data = null
        lastKnownGood = null
    }
}

class MemoryKeyStore : VaultKeyStore {
    var key: ByteArray? = null
    var authenticated = 0
    override fun save(key: ByteArray) {
        this.key = key.copyOf()
    }

    override fun hasKey() = key != null
    override fun remove() {
        key = null
    }

    override suspend fun load(authenticate: suspend (Cipher) -> Cipher): ByteArray {
        authenticated++
        return key?.copyOf() ?: error("no key")
    }
}

class MemoryHistory : BackupHistoryStore {
    var items = emptyList<BackupHistoryItem>()
    override suspend fun load() = items
    override suspend fun save(items: List<BackupHistoryItem>) {
        this.items = items
    }

    override suspend fun clear() {
        items = emptyList()
    }
}

/**
 * Sync folder: a single "remote" file plus a modification time, which tests can overwrite to simulate another device.
 * Every folder URI maps to this same remote.
 */
class MemorySyncFolder :
    SyncBackends,
    SyncBackend {
    /** Cloud storage locations use the in-memory WebDAV server, driving the real core protocol. */
    val dav = MemoryDavExecutor()

    /** Tests can swap in an implementation whose save fails. */
    override var connections: CloudConnectionStore = InMemoryCloudConnectionStore()
    override val cloudSetup = CloudSetup(dav, "Kakey-test")

    override fun cloud(folder: String, connections: CloudConnectionStore): SyncBackend =
        CloudSyncBackend(folder, connections, dav, "Kakey-test")

    var remote: SyncBackend.Remote? = null
    var clock = Instant.parse("2026-10-27T00:00:00Z")
    var released = 0

    /** How many times the remote was read in full. */
    var reads = 0

    /**
     * Content "another device" writes just before the next write, which is then rejected as a failed conditional write
     * (simulating a cloud storage backend).
     */
    var concurrentWriteBeforeNextWrite: ByteArray? = null
    val expectations = mutableListOf<RemoteExpectation>()
    override fun folder(folderUri: String): SyncBackend = this
    override fun displayName() = "Kakey"
    override fun read(): SyncBackend.Remote? {
        reads++
        return remote
    }
    override fun write(data: ByteArray, vaultUpdatedAt: Instant, deviceName: String, expecting: RemoteExpectation): CoreRemoteVersion {
        expectations += expecting
        concurrentWriteBeforeNextWrite?.let { other ->
            concurrentWriteBeforeNextWrite = null
            clock = clock.plusSeconds(60)
            remote = SyncBackend.Remote(other, CoreRemoteVersion.ModifiedAt(clock), "Other")
            throw RemoteChanged()
        }
        clock = clock.plusSeconds(60)
        val version = CoreRemoteVersion.ModifiedAt(clock)
        remote = SyncBackend.Remote(data, version, deviceName)
        return version
    }

    override fun release() {
        released++
    }
}

/**
 * A manually advanced dispatcher: dispatched tasks queue up until the test runs them. Used to cancel the caller after a vault
 * file operation is dispatched but before it runs, verifying that the non-cancellable critical section still completes
 * (standing in for the app's serial `Dispatchers.IO.limitedParallelism(1)`).
 */
class ManualDispatcher : CoroutineDispatcher() {
    private val queue = ArrayDeque<Runnable>()
    val pending: Int get() = queue.size

    override fun dispatch(context: CoroutineContext, block: Runnable) {
        queue.addLast(block)
    }

    /** Runs the queued tasks, including any queued while running. */
    fun runAll() {
        while (queue.isNotEmpty()) queue.removeFirst().run()
    }
}

/** The repository root (passed in by Gradle), used to read `Core/golden/`. */
val repoRoot: File get() = File(requireNotNull(System.getProperty("kakey.repo")) { "kakey.repo is not set" })
