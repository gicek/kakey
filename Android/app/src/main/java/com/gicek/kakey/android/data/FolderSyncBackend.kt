package com.gicek.kakey.android.data

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.core.net.toUri
import androidx.documentfile.provider.DocumentFile
import com.gicek.kakey.android.core.VaultException
import com.gicek.kakey.android.data.cloud.KeystoreCloudConnectionStore
import com.gicek.kakey.android.data.cloud.OkHttpExecutor
import com.gicek.kakey.android.domain.CloudConnectionStore
import com.gicek.kakey.android.domain.CloudSetup
import com.gicek.kakey.android.domain.CloudSyncBackend
import com.gicek.kakey.android.domain.FileLimits
import com.gicek.kakey.android.domain.FileLimits.readAtMost
import com.gicek.kakey.android.domain.RemoteExpectation
import com.gicek.kakey.android.domain.SyncBackend
import com.gicek.kakey.android.domain.SyncBackends
import com.gicek.kakey.android.domain.SyncFolderUnavailable
import com.gicek.kakey.core.CoreRemoteVersion
import com.gicek.kakey.core.KakeyException
import java.time.Instant
import org.json.JSONObject

/**
 * A sync folder the user granted through the system file picker (SAF), such as a cloud drive app or a Syncthing folder.
 *
 * The file layout matches the Mac: `vault.kakeyvault` (a verbatim copy of the local encrypted vault) plus
 * `vault.metadata.json` (device name and time, not sensitive). If the chosen folder is a `Kakey` folder or already holds a
 * vault it is used directly; otherwise the `Kakey/` subfolder is used (created if needed).
 * Syncing is done by the file provider and is not real-time; upload / download / conflict decisions are made by core `sync.rs`.
 * The remote vault is read up to [FileLimits.MAX_EXTERNAL_FILE_BYTES]; larger files are treated as corrupt and never read
 * fully into memory.
 * The remote version is the envelope file's modification time. File systems have no conditional writes, so `expecting` is
 * ignored and the core detects conflicts by modification time.
 */
class FolderSyncBackend(private val context: Context, private val folderUri: String) : SyncBackend {
    override fun release() {
        runCatching {
            context.contentResolver.releasePersistableUriPermission(
                folderUri.toUri(),
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
            )
        }
    }

    override fun displayName(): String? = runCatching {
        vaultFolder(create = false)?.name
            ?: root().name
    }.getOrNull()

    override fun read(): SyncBackend.Remote? {
        val folder = vaultFolder(create = false) ?: return null
        val vault = folder.findFile(VAULT_FILE) ?: return null
        val stream = context.contentResolver.openInputStream(vault.uri) ?: throw SyncFolderUnavailable()
        val data = stream.use { it.readAtMost() } ?: throw VaultException(KakeyException.CorruptVault())
        val device = folder.findFile(METADATA_FILE)?.let { file ->
            runCatching {
                context.contentResolver.openInputStream(file.uri)?.use {
                    JSONObject(it.readBytes().decodeToString()).optString("deviceName")
                }
            }.getOrNull()
        }
        return SyncBackend.Remote(data, vault.version(), device)
    }

    override fun write(data: ByteArray, vaultUpdatedAt: Instant, deviceName: String, expecting: RemoteExpectation): CoreRemoteVersion? {
        val folder = vaultFolder(create = true) ?: throw SyncFolderUnavailable()
        val vault = writeFile(folder, VAULT_FILE, "application/octet-stream", data)
        val metadata = JSONObject()
            .put("schemaVersion", 1)
            .put("deviceName", deviceName)
            .put("vaultUpdatedAt", vaultUpdatedAt.toString())
            .put("savedAt", Instant.now().toString())
        writeFile(folder, METADATA_FILE, "application/json", metadata.toString().encodeToByteArray())
        return vault.version()
    }

    private fun DocumentFile.version(): CoreRemoteVersion? =
        lastModified().takeIf { it > 0 }?.let { CoreRemoteVersion.ModifiedAt(Instant.ofEpochMilli(it)) }

    private fun root(): DocumentFile =
        DocumentFile.fromTreeUri(context, folderUri.toUri())?.takeIf { it.canRead() } ?: throw SyncFolderUnavailable()

    private fun vaultFolder(create: Boolean): DocumentFile? {
        val root = root()
        if (root.name == DEFAULT_FOLDER || root.findFile(VAULT_FILE) != null) return root
        return root.findFile(DEFAULT_FOLDER)?.takeIf { it.isDirectory }
            ?: if (create) root.createDirectory(DEFAULT_FOLDER) else null
    }

    private fun writeFile(folder: DocumentFile, name: String, mimeType: String, data: ByteArray): DocumentFile {
        val file = folder.findFile(name) ?: folder.createFile(mimeType, name) ?: throw SyncFolderUnavailable()
        // "wt": truncate, then write over the old contents
        context.contentResolver.openOutputStream(file.uri, "wt")?.use { it.write(data) } ?: throw SyncFolderUnavailable()
        return folder.findFile(name) ?: file
    }

    private companion object {
        const val VAULT_FILE = "vault.kakeyvault"
        const val METADATA_FILE = "vault.metadata.json"
        const val DEFAULT_FOLDER = "Kakey"
    }
}

/**
 * Backend factory for the production app: folders go through SAF (after the user picks one, [takePermission] obtains a
 * persistable read/write grant that survives restarts); cloud storage executes core requests with OkHttp and keeps the
 * connection blob in a Keystore-encrypted file.
 */
class SafSyncBackends(private val context: Context, private val userAgent: String) : SyncBackends {
    private val executor = OkHttpExecutor()

    override val connections: CloudConnectionStore = KeystoreCloudConnectionStore(context)
    override val cloudSetup = CloudSetup(executor, userAgent)

    override fun folder(folderUri: String): SyncBackend = FolderSyncBackend(context, folderUri)

    override fun cloud(folder: String, connections: CloudConnectionStore): SyncBackend =
        CloudSyncBackend(folder, connections, executor, userAgent)

    fun takePermission(uri: Uri) {
        context.contentResolver.takePersistableUriPermission(
            uri,
            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
        )
    }
}
