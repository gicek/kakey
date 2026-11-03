package com.gicek.kakey.android.ui

import android.content.Context
import android.content.ContextWrapper
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.platform.LocalContext
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.gicek.kakey.android.MainActivity
import com.gicek.kakey.android.data.SafSyncBackends
import com.gicek.kakey.android.domain.Phase
import com.gicek.kakey.android.domain.VaultStore
import com.gicek.kakey.android.ui.lock.LockScreen
import com.gicek.kakey.android.ui.main.MainNavigation
import com.gicek.kakey.android.ui.onboarding.OnboardingScreen
import com.gicek.kakey.android.ui.theme.KakeyTheme
import com.gicek.kakey.android.ui.theme.Motion

/** Global Snackbar for the vault's one-shot messages (added, already exists, save failed, ...). */
val LocalSnackbar = staticCompositionLocalOf { SnackbarHostState() }
val LocalStore = staticCompositionLocalOf<VaultStore> { error("VaultStore not provided") }
val LocalSyncBackends = staticCompositionLocalOf<SafSyncBackends> { error("SyncBackends not provided") }

/** Root UI: switches between onboarding, the lock screen and the main UI by lock state. */
@Composable
fun KakeyApp(store: VaultStore, syncBackends: SafSyncBackends) {
    val state by store.state.collectAsStateWithLifecycle()
    val snackbar = remember { SnackbarHostState() }
    val context = LocalContext.current
    LaunchedEffect(store) {
        store.messages.collect { snackbar.showSnackbar(it.resolve(context)) }
    }
    KakeyTheme(state.preferences.appearance) {
        CompositionLocalProvider(LocalSnackbar provides snackbar, LocalStore provides store, LocalSyncBackends provides syncBackends) {
            Surface(color = MaterialTheme.colorScheme.surface) {
                AnimatedContent(targetState = state.phase, transitionSpec = {
                    fadeIn(Motion.effects()) togetherWith
                        fadeOut(Motion.effects())
                }, label = "phase") { phase ->
                    when (phase) {
                        Phase.LOADING -> Unit // The splash screen is still on top
                        Phase.ONBOARDING -> OnboardingScreen()
                        Phase.LOCKED -> LockScreen()
                        Phase.UNLOCKED -> MainNavigation()
                    }
                }
            }
        }
    }
}

/** BiometricPrompt needs a FragmentActivity; the Compose Context may be wrapped several layers deep. */
fun Context.findActivity(): FragmentActivity {
    var context = this
    while (context is ContextWrapper) {
        if (context is FragmentActivity) return context
        context = context.baseContext
    }
    error("No FragmentActivity")
}

/**
 * While in composition, blocks screenshots and hides content in Recents ([MainActivity.setSecure]); restores on leaving
 * composition. The home screen passes whether it is on top.
 */
@Composable
fun SecureWindow(enabled: Boolean) {
    val activity = LocalContext.current.findActivity() as? MainActivity ?: return
    DisposableEffect(activity, enabled) {
        activity.setSecure(enabled)
        onDispose { activity.setSecure(false) }
    }
}
