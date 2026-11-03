package com.gicek.kakey.android.platform

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import com.gicek.kakey.android.domain.DropboxAppAuthenticator
import com.gicek.kakey.android.domain.DropboxAppResult
import com.gicek.kakey.core.CoreDropboxAppRequest
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CompletableDeferred

/**
 * Authorization through the official Dropbox Android app. The protocol matches the official SDK (dropbox-sdk-java's
 * `AuthActivity` / `DropboxAuthIntent`, MIT), but the SDK is not used: it only exposes the whole sign-in flow, exchanging
 * tokens over the network and keeping the PKCE verifier itself, which would break the rule that only the core builds
 * requests. This only sends the intent and receives the result; `state` validation and the token exchange are in the core
 * (`complete_dropbox_app`).
 *
 * The request goes only to a `com.dropbox.android` signed with Dropbox's production certificate, so another app posing as it
 * never receives the authorization request. Results come back through [OAuthRedirectActivity] and are passed on only when
 * `state` belongs to this sign-in. The protocol is undocumented; if an app update means it can't be launched, returns null
 * and the caller falls back to browser authorization.
 */
class OfficialDropboxAppAuthenticator(private val context: Context) : DropboxAppAuthenticator {
    override suspend fun authenticate(request: CoreDropboxAppRequest, accepts: (String) -> Boolean): DropboxAppResult? {
        if (!isOfficialAppInstalled()) return null
        val intent = Intent(ACTION_AUTHENTICATE_V2).setPackage(DROPBOX_PACKAGE).apply {
            putExtra(EXTRA_CONSUMER_KEY, request.appKey)
            putExtra(EXTRA_CONSUMER_SIG, "")
            putExtra(EXTRA_CALLING_CLASS, OAuthRedirectActivity::class.java.name)
            putExtra(EXTRA_CALLING_PACKAGE, context.packageName)
            putExtra(EXTRA_AUTH_STATE, request.authState)
            putExtra(EXTRA_AUTH_QUERY_PARAMS, request.queryParams)
            putExtra(EXTRA_ALREADY_AUTHED_UIDS, emptyArray<String>())
            putExtra(EXTRA_SDK_VERSION, SDK_PROTOCOL_VERSION)
            putExtra(EXTRA_TARGET_SDK_VERSION, context.applicationInfo.targetSdkVersion)
            if (context !is Activity) addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return try {
            DropboxAppCallbacks.await(accepts) { context.startActivity(intent) }
        } catch (_: ActivityNotFoundException) {
            null
        } catch (_: SecurityException) {
            null
        }
    }

    /**
     * The official app is installed, handles the authorization action, and its signing certificates (including rotation
     * history) include Dropbox's production certificate.
     */
    private fun isOfficialAppInstalled(): Boolean {
        val manager = context.packageManager
        val handlers = manager.queryIntentActivities(Intent(ACTION_AUTHENTICATE_V2).setPackage(DROPBOX_PACKAGE), 0)
        if (handlers.size != 1) return false
        val signing = try {
            manager.getPackageInfo(DROPBOX_PACKAGE, PackageManager.GET_SIGNING_CERTIFICATES).signingInfo
        } catch (_: PackageManager.NameNotFoundException) {
            null
        } ?: return false
        val certificates = if (signing.hasMultipleSigners()) signing.apkContentsSigners else signing.signingCertificateHistory
        val digest = MessageDigest.getInstance("SHA-256")
        return certificates.orEmpty().any { certificate ->
            digest.digest(certificate.toByteArray()).joinToString("") { "%02x".format(it) } == DROPBOX_CERTIFICATE_SHA256
        }
    }

    internal companion object {
        const val DROPBOX_PACKAGE = "com.dropbox.android"
        const val ACTION_AUTHENTICATE_V2 = "com.dropbox.android.AUTHENTICATE_V2"

        /**
         * SHA-256 of Dropbox's production signing certificate (CN=Tom Meyer, O=Dropbox, 2010–2040), taken from
         * `DROPBOX_APP_SIGNATURES` in the official SDK's `DbxOfficialAppConnector` and cross-checked against `apksigner` output
         * for the Google Play build 494.2.2. The "Android Debug" certificate the SDK also lists is not trusted.
         */
        const val DROPBOX_CERTIFICATE_SHA256 = "3467b909be2a577043bb77406388320df882276c937d09689c4d894193984c01"

        /** SDK version reported to the app; the app uses it to decide which protocol the caller supports. */
        const val SDK_PROTOCOL_VERSION = "7.0.0"

        const val EXTRA_CONSUMER_KEY = "CONSUMER_KEY"
        const val EXTRA_CONSUMER_SIG = "CONSUMER_SIG"
        const val EXTRA_CALLING_CLASS = "CALLING_CLASS"
        const val EXTRA_CALLING_PACKAGE = "CALLING_PACKAGE"
        const val EXTRA_AUTH_STATE = "AUTH_STATE"
        const val EXTRA_AUTH_QUERY_PARAMS = "AUTH_QUERY_PARAMS"
        const val EXTRA_ALREADY_AUTHED_UIDS = "ALREADY_AUTHED_UIDS"
        const val EXTRA_SDK_VERSION = "DROPBOX_SDK_JAVA_VERSION"
        const val EXTRA_TARGET_SDK_VERSION = "TARGET_SDK_VERSION"
        const val EXTRA_ACCESS_TOKEN = "ACCESS_TOKEN"
        const val EXTRA_ACCESS_SECRET = "ACCESS_SECRET"
    }
}

/**
 * In-process result relay: only one app authorization is awaited at a time; results whose `state` doesn't belong to it are
 * dropped (same approach as [OAuthCallbacks]).
 */
object DropboxAppCallbacks {
    private class Pending(val accepts: (String) -> Boolean, val result: CompletableDeferred<DropboxAppResult>)

    private val pending = AtomicReference<Pending?>(null)

    /**
     * Registers before launching the app so the result can't arrive before registration; cancellation (the user taps cancel)
     * unregisters.
     */
    suspend fun await(accepts: (String) -> Boolean, open: () -> Unit): DropboxAppResult {
        val waiting = Pending(accepts, CompletableDeferred())
        pending.getAndSet(waiting)?.result?.cancel()
        try {
            open()
            return waiting.result.await()
        } finally {
            pending.compareAndSet(waiting, null)
        }
    }

    /** Delivers [intent] and returns true when it is a Dropbox app result belonging to the pending authorization. */
    fun deliver(intent: Intent): Boolean {
        val state = intent.getStringExtra(OfficialDropboxAppAuthenticator.EXTRA_AUTH_STATE) ?: return false
        val waiting = pending.get() ?: return false
        if (!waiting.accepts(state)) return false
        val result = DropboxAppResult(
            tokenType = intent.getStringExtra(OfficialDropboxAppAuthenticator.EXTRA_ACCESS_TOKEN).orEmpty(),
            code = intent.getStringExtra(OfficialDropboxAppAuthenticator.EXTRA_ACCESS_SECRET).orEmpty(),
            state = state,
        )
        return waiting.result.complete(result)
    }
}
