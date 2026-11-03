package com.gicek.kakey.android.domain

import com.gicek.kakey.android.core.VaultContents
import com.gicek.kakey.android.core.VaultException
import com.gicek.kakey.android.core.toContents
import com.gicek.kakey.android.core.toCore
import com.gicek.kakey.core.CoreEnvelopeInfo
import com.gicek.kakey.core.CoreVaultContents
import com.gicek.kakey.core.KakeyException
import com.gicek.kakey.core.coreAdoptPinned
import com.gicek.kakey.core.coreVaultCreate
import com.gicek.kakey.core.coreVaultEnvelopeInfo
import com.gicek.kakey.core.coreVaultOpen
import com.gicek.kakey.core.coreVaultReseal
import com.gicek.kakey.core.coreVaultUnlock
import java.time.Instant

/**
 * Reads and writes the local encrypted vault (the counterpart of Apple's `VaultPersistenceService`): the envelope format, key
 * derivation and encryption all live in the core; this only orchestrates files and core calls. Argon2id is slow, so callers
 * run on a background thread.
 *
 * @param favoritesName Name of the category that pinned entries join when importing an Authenticator backup, in the current
 *   UI language (docs/TECHNICAL.md; Apple uses `L10n.tr("Favorites")`).
 */
class VaultRepository(private val files: VaultFiles, private val now: () -> Instant, private val favoritesName: () -> String) {
    data class Unlocked(val contents: VaultContents, val key: ByteArray)

    val vaultExists: Boolean get() = files.vaultExists

    fun encryptedData(): ByteArray = files.read()

    fun envelope(data: ByteArray): CoreEnvelopeInfo = core { coreVaultEnvelopeInfo(data) }

    /** New vault or password change: fresh random salt and the current KDF; returns the new vault key. */
    fun create(contents: VaultContents, password: String): ByteArray {
        val created = core { coreVaultCreate(password, contents.toCore(), now()) }
        files.write(created.data)
        return created.key
    }

    /** Master password unlock; on first-run restore [data] is the fetched backup (in memory only) and the local file isn't read. */
    fun unlock(password: String, data: ByteArray = readVault()): Unlocked {
        val unlocked = core { coreVaultUnlock(data, password) }
        return Unlocked(unlocked.contents.toContents(), unlocked.key)
    }

    /** Only verifies the password (before a password change), without touching the file. */
    fun verify(password: String) {
        core { coreVaultUnlock(readVault(), password) }
    }

    /** Biometric unlock: opens the current file with the stored key. */
    fun open(key: ByteArray): VaultContents = core { coreVaultOpen(readVault(), key) }.toContents()

    /**
     * Called after importing a backup file (the counterpart of Apple's `VaultContents(adoptingPinned:)`): Authenticator pinned
     * entries join the Favorites category named in the UI language and `pinnedIds` is cleared. On the rare conversion failure
     * (random number failure) returns the input unchanged.
     */
    fun adoptingPinned(contents: CoreVaultContents): CoreVaultContents {
        if (contents.pinnedIds.isEmpty()) return contents
        return runCatching { coreAdoptPinned(contents, favoritesName()) }.getOrDefault(contents)
    }

    /**
     * Saves while unlocked: keeps the existing envelope's salt, KDF metadata and creation time, and only changes the nonce.
     * The core's reseal first opens the current file with this key to verify it, and on mismatch reports `InvalidPassword` and
     * writes nothing (docs/SECURITY.md): if the file was replaced by another vault (password change, download) and the key
     * didn't follow, no ciphertext that nobody can open gets written. No separate pre-check is needed here.
     */
    fun save(contents: VaultContents, key: ByteArray) {
        val data = core { coreVaultReseal(readVault(), key, contents.toCore(), now()) }
        files.write(data)
    }

    /** Replaces the local file with the version from the backup location (after validating it is a parseable envelope). */
    fun replace(data: ByteArray): CoreEnvelopeInfo {
        val info = envelope(data)
        files.write(data)
        return info
    }

    fun deleteAll() = files.deleteAll()

    private fun readVault(): ByteArray = try {
        files.read()
    } catch (error: Exception) {
        throw VaultException(KakeyException.CorruptVault())
    }

    private inline fun <T> core(body: () -> T): T = try {
        body()
    } catch (error: KakeyException) {
        throw VaultException(error)
    }
}
