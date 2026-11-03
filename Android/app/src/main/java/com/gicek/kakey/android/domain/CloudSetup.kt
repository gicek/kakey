package com.gicek.kakey.android.domain

import com.gicek.kakey.core.CoreCloudAccess
import com.gicek.kakey.core.CoreCloudEntry
import com.gicek.kakey.core.CoreCloudException
import com.gicek.kakey.core.CoreCloudOutcome
import com.gicek.kakey.core.CoreNextcloudLogin
import com.gicek.kakey.core.CoreOAuthSession
import com.gicek.kakey.core.coreCloudBeginOauth
import com.gicek.kakey.core.coreCloudConnectionInfo
import com.gicek.kakey.core.coreCloudCreateFolder
import com.gicek.kakey.core.coreCloudList
import com.gicek.kakey.core.coreCloudRevoke
import com.gicek.kakey.core.coreCloudWebdavConnection
import com.gicek.kakey.core.coreNextcloudBeginLogin
import com.gicek.kakey.core.coreNextcloudPollLogin
import java.io.IOException
import javax.net.ssl.SSLException
import kotlin.coroutines.CoroutineContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/**
 * One-off operations while connecting cloud storage (the counterpart of Apple's `CloudSetupService`): building and checking a
 * WebDAV connection, Nextcloud and OAuth sign-in, browsing and creating remote folders, and revoking on disconnect. The
 * protocols all live in the core. Connection blobs pass through here only in memory ([InMemoryCloudConnectionStore]); if a
 * token is refreshed while browsing, the new connection is written back to the same in-memory store and handed to the
 * persistent [CloudConnectionStore] only after the caller confirms.
 * Calls are blocking; run them on the IO dispatcher.
 */
class CloudSetup(private val executor: HttpExecutor, private val userAgent: String) {
    /**
     * Builds a WebDAV connection and lists the root once to confirm the address and account work. [allowInsecureHttp] is true
     * only after the user confirmed cleartext HTTP; [trustedCertificate] is passed only after the user checked the server
     * certificate fingerprint. Throws [CloudCertificateException] when the system rejects the certificate.
     */
    fun webDavConnection(
        url: String,
        username: String,
        password: String,
        allowInsecureHttp: Boolean,
        trustedCertificate: ByteArray? = null,
    ): ByteArray {
        val connection = wrapping { coreCloudWebdavConnection(url, username, password, allowInsecureHttp, trustedCertificate) }
        entries("", InMemoryCloudConnectionStore(connection))
        return connection
    }

    /**
     * First step of OAuth sign-in (Dropbox, OneDrive): the platform opens `session.url()` in a browser and passes the redirect
     * to [completeOAuth].
     */
    fun beginOAuth(provider: CloudProvider, access: CoreCloudAccess): CoreOAuthSession =
        wrapping { coreCloudBeginOauth(provider.core, access) }

    /**
     * Result returned by the official Dropbox app: the core checks `state` and the token type, then exchanges the same PKCE
     * verifier for a token.
     */
    fun completeDropboxApp(session: CoreOAuthSession, result: DropboxAppResult): ByteArray {
        val operation = wrapping { session.completeDropboxApp(result.tokenType, result.code, result.state, userAgent) }
        val outcome = runner(null).drive(operation)
        return (outcome as? CoreCloudOutcome.Connected ?: throw CloudSyncException.internal()).connection
    }

    /** The core validates the redirect (`state`), exchanges it for a token and looks up the account name; returns the new blob. */
    fun completeOAuth(session: CoreOAuthSession, callbackUrl: String): ByteArray {
        val operation = wrapping { session.complete(callbackUrl, userAgent) }
        val outcome = runner(null).drive(operation)
        return (outcome as? CoreCloudOutcome.Connected ?: throw CloudSyncException.internal()).connection
    }

    /** [trustedCertificate] as in [webDavConnection]: later polls and the connection from sign-in all pin this certificate. */
    fun beginNextcloudLogin(
        server: String,
        allowInsecureHttp: Boolean,
        trustedCertificate: ByteArray? = null,
    ): Pair<String, CoreNextcloudLogin> {
        val outcome =
            runner(null).drive(wrapping { coreNextcloudBeginLogin(server, allowInsecureHttp, trustedCertificate, userAgent) })
        val started = outcome as? CoreCloudOutcome.LoginStarted ?: throw CloudSyncException.internal()
        return started.loginUrl to started.login
    }

    /** Returns null while the user hasn't finished authorizing in the browser. */
    fun pollNextcloudLogin(login: CoreNextcloudLogin): ByteArray? {
        val outcome = runner(null).drive(coreNextcloudPollLogin(login, userAgent))
        return (outcome as? CoreCloudOutcome.LoginPolled ?: throw CloudSyncException.internal()).connection
    }

    /** Direct children of a folder (files and folders), sorted by name. */
    fun entries(path: String, connections: CloudConnectionStore): List<CoreCloudEntry> {
        val outcome = runner(connections).run { bytes, agent -> coreCloudList(bytes, path, agent) }
        val entries = (outcome as? CoreCloudOutcome.Entries ?: throw CloudSyncException.internal()).entries
        return entries.sortedBy { it.name.lowercase() }
    }

    fun createFolder(path: String, connections: CloudConnectionStore) {
        runner(connections).run { bytes, agent -> coreCloudCreateFolder(bytes, path, agent) }
    }

    /** Best-effort revocation of server-side authorization on disconnect; failure doesn't stop deleting the local credentials. */
    fun revoke(connection: ByteArray) {
        runCatching { runner(InMemoryCloudConnectionStore(connection)).run { bytes, agent -> coreCloudRevoke(bytes, agent) } }
    }

    /** Location info for display (no password). */
    fun location(connection: ByteArray, folder: String): SyncLocation.Cloud {
        val info = wrapping { coreCloudConnectionInfo(connection) }
        return SyncLocation.Cloud(
            CloudProvider.of(info.provider),
            info.host,
            info.username,
            info.isSecure,
            folder,
            isAppFolder = info.access == CoreCloudAccess.APP_FOLDER,
            isCertificatePinned = info.hasPinnedCertificate,
        )
    }

    private fun runner(connections: CloudConnectionStore?) =
        CloudOperationRunner(connections ?: InMemoryCloudConnectionStore(), executor, userAgent)

    private inline fun <T> wrapping(body: () -> T): T = try {
        body()
    } catch (error: CoreCloudException) {
        throw CloudSyncException(error)
    }
}

/**
 * Waits for the user to finish Nextcloud authorization in the browser: polls every [intervalMillis], at most [attempts] times;
 * returns the connection blob once authorized, or null on timeout. Network-level failures ([IOException], except certificate
 * errors as [SSLException]) are treated as transient and waiting continues: the app is in the background while the user
 * authorizes in the browser and the system may interrupt requests then, so ending the sign-in on the first failure would leave
 * the user with only an error on return. Explicit server rejections still throw.
 * Note that Nextcloud hands out the app password only on the first poll after authorization; later polls get 404.
 *
 * When [wake] fires (returning to the app), checks immediately instead of waiting for the interval.
 */
suspend fun CloudSetup.awaitNextcloudLogin(
    login: CoreNextcloudLogin,
    attempts: Int,
    intervalMillis: Long,
    wake: NextcloudLoginWake? = null,
    io: CoroutineContext = Dispatchers.IO,
): ByteArray? {
    repeat(attempts) {
        val woken = wake?.await(intervalMillis) ?: run {
            delay(intervalMillis)
            false
        }
        if (woken) wake?.onChecking?.invoke(true)
        val created = try {
            withContext(io) { pollNextcloudLogin(login) }
        } catch (certificate: SSLException) {
            if (woken) wake?.onChecking?.invoke(false)
            throw certificate
        } catch (_: IOException) {
            null
        }
        if (created != null) return created
        if (woken) wake?.onChecking?.invoke(false)
    }
    return null
}

/**
 * Makes a pending Nextcloud authorization check immediately ([request] on returning to the app). [onChecking] is true while
 * that immediate check runs and returns to false if not yet authorized; once authorized it stays true and the caller moves on.
 */
class NextcloudLoginWake(val onChecking: (Boolean) -> Unit) {
    private val signal = Channel<Unit>(Channel.CONFLATED)

    fun request() {
        signal.trySend(Unit)
    }

    /** Waits [timeoutMillis] or until woken; returns true when woken. */
    internal suspend fun await(timeoutMillis: Long): Boolean = withTimeoutOrNull(timeoutMillis) { signal.receive() } != null
}
