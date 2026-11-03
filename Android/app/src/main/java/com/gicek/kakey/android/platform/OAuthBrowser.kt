package com.gicek.kakey.android.platform

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.core.net.toUri
import com.gicek.kakey.android.MainActivity
import com.gicek.kakey.android.domain.WebAuthenticator
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CompletableDeferred

/**
 * OAuth sign-in (docs/TECHNICAL.md): opens the sign-in page in a Custom Tab; the redirect comes back through
 * [OAuthRedirectActivity].
 *
 * androidx.browser is not used: a Custom Tab is just `ACTION_VIEW` with `customtabs.extra.SESSION`; supporting browsers open it
 * as a Custom Tab and others as a normal page, with the same flow. Another app could register the redirect scheme: PKCE
 * ensures an intercepted authorization code can't be exchanged for a token, and only redirects the core judges to belong to
 * this sign-in (matching `state`) are handed back.
 */
class CustomTabAuthenticator(private val context: Context) : WebAuthenticator {
    override suspend fun authenticate(url: String, accepts: (String) -> Boolean): String = OAuthCallbacks.await(accepts) {
        val intent = Intent(Intent.ACTION_VIEW, url.toUri()).apply {
            putExtras(Bundle().apply { putBinder(EXTRA_CUSTOM_TABS_SESSION, null) })
            if (context !is Activity) addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        context.startActivity(intent)
    }

    private companion object {
        const val EXTRA_CUSTOM_TABS_SESSION = "android.support.customtabs.extra.SESSION"
    }
}

/** In-process redirect relay: only one sign-in is awaited at a time; redirects that don't belong to it are dropped. */
object OAuthCallbacks {
    private class Pending(val accepts: (String) -> Boolean, val result: CompletableDeferred<String>)

    private val pending = AtomicReference<Pending?>(null)

    /**
     * Registers before opening the browser so the redirect can't arrive before registration; cancellation (the user gives up)
     * unregisters.
     */
    suspend fun await(accepts: (String) -> Boolean, open: () -> Unit): String {
        val waiting = Pending(accepts, CompletableDeferred())
        pending.getAndSet(waiting)?.result?.cancel()
        try {
            open()
            return waiting.result.await()
        } finally {
            pending.compareAndSet(waiting, null)
        }
    }

    /** Delivers the redirect and returns true when it belongs to the pending sign-in. */
    fun deliver(url: String): Boolean {
        val waiting = pending.get() ?: return false
        return waiting.accepts(url) && waiting.result.complete(url)
    }
}

/**
 * Transparent Activity receiving OAuth redirects (the manifest registers each provider's scheme from `cloud-keys.toml`):
 * browser redirects (URLs) go to [OAuthCallbacks], and results from the official Dropbox app (extras) go to
 * [DropboxAppCallbacks]. It then returns to the app (`CLEAR_TOP` dismisses the Custom Tab) and finishes immediately without
 * appearing in Recents.
 */
class OAuthRedirectActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        intent?.let { received ->
            if (received.hasExtra(OfficialDropboxAppAuthenticator.EXTRA_AUTH_STATE)) {
                DropboxAppCallbacks.deliver(received)
            } else {
                received.data?.toString()?.let(OAuthCallbacks::deliver)
            }
        }
        startActivity(
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP),
        )
        finish()
    }
}
