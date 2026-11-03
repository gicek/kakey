package com.gicek.kakey.android.domain

import com.gicek.kakey.core.CoreDropboxAppRequest
import com.gicek.kakey.core.CoreHttpRequest
import com.gicek.kakey.core.CoreHttpResponse
import com.gicek.kakey.core.CoreRemoteVersion
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.time.Instant
import javax.crypto.Cipher

/**
 * Platform capabilities the vault needs. Real implementations live in `data/` (files, Keystore, SAF); tests inject in-memory
 * fakes and never touch real storage or system state (AGENTS.md).
 */
interface VaultFiles {
    val vaultExists: Boolean

    /** Reads the local encrypted vault; throws if it doesn't exist or can't be read. */
    fun read(): ByteArray

    /** Atomically replaces the main file, first keeping the current parseable version as last-known-good. */
    fun write(data: ByteArray)

    /** Deletes the local vault and last-known-good snapshot (app reset). */
    fun deleteAll()
}

/**
 * Keeps the vault key for biometric quick unlock (Android Keystore).
 * Saving needs no authentication; loading requires the user to authenticate in BiometricPrompt with the [Cipher] that [load]
 * hands over. [save], [hasKey] and [remove] may trigger Keystore key generation and IPC, so callers run them on a background
 * thread. [load] moves Keystore access and file reads to the background itself; only `authenticate` runs on the caller's
 * thread (the main thread, as BiometricPrompt requires).
 */
interface VaultKeyStore {
    fun save(key: ByteArray)
    fun hasKey(): Boolean
    fun remove()

    /**
     * @param authenticate Shows BiometricPrompt and, once authenticated, returns the same Cipher unlocked; throws
     *   [BiometricCancelled] on cancel. Runs on the thread that called [load].
     */
    suspend fun load(authenticate: suspend (Cipher) -> Cipher): ByteArray
}

/** The user canceled the system biometric prompt or chose "Use Master Password": silently return to password entry. */
class BiometricCancelled : Exception()

/** Biometric failure (lockout, unavailable, ...) carrying the reason to show. */
class BiometricFailed(val reason: String) : Exception(reason)

/**
 * The key was invalidated (the system revokes it when fingerprints / faces are re-enrolled); unlock with the master password,
 * then re-enable.
 */
class BiometricKeyInvalidated : Exception()

/**
 * Backup and sync backend (docs/TECHNICAL.md): an instance is bound to one configured remote location and reads / writes
 * the encrypted envelope and non-sensitive metadata, with the same remote layout as the Mac (`vault.kakeyvault` +
 * `vault.metadata.json`). Upload / download / conflict decisions are made by core `sync.rs`; the backend only reports the
 * remote version (modification time for folders, ETag / rev for cloud storage).
 */
interface SyncBackend {
    data class Remote(val data: ByteArray, val version: CoreRemoteVersion?, val deviceName: String?)

    /** Location name for display; null when authorization has been lost. */
    fun displayName(): String?
    fun read(): Remote?

    /**
     * Returns the remote version after writing, used as the marker for the next sync decision. If [expecting] isn't met, throws
     * [RemoteChanged] and leaves the remote untouched; backends without conditional writes (folders) ignore it.
     */
    fun write(data: ByteArray, vaultUpdatedAt: Instant, deviceName: String, expecting: RemoteExpectation): CoreRemoteVersion?

    /** Releases authorization when sync stops or the app is reset. */
    fun release()
}

/** What a remote write requires of the remote state. */
sealed interface RemoteExpectation {
    /** The user explicitly chose to overwrite (manual backup, keeping this device's copy on conflict). */
    data object Any : RemoteExpectation

    /** There was no remote backup at decision time. */
    data object Absent : RemoteExpectation

    /** The remote was at this version at decision time. */
    data class Unchanged(val version: CoreRemoteVersion) : RemoteExpectation
}

/** A conditional write was rejected: another device changed the remote after the decision. */
class RemoteChanged : Exception()

/**
 * The local key can't open the remote backup (a different vault, or another device changed the master password): don't sync or
 * overwrite.
 */
class RemoteUnreadable : Exception()

/**
 * Executes core-built HTTP requests (cloud storage backup). The contract is in `kakey-ffi`'s `cloud.rs`: send as-is, don't
 * follow redirects (3xx goes back to the core to check same-origin), no cookies, no cache, and read response bodies up to the
 * limit + 1 byte. Blocking; run on the IO dispatcher. Transport failures (offline, timeout, TLS) throw [java.io.IOException].
 */
fun interface HttpExecutor {
    fun execute(request: CoreHttpRequest): CoreHttpResponse
}

/**
 * Keeps the cloud storage connection blob (an opaque serialization of core `cloudset::Connection`, including a password or
 * token): device-only, never carried along with backups, and not gated by biometrics (first-run restore needs it before the
 * vault is unlocked).
 */
interface CloudConnectionStore {
    fun load(): ByteArray?
    fun save(connection: ByteArray)
    fun remove()
}

/**
 * Opens the OAuth provider's sign-in page and waits for the redirect URL (docs/TECHNICAL.md). [accepts] lets the core
 * decide whether a redirect belongs to this sign-in (both URL and `state` match); only accepted redirects are returned. The
 * coroutine is canceled if the user gives up.
 */
fun interface WebAuthenticator {
    suspend fun authenticate(url: String, accepts: (String) -> Boolean): String
}

/**
 * Authorization through the official Dropbox Android app: when the official app with the correct signature is installed, it
 * authorizes and returns an authorization code, saving a sign-in compared with the browser. Returns null if it's not installed,
 * the signature doesn't match or it can't be launched; the caller then falls back to [WebAuthenticator]. [accepts] lets the
 * core check that the returned `state` belongs to this sign-in.
 */
fun interface DropboxAppAuthenticator {
    suspend fun authenticate(request: CoreDropboxAppRequest, accepts: (String) -> Boolean): DropboxAppResult?
}

/**
 * Result returned by the Dropbox app via intent: `ACCESS_TOKEN` (token type), `ACCESS_SECRET` (authorization code) and
 * `AUTH_STATE`, validated by the core.
 */
class DropboxAppResult(val tokenType: String, val code: String, val state: String) {
    override fun toString(): String = "DropboxAppResult(<redacted>)"
}

/** Creates backends from the location saved in settings, and provides cloud storage connection keeping and one-off setup operations. */
interface SyncBackends {
    /** The app's saved cloud storage connection. */
    val connections: CloudConnectionStore

    /** One-off operations while connecting cloud storage (before the connection is saved). */
    val cloudSetup: CloudSetup

    fun folder(folderUri: String): SyncBackend

    /** Cloud storage backend; first-run restore passes a temporary in-memory connection that is saved only after confirmation. */
    fun cloud(folder: String, connections: CloudConnectionStore = this.connections): SyncBackend
}

/** In-memory connection keeping: temporary connections during first-run restore, and tests. */
class InMemoryCloudConnectionStore(private var value: ByteArray? = null) : CloudConnectionStore {
    override fun load(): ByteArray? = value

    override fun save(connection: ByteArray) {
        value = connection
    }

    override fun remove() {
        value = null
    }
}

class SyncFolderUnavailable : Exception()

/**
 * Size limit for external files (see docs/SECURITY.md): imported backup files and the vault in a backup folder are capped at
 * this and anything larger is treated as invalid without being read fully into memory. A vault with thousands of accounts is
 * under 1 MiB, so 16 MiB leaves plenty of headroom.
 */
object FileLimits {
    const val MAX_EXTERNAL_FILE_BYTES: Long = 16L shl 20
    private const val READ_BUFFER_BYTES = 64 * 1024

    /** Reads at most [max] bytes; returns null on overflow without reading further. */
    fun InputStream.readAtMost(max: Long = MAX_EXTERNAL_FILE_BYTES): ByteArray? {
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(READ_BUFFER_BYTES)
        var total = 0L
        while (true) {
            val read = read(buffer)
            if (read < 0) return output.toByteArray()
            total += read
            if (total > max) return null
            output.write(buffer, 0, read)
        }
    }
}

/** Backup history (local plaintext: time, device name, size and source; no account data). */
data class BackupHistoryItem(
    val date: Instant,
    val device: String,
    val sizeBytes: Long,
    val source: Source,
    val isFailure: Boolean = false,
    /** Direction of data in this successful sync; absent for failures and conflicts. */
    val direction: Direction? = null,
    /** Location name for this sync (OneDrive, folder name, ...) to tell locations apart after a change. */
    val location: String? = null,
) {
    val isWarning: Boolean get() = isFailure

    /**
     * The device matters only for downloads and conflicts (uploads and failures are always this device); hidden when it
     * matches this device.
     */
    fun otherDevice(thisDevice: String): String? =
        device.takeUnless { direction == Direction.UPLOAD || isFailure || it == thisDevice || it.isEmpty() }

    enum class Source { AUTO, MANUAL, SYNC, RESTORE, MERGE }

    /** Upload (this device overwrote the backup), download (the backup replaced this device), or already in sync. */
    enum class Direction { UPLOAD, DOWNLOAD, UNCHANGED }
}

/** File IO happens inside the implementation; callers await it in a coroutine without blocking the main thread. */
interface BackupHistoryStore {
    suspend fun load(): List<BackupHistoryItem>
    suspend fun save(items: List<BackupHistoryItem>)
    suspend fun clear()

    companion object {
        const val MAX_ENTRIES = 50
    }
}
