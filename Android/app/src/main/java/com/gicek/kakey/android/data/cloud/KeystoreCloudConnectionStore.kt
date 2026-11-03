package com.gicek.kakey.android.data.cloud

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import com.gicek.kakey.android.domain.CloudConnectionStore
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Keeps the cloud storage connection blob: a non-exportable AES-256-GCM key in Keystore (no user authentication required,
 * since background auto-sync and the first restore before unlock both need it) encrypts it into
 * `noBackupFilesDir/Kakey/cloud-connection.bin` (excluded from cloud backup and device transfer).
 * File format: 12-byte IV + ciphertext (including the 16-byte tag). If it can't be read (corrupt file, key wiped by the
 * system), it is treated as no connection and deleted.
 */
class KeystoreCloudConnectionStore(context: Context) : CloudConnectionStore {
    private val file = File(File(context.noBackupFilesDir, "Kakey"), "cloud-connection.bin")
    private val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }

    override fun load(): ByteArray? {
        if (!file.exists()) return null
        return runCatching {
            val bytes = file.readBytes()
            val key = keyStore.getKey(ALIAS, null) as? SecretKey ?: error("missing key")
            Cipher.getInstance(TRANSFORMATION).run {
                init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(TAG_BITS, bytes, 0, IV_BYTES))
                doFinal(bytes, IV_BYTES, bytes.size - IV_BYTES)
            }
        }.getOrElse {
            remove()
            null
        }
    }

    override fun save(connection: ByteArray) {
        val key = keyStore.getKey(ALIAS, null) as? SecretKey ?: generate()
        val cipher = Cipher.getInstance(TRANSFORMATION).apply { init(Cipher.ENCRYPT_MODE, key) }
        val sealed = cipher.iv + cipher.doFinal(connection)
        file.parentFile?.mkdirs()
        val temporary = File(file.parentFile, "${file.name}.tmp")
        temporary.writeBytes(sealed)
        if (!temporary.renameTo(file)) {
            temporary.delete()
            error("cannot replace ${file.name}")
        }
    }

    override fun remove() {
        file.delete()
        if (keyStore.containsAlias(ALIAS)) keyStore.deleteEntry(ALIAS)
    }

    private fun generate(): SecretKey = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE).apply {
        init(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setKeySize(AES_KEY_BITS)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build(),
        )
    }.generateKey()

    private companion object {
        const val ANDROID_KEYSTORE = "AndroidKeyStore"
        const val ALIAS = "com.gicek.kakey.cloud-connection-key"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val AES_KEY_BITS = 256
        const val TAG_BITS = 128
        const val IV_BYTES = 12
    }
}
