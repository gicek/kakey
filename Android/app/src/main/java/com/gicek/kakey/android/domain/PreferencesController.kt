package com.gicek.kakey.android.domain

import com.gicek.kakey.android.R
import com.gicek.kakey.android.core.UiText
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.withContext

/**
 * Settings changes and biometric key keeping. The atomic read-modify-write of settings itself is in
 * [VaultSession.updatePreferences], because sync downloads also change settings on the `files` thread.
 */
internal class PreferencesController(private val session: VaultSession) {
    fun setAppearance(mode: AppearanceMode) = session.updatePreferences { it.copy(appearance = mode) }

    fun setAutoLock(mode: AutoLockMode) = session.updatePreferences { it.copy(autoLock = mode) }

    suspend fun setBiometricsEnabled(enabled: Boolean) {
        session.updatePreferences { it.copy(biometricsEnabled = enabled) }
        if (enabled) {
            storeBiometricKey()
        } else {
            withContext(session.io) { session.keyStore.remove() }
            session.state.update { it.copy(biometricKeyAvailable = false) }
        }
    }

    /**
     * Re-stores the biometric key in the background using a copy of the current key (RSA key generation can take hundreds of
     * milliseconds).
     */
    suspend fun storeBiometricKey() {
        val key = session.key?.copyOf() ?: return
        try {
            withContext(session.io) { saveBiometricKey(key) }
        } finally {
            key.fill(0)
        }
    }

    /** Call on a background thread. */
    fun saveBiometricKey(key: ByteArray) {
        try {
            session.keyStore.save(key)
            session.state.update { it.copy(biometricKeyAvailable = true) }
        } catch (error: Exception) {
            session.state.update { it.copy(biometricKeyAvailable = false) }
            session.message(UiText.Res(R.string.unlock_once_with_your_master_password, session.biometricName))
        }
    }
}
