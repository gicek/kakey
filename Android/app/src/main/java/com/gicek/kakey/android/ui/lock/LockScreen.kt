package com.gicek.kakey.android.ui.lock

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Fingerprint
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.gicek.kakey.android.R
import com.gicek.kakey.android.core.text
import com.gicek.kakey.android.platform.Biometrics
import com.gicek.kakey.android.ui.LocalStore
import com.gicek.kakey.android.ui.components.BrandBadge
import com.gicek.kakey.android.ui.components.PasswordField
import com.gicek.kakey.android.ui.components.icon
import com.gicek.kakey.android.ui.components.nameRes
import com.gicek.kakey.android.ui.components.rememberBiometricKind
import com.gicek.kakey.android.ui.components.rememberNow
import com.gicek.kakey.android.ui.components.unlockTitleRes
import com.gicek.kakey.android.ui.findActivity
import kotlinx.coroutines.launch

/**
 * Lock screen: unlock with the master password or biometrics; prompts for biometrics once on appearance, staying on password
 * entry if canceled.
 */
@Composable
fun LockScreen() {
    val store = LocalStore.current
    val state by store.state.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var password by remember { mutableStateOf("") }
    val focus = remember { FocusRequester() }
    val canUseBiometrics = state.preferences.biometricsEnabled && state.biometricKeyAvailable
    val now = rememberNow()
    // Recomputed every second with now; the wait runs on the monotonic clock, so changing system time can't end it early
    val lockout = remember(now) { store.lockoutRemaining() }

    val title = stringResource(R.string.unlock_kakey_5789)
    val negative = stringResource(R.string.use_master_password)
    val biometricKind = rememberBiometricKind()
    val biometricName = stringResource(biometricKind.nameRes)
    fun unlockWithBiometrics() {
        scope.launch {
            store.unlockWithBiometrics { cipher -> Biometrics.unlock(context.findActivity(), cipher, title, "", negative) }
        }
    }
    fun unlock() {
        if (password.isEmpty()) return
        scope.launch {
            store.unlock(password)
            // Clear only on a successful unlock; keep it after a wrong attempt so it's easy to fix
            if (store.state.value.phase != com.gicek.kakey.android.domain.Phase.LOCKED) password = ""
        }
    }

    // Only the lock screen at launch auto-prompts for biometrics once; after any lock while running (manual, auto, screen off)
    // it just focuses the password field
    LaunchedEffect(Unit) {
        if (canUseBiometrics && !state.autoBiometricSuppressed) unlockWithBiometrics() else runCatching { focus.requestFocus() }
    }

    Box(Modifier.fillMaxSize().safeDrawingPadding().imePadding(), contentAlignment = Alignment.Center) {
        Column(
            Modifier.widthIn(max = 420.dp).padding(24.dp).verticalScroll(rememberScrollState()),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            BrandBadge(size = 132.dp, modifier = Modifier.padding(bottom = 8.dp))
            Text(
                stringResource(R.string.kakey_is_locked),
                style = MaterialTheme.typography.headlineMedium,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                if (canUseBiometrics) {
                    stringResource(R.string.use_x_or_enter_your_master, biometricName)
                } else {
                    stringResource(R.string.enter_your_master_password_to_unlock_1c4b)
                },
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
            )
            PasswordField(
                value = password,
                onValueChange = {
                    password = it
                    store.clearUnlockError()
                },
                label = stringResource(R.string.enter_password_5705),
                enabled = lockout == null && !state.isWorking,
                isError = state.unlockError != null,
                imeAction = ImeAction.Go,
                onDone = ::unlock,
                modifier = Modifier.focusRequester(focus),
            )
            Button(
                onClick = ::unlock,
                enabled = password.isNotEmpty() && lockout == null && !state.isWorking,
                modifier = Modifier.fillMaxWidth().height(56.dp),
            ) {
                if (state.isWorking) {
                    CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp, color = MaterialTheme.colorScheme.onPrimary)
                } else {
                    Text(stringResource(R.string.unlock))
                }
            }
            if (canUseBiometrics) {
                FilledTonalButton(onClick = ::unlockWithBiometrics, modifier = Modifier.fillMaxWidth().height(56.dp)) {
                    Icon(biometricKind.icon, contentDescription = null)
                    Text(stringResource(biometricKind.unlockTitleRes), Modifier.padding(start = 8.dp))
                }
            }
            when {
                lockout != null -> Text(
                    ((lockout.toMillis() + 999) / 1000).toInt().let {
                        pluralStringResource(R.plurals.too_many_attempts_try_again_in, it, it)
                    },
                    color = MaterialTheme.colorScheme.tertiary,
                    style = MaterialTheme.typography.bodySmall,
                    textAlign = TextAlign.Center,
                )
                state.unlockError != null -> Text(
                    state.unlockError!!.text(),
                    color = MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.bodySmall,
                    textAlign = TextAlign.Center,
                )
            }
        }
    }
}
