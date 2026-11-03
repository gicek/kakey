package com.gicek.kakey.android.domain

import com.gicek.kakey.core.CoreCloudException
import com.gicek.kakey.core.CoreCloudOperation
import com.gicek.kakey.core.CoreCloudOutcome
import com.gicek.kakey.core.CoreCloudStep
import com.gicek.kakey.core.CoreHttpResponse
import com.gicek.kakey.core.CoreRemoteVersion
import com.gicek.kakey.core.CoreUploadMode
import com.gicek.kakey.core.coreCloudConnectionInfo
import com.gicek.kakey.core.coreCloudFetchBackup
import com.gicek.kakey.core.coreCloudUploadBackup
import java.time.Instant

/**
 * Cloud storage backend (docs/TECHNICAL.md): `vault.kakeyvault` + `vault.metadata.json` in the chosen remote folder.
 *
 * The protocols and remote layout live in the core (`cloudset` + `kakey_core::backup`); this only drives the operations. The
 * remote version is the ETag / rev and writes are conditional: if the remote changed after the decision, [RemoteChanged] is
 * thrown and [SyncCoordinator] decides again; other failures are [CloudSyncException].
 * The caller (`VaultRepository`) validates the downloaded envelope's format, as with the folder backend.
 */
class CloudSyncBackend(
    private val folder: String,
    private val connections: CloudConnectionStore,
    executor: HttpExecutor,
    userAgent: String,
    private val now: () -> Instant = Instant::now,
) : SyncBackend {
    private val runner = CloudOperationRunner(connections, executor, userAgent)

    override fun displayName(): String? = runCatching { connections.load()?.let { coreCloudConnectionInfo(it).host } }.getOrNull()

    override fun read(): SyncBackend.Remote? {
        val outcome = runner.run { connection, userAgent -> coreCloudFetchBackup(connection, folder, userAgent) }
        val backup = (outcome as? CoreCloudOutcome.Backup ?: throw CloudSyncException.internal()).backup ?: return null
        return SyncBackend.Remote(backup.data, backup.version, backup.deviceName)
    }

    override fun write(data: ByteArray, vaultUpdatedAt: Instant, deviceName: String, expecting: RemoteExpectation): CoreRemoteVersion? {
        val mode = when (expecting) {
            RemoteExpectation.Any -> CoreUploadMode.Overwrite
            RemoteExpectation.Absent -> CoreUploadMode.IfUnchanged(null)
            is RemoteExpectation.Unchanged -> CoreUploadMode.IfUnchanged(expecting.version)
        }
        val outcome = try {
            runner.run { connection, userAgent ->
                coreCloudUploadBackup(connection, folder, data, deviceName, vaultUpdatedAt, now(), mode, userAgent)
            }
        } catch (error: CloudSyncException) {
            if (error.error is CoreCloudException.Conflict) throw RemoteChanged()
            throw error
        }
        return (outcome as? CoreCloudOutcome.Uploaded ?: throw CloudSyncException.internal()).version
    }

    /** Revocation and credential deletion on disconnect happen in settings (they need the network and don't follow from stopping sync). */
    override fun release() = Unit
}

/**
 * Drives core cloud storage operations: passes the saved connection blob to the constructor and runs requests until done;
 * saves a new connection blob as soon as an operation returns one.
 */
class CloudOperationRunner(
    private val connections: CloudConnectionStore,
    private val executor: HttpExecutor,
    private val userAgent: String,
) {
    fun run(make: (connection: ByteArray, userAgent: String) -> CoreCloudOperation): CoreCloudOutcome {
        val connection = connections.load() ?: throw CloudSyncException(CoreCloudException.ReauthRequired())
        return wrapping { make(connection, userAgent) }.use(::drive)
    }

    /** Operations that don't need a saved connection (Nextcloud sign-in) also go through here. */
    fun drive(operation: CoreCloudOperation): CoreCloudOutcome {
        var response: CoreHttpResponse? = null
        while (true) {
            when (val step = wrapping { operation.advance(response) }) {
                is CoreCloudStep.Send -> response = executor.execute(step.request)
                is CoreCloudStep.Done -> {
                    step.connection?.let(connections::save)
                    return step.outcome
                }
            }
        }
    }

    private inline fun <T> wrapping(body: () -> T): T = try {
        body()
    } catch (error: CoreCloudException) {
        throw CloudSyncException(error)
    }
}

/** Platform form of a cloud storage failure: the text is resolved at display time from the table in `core/Core.kt` using the core's key. */
class CloudSyncException(val error: CoreCloudException) : Exception(error.toString()) {
    companion object {
        fun internal() = CloudSyncException(CoreCloudException.Internal())
    }
}
