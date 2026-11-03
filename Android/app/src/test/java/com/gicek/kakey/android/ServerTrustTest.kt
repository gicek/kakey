package com.gicek.kakey.android

import com.gicek.kakey.android.data.cloud.PinningTrustManager
import com.gicek.kakey.android.domain.CloudCertificateException
import com.gicek.kakey.android.domain.ServerTrustDecision
import java.security.cert.CertificateException
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import javax.net.ssl.X509TrustManager
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * Certificate challenges (docs/SECURITY.md): proceed normally when the system trusts the server; otherwise accept
 * only a leaf certificate matching the pinned value, and fail with its fingerprint if none matches.
 */
class ServerTrustTest {
    private val mine = ByteArray(32) { 1 }
    private val other = ByteArray(32) { 2 }

    @After
    fun clear() {
        PinningTrustManager.rejection.remove()
    }

    @Test
    fun decidesLikeApple() {
        val decide = ServerTrustDecision.Companion::decide
        assertSame(ServerTrustDecision.SystemDefault, decide(true, mine, null))
        assertSame("Pin is ignored once the server has a trusted certificate", ServerTrustDecision.SystemDefault, decide(true, other, mine))
        assertSame("No certificate: defer to the system and fail as usual", ServerTrustDecision.SystemDefault, decide(false, null, mine))
        assertSame(ServerTrustDecision.AcceptPinned, decide(false, mine, mine))
        val untrusted = (decide(false, mine, null) as ServerTrustDecision.Reject).error
        assertTrue(untrusted is CloudCertificateException.Untrusted)
        assertArrayEquals(mine, untrusted.fingerprint)
        val changed = (decide(false, other, mine) as ServerTrustDecision.Reject).error
        assertTrue(changed is CloudCertificateException.Changed)
        assertArrayEquals(other, changed.fingerprint)
        assertEquals("01:01", ServerTrustDecision.formatted(byteArrayOf(1, 1)))
    }

    @Test
    fun acceptsOnlyThePinnedSelfSignedCertificate() {
        val chain = arrayOf(selfSigned)
        assertArrayEquals(SELF_SIGNED_SHA256, ServerTrustDecision.sha256(selfSigned.encoded))

        // No pin: fail as usual and record the fingerprint so the UI can ask the user to verify it
        expectRejected { PinningTrustManager(SystemRejects, null).checkServerTrusted(chain, "ECDHE_ECDSA") }
        val untrusted = PinningTrustManager.rejection.get()
        assertTrue(untrusted is CloudCertificateException.Untrusted)
        assertArrayEquals(SELF_SIGNED_SHA256, untrusted!!.fingerprint)

        // This exact certificate is pinned: accept without recording a reason
        PinningTrustManager.rejection.remove()
        PinningTrustManager(SystemRejects, SELF_SIGNED_SHA256).checkServerTrusted(chain, "ECDHE_ECDSA")
        assertNull(PinningTrustManager.rejection.get())

        // A different certificate is pinned: reject and report that the certificate changed
        expectRejected { PinningTrustManager(SystemRejects, mine).checkServerTrusted(chain, "ECDHE_ECDSA") }
        assertTrue(PinningTrustManager.rejection.get() is CloudCertificateException.Changed)
    }

    private fun expectRejected(block: () -> Unit) {
        try {
            block()
            fail("Must reject when the system does not trust the certificate and no pin matches")
        } catch (_: CertificateException) {
        }
    }

    /** A system trust manager that rejects everything (as with a self-signed certificate). */
    private object SystemRejects : X509TrustManager {
        override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) = throw CertificateException("untrusted")

        override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) = throw CertificateException("untrusted")

        override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
    }

    private companion object {
        /** Self-signed certificate used only by this test (CN=nas.local; the private key was discarded). */
        val selfSigned: X509Certificate = CertificateFactory.getInstance("X.509").generateCertificate(
            """
            -----BEGIN CERTIFICATE-----
            MIIBfzCCASWgAwIBAgIUdspm6qgU+ItIIPeTSsQ3C2w0cnAwCgYIKoZIzj0EAwIw
            FDESMBAGA1UEAwwJbmFzLmxvY2FsMCAXDTI2MTAzMDE2MTczMloYDzIxMjYxMDA2
            MTYxNzMyWjAUMRIwEAYDVQQDDAluYXMubG9jYWwwWTATBgcqhkjOPQIBBggqhkjO
            PQMBBwNCAAQsnDP/w9Gaie9omGDpRMFlQEEp5NhMxt+aFYL87hNsiFPW8Lw0fNAt
            ntx8U9xpxHyOObJ4v3xHDnH0pd4oFJt9o1MwUTAdBgNVHQ4EFgQUvjmfnAWJmFBu
            3BCHRAiHqKhkbsQwHwYDVR0jBBgwFoAUvjmfnAWJmFBu3BCHRAiHqKhkbsQwDwYD
            VR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNIADBFAiEArtcKYIDQwOeLCnQbBq4E
            256shneokLjqzn8typeTYgsCIEPTe+11sJf2Py49keUzYlIH72koNEl0ttW6Zt22
            +KgS
            -----END CERTIFICATE-----
            """.trimIndent().byteInputStream(),
        ) as X509Certificate

        val SELF_SIGNED_SHA256: ByteArray = "ea9a03028ecee993fb6d376c17d1e4df6ae26eb0a0af9e14bf3b7505546f8d1c"
            .chunked(2)
            .map { it.toInt(16).toByte() }
            .toByteArray()
    }
}
