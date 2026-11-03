package com.gicek.kakey.android.platform

import android.content.Context
import android.content.pm.PackageManager
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_STRONG
import androidx.biometric.BiometricManager.Authenticators.DEVICE_CREDENTIAL
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import com.gicek.kakey.android.domain.BiometricCancelled
import com.gicek.kakey.android.domain.BiometricFailed
import javax.crypto.Cipher
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.suspendCancellableCoroutine

/**
 * The device's biometric kind, which decides what the UI calls it: a specific name when only fingerprint or only face is
 * enrolled; "biometrics" when both are present or it can't be determined. The strong-biometric check doesn't say which kind
 * qualified, so the UI must not promise a method the user may not be able to use.
 */
enum class BiometricKind { FINGERPRINT, FACE, GENERIC }

/** Coroutine wrapper for BiometricPrompt. Prompt text is passed in by the caller (in the in-app language). */
object Biometrics {
    fun kind(context: Context): BiometricKind {
        val packages = context.packageManager
        val fingerprint = packages.hasSystemFeature(PackageManager.FEATURE_FINGERPRINT)
        val face = packages.hasSystemFeature(PackageManager.FEATURE_FACE)
        return when {
            fingerprint && !face -> BiometricKind.FINGERPRINT
            face && !fingerprint -> BiometricKind.FACE
            else -> BiometricKind.GENERIC
        }
    }

    /** The device supports and has enrolled strong biometrics (fingerprint / face). */
    fun isAvailable(context: Context): Boolean =
        BiometricManager.from(context).canAuthenticate(BIOMETRIC_STRONG) == BiometricManager.BIOMETRIC_SUCCESS

    /**
     * Unlocks the vault: strong biometrics only, with the negative button returning to the master password. Returns the
     * unlocked [cipher] on success.
     */
    suspend fun unlock(activity: FragmentActivity, cipher: Cipher, title: String, subtitle: String, negative: String): Cipher {
        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle(title)
            .setSubtitle(subtitle)
            .setNegativeButtonText(negative)
            .setAllowedAuthenticators(BIOMETRIC_STRONG)
            .setConfirmationRequired(false)
            .build()
        val result = authenticate(activity, info, BiometricPrompt.CryptoObject(cipher))
        return result.cryptoObject?.cipher ?: throw BiometricFailed("")
    }

    /**
     * The device can verify the owner (strong biometrics enrolled or a screen lock set); without either [verifyOwner] can't
     * prompt and the caller falls back to a confirmation dialog.
     */
    fun canVerifyOwner(context: Context): Boolean =
        BiometricManager.from(context).canAuthenticate(BIOMETRIC_STRONG or DEVICE_CREDENTIAL) == BiometricManager.BIOMETRIC_SUCCESS

    /**
     * Re-verifies the device owner (revealing a secret, exporting a QR code, resetting the app): biometrics or the device
     * screen lock credential both work, so devices without biometrics can still complete it.
     * @return true on success; false if the user cancels; other failures throw [BiometricFailed].
     */
    suspend fun verifyOwner(activity: FragmentActivity, title: String, subtitle: String): Boolean {
        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle(title)
            .setSubtitle(subtitle)
            .setAllowedAuthenticators(BIOMETRIC_STRONG or DEVICE_CREDENTIAL)
            .build()
        return try {
            authenticate(activity, info, null)
            true
        } catch (error: BiometricCancelled) {
            false
        }
    }

    private suspend fun authenticate(
        activity: FragmentActivity,
        info: BiometricPrompt.PromptInfo,
        crypto: BiometricPrompt.CryptoObject?,
    ): BiometricPrompt.AuthenticationResult = suspendCancellableCoroutine { continuation ->
        val prompt = BiometricPrompt(
            activity,
            ContextCompat.getMainExecutor(activity),
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                    if (continuation.isActive) continuation.resume(result)
                }

                override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                    if (!continuation.isActive) return
                    val cancelled = errorCode == BiometricPrompt.ERROR_USER_CANCELED ||
                        errorCode == BiometricPrompt.ERROR_NEGATIVE_BUTTON ||
                        errorCode == BiometricPrompt.ERROR_CANCELED
                    continuation.resumeWithException(if (cancelled) BiometricCancelled() else BiometricFailed(errString.toString()))
                }

                // A single failed recognition (finger misplaced, ...) is reported by the system prompt itself, which allows a
                // retry; the flow continues
                override fun onAuthenticationFailed() = Unit
            },
        )
        if (crypto != null) prompt.authenticate(info, crypto) else prompt.authenticate(info)
        continuation.invokeOnCancellation { prompt.cancelAuthentication() }
    }
}
