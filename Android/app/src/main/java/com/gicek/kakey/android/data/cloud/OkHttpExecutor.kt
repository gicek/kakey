package com.gicek.kakey.android.data.cloud

import android.annotation.SuppressLint
import com.gicek.kakey.android.domain.CloudCertificateException
import com.gicek.kakey.android.domain.HttpExecutor
import com.gicek.kakey.android.domain.ServerTrustDecision
import com.gicek.kakey.core.CoreHttpHeader
import com.gicek.kakey.core.CoreHttpRequest
import com.gicek.kakey.core.CoreHttpResponse
import com.gicek.kakey.core.coreCloudMaxBodyBytes
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.security.KeyStore
import java.security.MessageDigest
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import javax.net.ssl.HostnameVerifier
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSession
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager
import okhttp3.CookieJar
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.internal.http.HttpMethod

/**
 * Executes core-built requests with OkHttp: no redirects (including HTTPS -> HTTP), no cookies, no cache, and no automatic
 * retry of a failed request. Response bodies are read up to the limit + 1 byte so the core can report "response too large".
 * HTTPS is validated by the system first; if the system rejects the certificate, the request's pinned certificate decides
 * (docs/SECURITY.md, [ServerTrustDecision]), and an unacceptable one throws [CloudCertificateException].
 */
class OkHttpExecutor(
    private val client: OkHttpClient = defaultClient(),
    private val maxBodyBytes: Long = coreCloudMaxBodyBytes().toLong(),
    private val systemTrust: X509TrustManager = systemTrustManager(),
) : HttpExecutor {
    /**
     * One derived client per pin value (including "no pin", keyed by an empty string): connections are still reused, but
     * pinned connections are never shared with other requests.
     */
    private val clients = ConcurrentHashMap<String, OkHttpClient>()

    override fun execute(request: CoreHttpRequest): CoreHttpResponse {
        val url = request.url.toHttpUrlOrNull() ?: throw IOException("invalid url")
        // GET / DELETE have no body; PUT / POST / PROPFIND / MKCOL must have one (possibly empty)
        val body = request.body.takeIf { it.isNotEmpty() || HttpMethod.requiresRequestBody(request.method) }?.toRequestBody()
        val builder = Request.Builder().url(url).method(request.method, body)
        request.headers.forEach { builder.addHeader(it.name, it.value) }
        val call = (if (url.isHttps) clientFor(request.pinnedCertificate) else client).newCall(builder.build())
        // For a synchronous call the TLS handshake runs on this thread, so the rejection reason is kept in a thread-local
        // and can't leak into another request
        PinningTrustManager.rejection.remove()
        val response = try {
            call.execute()
        } catch (failure: IOException) {
            PinningTrustManager.rejection.get()?.let { throw it }
            throw failure
        } finally {
            PinningTrustManager.rejection.remove()
        }
        response.use {
            val headers = it.headers.map { (name, value) -> CoreHttpHeader(name, value) }
            return CoreHttpResponse(it.code.toUShort(), headers, it.body.byteStream().use(::readCapped))
        }
    }

    private fun clientFor(pinned: ByteArray?): OkHttpClient = clients.getOrPut(pinned?.let(ServerTrustDecision::formatted).orEmpty()) {
        val trust = PinningTrustManager(systemTrust, pinned)
        val context = SSLContext.getInstance("TLS").apply { init(null, arrayOf(trust), null) }
        val system = client.hostnameVerifier
        // Relax hostname verification only when the leaf certificate is exactly the pinned one
        val hostnames = HostnameVerifier { host, session -> system.verify(host, session) || isPinnedLeaf(session, pinned) }
        client.newBuilder().sslSocketFactory(context.socketFactory, trust).hostnameVerifier(hostnames).build()
    }

    /** Reads at most the limit + 1 byte: the extra byte lets the core report "response too large" without buffering a huge file. */
    private fun readCapped(stream: InputStream): ByteArray {
        val out = ByteArrayOutputStream()
        val buffer = ByteArray(BUFFER_BYTES)
        while (out.size() <= maxBodyBytes) {
            val read = stream.read(buffer)
            if (read < 0) break
            out.write(buffer, 0, read)
        }
        val bytes = out.toByteArray()
        return if (bytes.size > maxBodyBytes + 1) bytes.copyOf((maxBodyBytes + 1).toInt()) else bytes
    }

    private fun isPinnedLeaf(session: SSLSession, pinned: ByteArray?): Boolean {
        if (pinned == null) return false
        val leaf = runCatching { session.peerCertificates.firstOrNull() as? X509Certificate }.getOrNull() ?: return false
        return MessageDigest.isEqual(ServerTrustDecision.sha256(leaf.encoded), pinned)
    }

    companion object {
        /** The system default trust manager; on Android it follows `network_security_config` (system certificates only). */
        fun systemTrustManager(): X509TrustManager = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
            .apply { init(null as KeyStore?) }
            .trustManagers
            .filterIsInstance<X509TrustManager>()
            .first()

        private const val BUFFER_BYTES = 64 * 1024
        private const val CONNECT_TIMEOUT_SECONDS = 30L
        private const val CALL_TIMEOUT_SECONDS = 300L

        fun defaultClient(): OkHttpClient = OkHttpClient.Builder()
            .followRedirects(false)
            .followSslRedirects(false)
            .retryOnConnectionFailure(false)
            .cookieJar(CookieJar.NO_COOKIES)
            .cache(null)
            .connectTimeout(CONNECT_TIMEOUT_SECONDS, TimeUnit.SECONDS)
            .readTimeout(CONNECT_TIMEOUT_SECONDS, TimeUnit.SECONDS)
            .writeTimeout(CONNECT_TIMEOUT_SECONDS, TimeUnit.SECONDS)
            .callTimeout(CALL_TIMEOUT_SECONDS, TimeUnit.SECONDS)
            .build()
    }
}

/**
 * Delegates to the system check first; if the system rejects the chain, accepts only a leaf certificate matching the pin,
 * otherwise records the reason in [rejection] and fails as usual. This is not "trust everything": with no pin or a fingerprint
 * mismatch the chain is rejected.
 */
@SuppressLint("CustomX509TrustManager") // Delegates to the system check; relaxes it only for the one certificate the user confirmed
internal class PinningTrustManager(private val system: X509TrustManager, private val pinned: ByteArray?) : X509TrustManager {
    override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) {
        try {
            system.checkServerTrusted(chain, authType)
        } catch (failure: CertificateException) {
            val leaf = chain.firstOrNull()?.encoded?.let(ServerTrustDecision::sha256)
            when (val decision = ServerTrustDecision.decide(systemTrusted = false, leafFingerprint = leaf, pinned = pinned)) {
                ServerTrustDecision.AcceptPinned -> return
                is ServerTrustDecision.Reject -> rejection.set(decision.error)
                ServerTrustDecision.SystemDefault -> Unit
            }
            throw failure
        }
    }

    override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) = system.checkClientTrusted(chain, authType)

    override fun getAcceptedIssuers(): Array<X509Certificate> = system.acceptedIssuers

    companion object {
        val rejection = ThreadLocal<CloudCertificateException?>()
    }
}
