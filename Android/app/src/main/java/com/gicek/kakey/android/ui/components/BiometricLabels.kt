package com.gicek.kakey.android.ui.components

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Face
import androidx.compose.material.icons.outlined.Fingerprint
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import com.gicek.kakey.android.R
import com.gicek.kakey.android.platform.BiometricKind
import com.gicek.kakey.android.platform.Biometrics

/** The name used mid-sentence ("Use %s or enter your master password to unlock", ...). */
val BiometricKind.nameRes: Int
    get() = when (this) {
        BiometricKind.FINGERPRINT -> R.string.fingerprint
        BiometricKind.FACE -> R.string.face
        BiometricKind.GENERIC -> R.string.biometrics
    }

/** Full title for switches and buttons: Chinese can't fit the name into a template with spaces, so each is its own string. */
val BiometricKind.unlockTitleRes: Int
    get() = when (this) {
        BiometricKind.FINGERPRINT -> R.string.unlock_with_fingerprint
        BiometricKind.FACE -> R.string.unlock_with_face
        BiometricKind.GENERIC -> R.string.unlock_with_biometrics
    }

val BiometricKind.icon: ImageVector
    get() = if (this == BiometricKind.FACE) Icons.Outlined.Face else Icons.Outlined.Fingerprint

/** The device's biometric kind, probed only once in the UI. */
@Composable
fun rememberBiometricKind(): BiometricKind {
    val context = LocalContext.current
    return remember { Biometrics.kind(context) }
}
