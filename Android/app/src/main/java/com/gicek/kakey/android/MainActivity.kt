package com.gicek.kakey.android

import android.os.Bundle
import android.view.WindowManager
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import androidx.fragment.app.FragmentActivity
import com.gicek.kakey.android.domain.Phase
import com.gicek.kakey.android.ui.KakeyApp

/**
 * The only Activity. It extends FragmentActivity so BiometricPrompt works; all UI is Compose.
 * `FLAG_SECURE` (hides verification codes in the Recents preview and blocks screenshots) is set only while the home screen
 * or account detail is showing (see [setSecure] and docs/SECURITY.md). Onboarding, lock, settings and other screens show no
 * codes or secrets, so they can be captured and appear normally in Recents.
 */
class MainActivity : FragmentActivity() {
    /** The demo vault (Debug builds only) is used for screenshot reviews, so no screen sets FLAG_SECURE. */
    private var demo = false

    /** Turned on while the home screen shows and off when leaving it or locking; the account detail bottom sheet inherits it. */
    fun setSecure(secure: Boolean) {
        if (secure && !demo) {
            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        val splash = installSplashScreen()
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val app = application as KakeyApplication
        // Settings and vault existence are read in the background; keep the splash up until then to avoid a blank flash
        splash.setKeepOnScreenCondition { app.store.state.value.phase == Phase.LOADING }
        demo = DemoVault.start(app, intent)
        setContent { KakeyApp(app.store, app.syncBackends) }
    }

    /**
     * The system calls this first when the main window receives a touch or key: it counts as activity and restarts the
     * auto-lock timer. Compose dialogs, bottom sheets and the system keyboard are separate windows that bypass this; the
     * first interaction with the main window after they close catches up.
     */
    override fun onUserInteraction() {
        super.onUserInteraction()
        (application as KakeyApplication).store.noteUserActivity()
    }
}
