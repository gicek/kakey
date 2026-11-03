package com.gicek.kakey.android

import com.gicek.kakey.android.data.cloud.OkHttpExecutor
import com.gicek.kakey.core.CoreHttpHeader
import com.gicek.kakey.core.CoreHttpRequest
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test

/**
 * The OkHttp executor against a local MockWebServer: requests go out unchanged, redirects are not followed, cookies are not
 * stored, and response bodies are truncated at the limit.
 */
class OkHttpExecutorTest {
    private val server = MockWebServer()

    @Before
    fun start() {
        server.start()
    }

    @After
    fun stop() {
        server.close()
    }

    private fun request(method: String, path: String, body: ByteArray = ByteArray(0), headers: List<CoreHttpHeader> = emptyList()) =
        CoreHttpRequest(method, server.url(path).toString(), headers, body)

    @Test
    fun sendsWebDavMethodsVerbatim() {
        server.enqueue(MockResponse.Builder().code(207).addHeader("ETag", "\"v1\"").body("<ok/>").build())
        val response = OkHttpExecutor(maxBodyBytes = 1024).execute(
            request("PROPFIND", "/dav/Kakey/", "<propfind/>".encodeToByteArray(), listOf(CoreHttpHeader("Depth", "1"))),
        )
        val recorded = server.takeRequest()
        assertEquals("PROPFIND", recorded.method)
        assertEquals("1", recorded.headers["Depth"])
        assertEquals("<propfind/>", recorded.body?.utf8())
        assertEquals(207, response.status.toInt())
        assertArrayEquals("<ok/>".encodeToByteArray(), response.body)
        assertEquals("\"v1\"", response.headers.first { it.name.equals("etag", ignoreCase = true) }.value)

        server.enqueue(MockResponse.Builder().code(201).build())
        OkHttpExecutor().execute(request("MKCOL", "/dav/New/"))
        assertEquals("MKCOL", server.takeRequest().method)
    }

    @Test
    fun returnsRedirectsInsteadOfFollowing() {
        server.enqueue(MockResponse.Builder().code(302).addHeader("Location", "http://evil.example/").build())
        val response = OkHttpExecutor().execute(request("GET", "/a"))
        assertEquals(302, response.status.toInt())
        assertEquals("http://evil.example/", response.headers.first { it.name.equals("location", ignoreCase = true) }.value)
        assertEquals(1, server.requestCount)
    }

    @Test
    fun doesNotKeepCookies() {
        server.enqueue(MockResponse.Builder().code(200).addHeader("Set-Cookie", "session=abc; Path=/").build())
        server.enqueue(MockResponse.Builder().code(200).build())
        val executor = OkHttpExecutor()
        executor.execute(request("GET", "/a"))
        executor.execute(request("GET", "/a"))
        server.takeRequest()
        assertNull(server.takeRequest().headers["Cookie"])
    }

    @Test
    fun capsBodyAtLimitPlusOne() {
        server.enqueue(MockResponse.Builder().code(200).body("x".repeat(5000)).build())
        assertEquals(
            "Reads one extra byte so the core can report the response as too large",
            101,
            OkHttpExecutor(maxBodyBytes = 100).execute(request("GET", "/big")).body.size,
        )
    }
}
