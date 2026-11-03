package com.gicek.kakey.android.data

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import com.gicek.kakey.android.domain.BiometricKeyInvalidated
import com.gicek.kakey.android.domain.VaultKeyStore
import java.io.File
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.spec.MGF1ParameterSpec
import java.security.spec.X509EncodedKeySpec
import javax.crypto.Cipher
import javax.crypto.spec.OAEPParameterSpec
import javax.crypto.spec.PSource
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Keeps the vault key for biometric quick unlock (see docs/SECURITY.md).
 *
 * An RSA key pair is generated in Android Keystore: the private key is non-exportable, requires strong biometric
 * authentication (`BIOMETRIC_STRONG`) before each use, and is permanently invalidated by the system when a fingerprint or
 * face is added or removed. The vault key is wrapped with the public key using RSA-OAEP and stored in the app's private
 * directory.
 *
 * An asymmetric key is used instead of AES so that wrapping (refreshing after a master password unlock, re-storing after a
 * password change) needs only the public key and never prompts (matching iOS Keychain access); only unwrapping requires user
 * authentication. The rationale is in docs/SECURITY.md.
 */
class KeystoreVaultKeyStore(context: Context, private val io: CoroutineDispatcher = Dispatchers.IO) : VaultKeyStore {
    private val wrapped = File(File(context.noBackupFilesDir, "Kakey"), "biometric-key.bin")
    private val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }

    override fun save(key: ByteArray) {
        val publicKey = keyStore.getCertificate(ALIAS)?.publicKey ?: generate()
        // The public key object returned by Keystore can't be used with a software Cipher directly; rebuild it from its encoding
        val portable = KeyFactory.getInstance("RSA").generatePublic(X509EncodedKeySpec(publicKey.encoded))
        val cipher = Cipher.getInstance(TRANSFORMATION).apply { init(Cipher.ENCRYPT_MODE, portable, OAEP) }
        wrapped.parentFile?.mkdirs()
        wrapped.writeBytes(cipher.doFinal(key))
    }

    override fun hasKey(): Boolean = wrapped.exists() && keyStore.containsAlias(ALIAS)

    override fun remove() {
        wrapped.delete()
        if (keyStore.containsAlias(ALIAS)) keyStore.deleteEntry(ALIAS)
    }

    /**
     * Keystore queries, private key lookup, `Cipher.init` and file reads are all IPC / IO and run on [io]; only [authenticate]
     * (BiometricPrompt) runs on the caller's thread (the main thread).
     */
    override suspend fun load(authenticate: suspend (Cipher) -> Cipher): ByteArray {
        val cipher = withContext(io) {
            if (!hasKey()) throw BiometricKeyInvalidated()
            try {
                Cipher.getInstance(TRANSFORMATION).apply { init(Cipher.DECRYPT_MODE, keyStore.getKey(ALIAS, null) as PrivateKey, OAEP) }
            } catch (error: KeyPermanentlyInvalidatedException) {
                remove()
                throw BiometricKeyInvalidated()
            }
        }
        val unlocked = authenticate(cipher)
        return withContext(io) { unlocked.doFinal(wrapped.readBytes()) }
    }

    private fun generate() = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_RSA, ANDROID_KEYSTORE).apply {
        initialize(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_DECRYPT or KeyProperties.PURPOSE_ENCRYPT)
                .setKeySize(RSA_KEY_BITS)
                .setDigests(KeyProperties.DIGEST_SHA256, KeyProperties.DIGEST_SHA1)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_RSA_OAEP)
                .setUserAuthenticationRequired(true)
                .setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG)
                .setInvalidatedByBiometricEnrollment(true)
                .build(),
        )
    }.generateKeyPair().public

    private companion object {
        const val RSA_KEY_BITS = 2048
        const val ANDROID_KEYSTORE = "AndroidKeyStore"
        const val ALIAS = "com.gicek.kakey.vault-key"
        const val TRANSFORMATION = "RSA/ECB/OAEPPadding"

        // Keystore OAEP decryption only supports MGF1-SHA1, so both sides spell out the same parameters
        val OAEP = OAEPParameterSpec("SHA-256", "MGF1", MGF1ParameterSpec.SHA1, PSource.PSpecified.DEFAULT)
    }
}
