package com.gicek.kakey.android.data

import android.content.Context
import android.util.AtomicFile
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import com.gicek.kakey.android.domain.BackupHistoryItem
import com.gicek.kakey.android.domain.BackupHistoryStore
import com.gicek.kakey.android.domain.Preferences
import com.gicek.kakey.android.domain.PreferencesStore
import com.gicek.kakey.android.domain.VaultFiles
import com.gicek.kakey.core.coreVaultIsValidEnvelope
import java.io.File
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * The local encrypted vault file `files/Kakey/vault.json` (same name and format as on Apple). Writes replace it atomically via
 * [AtomicFile], first keeping the current parseable version as `vault.last-known-good.json`. It lives in the app's private
 * directory and is excluded from Android cloud backup (data_extraction_rules).
 */
class FileVaultFiles(private val directory: File) : VaultFiles {
    constructor(context: Context) : this(File(context.filesDir, "Kakey"))

    private val vault = File(directory, "vault.json")
    private val lastKnownGood = File(directory, "vault.last-known-good.json")

    override val vaultExists: Boolean get() = vault.exists()

    override fun read(): ByteArray = AtomicFile(vault).readFully()

    override fun write(data: ByteArray) {
        directory.mkdirs()
        if (vault.exists()) {
            val current = AtomicFile(vault).readFully()
            if (coreVaultIsValidEnvelope(current)) writeAtomically(lastKnownGood, current)
        }
        writeAtomically(vault, data)
    }

    override fun deleteAll() {
        directory.deleteRecursively()
    }

    private fun writeAtomically(file: File, data: ByteArray) {
        val atomic = AtomicFile(file)
        val stream = atomic.startWrite()
        try {
            stream.write(data)
            atomic.finishWrite(stream)
        } catch (error: Exception) {
            atomic.failWrite(stream)
            throw error
        }
    }
}

private val Context.settingsDataStore by preferencesDataStore(name = "settings")

/**
 * Non-sensitive settings (Preferences DataStore, stored as a single JSON value; codec in [PreferencesCodec]).
 * Read once in a coroutine at startup without blocking the main thread; later writes happen in the background.
 */
class DataStorePreferencesStore(private val context: Context, private val scope: CoroutineScope) : PreferencesStore {
    private val key = stringPreferencesKey("preferences.v1")

    override suspend fun load(): Preferences = context.settingsDataStore.data.first()[key]?.let(PreferencesCodec::decode) ?: Preferences()

    override fun save(preferences: Preferences) {
        val json = PreferencesCodec.encode(preferences)
        scope.launch { context.settingsDataStore.edit { it[key] = json } }
    }

    override fun clear() {
        scope.launch { context.settingsDataStore.edit { it.clear() } }
    }
}

/** Backup history in `files/Kakey/backup-history.json`; plaintext holds only time, device name, size and source ([BackupHistoryCodec]). */
class FileBackupHistoryStore(context: Context, private val io: CoroutineDispatcher) : BackupHistoryStore {
    private val file = File(File(context.filesDir, "Kakey"), "backup-history.json")

    override suspend fun load(): List<BackupHistoryItem> = withContext(io) {
        runCatching { BackupHistoryCodec.decode(file.readText()) }.getOrDefault(emptyList())
    }

    override suspend fun save(items: List<BackupHistoryItem>) = withContext(io) {
        file.parentFile?.mkdirs()
        file.writeText(BackupHistoryCodec.encode(items))
    }

    override suspend fun clear() = withContext(io) {
        file.delete()
        Unit
    }
}
