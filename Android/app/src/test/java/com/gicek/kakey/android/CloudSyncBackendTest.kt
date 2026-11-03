package com.gicek.kakey.android

import com.gicek.kakey.android.domain.CloudConnectionStore
import com.gicek.kakey.android.domain.CloudSyncBackend
import com.gicek.kakey.android.domain.CloudSyncException
import com.gicek.kakey.android.domain.RemoteChanged
import com.gicek.kakey.android.domain.RemoteExpectation
import com.gicek.kakey.core.CoreCloudException
import com.gicek.kakey.core.CoreRemoteVersion
import com.gicek.kakey.core.coreCloudWebdavConnection
import java.io.IOException
import java.time.Instant
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The cloud storage backend driving the real core protocol (cloudset + kakey_core::backup) against an in-memory WebDAV
 * server; sync decisions are covered in VaultStoreTest.
 */
class CloudSyncBackendTest {
    private class MemoryConnections(var value: ByteArray?) : CloudConnectionStore {
        override fun load() = value
        override fun save(connection: ByteArray) {
            value = connection
        }
        override fun remove() {
            value = null
        }
    }

    private val server = MemoryDavExecutor()
    private val connections = MemoryConnections(coreCloudWebdavConnection(MemoryDavExecutor.BASE, "alice", "pw", false, null))
    private val backend = CloudSyncBackend("Kakey", connections, server, "Kakey-test") { Instant.parse("2026-10-28T00:00:00Z") }
    private val updatedAt = Instant.parse("2026-10-27T00:00:00Z")

    @Test
    fun firstWriteCreatesTheFolderAndReadsBackTheSameVersion() {
        assertNull(backend.read())
        val version = backend.write("one".encodeToByteArray(), updatedAt, "Pixel", RemoteExpectation.Absent)
        assertTrue("Cloud storage remote version is the ETag", version is CoreRemoteVersion.Revision)
        assertTrue("Missing folder is created first", server.requests.any { it.method == "MKCOL" })
        assertTrue(server.requests.all { request -> request.headers.any { it.name == "User-Agent" && it.value == "Kakey-test" } })

        val remote = backend.read()!!
        assertArrayEquals("one".encodeToByteArray(), remote.data)
        assertEquals(version, remote.version)
        assertEquals("Pixel", remote.deviceName)
        assertEquals("dav.example.com", backend.displayName())
    }

    @Test
    fun conditionalWritesRejectStaleVersions() {
        val first = backend.write("one".encodeToByteArray(), updatedAt, "Pixel", RemoteExpectation.Absent)!!
        assertThrows(RemoteChanged::class.java) { backend.write("x".encodeToByteArray(), updatedAt, "Pixel", RemoteExpectation.Absent) }

        server.concurrentWriteBeforeNextPut = "other device".encodeToByteArray()
        assertThrows(RemoteChanged::class.java) {
            backend.write("two".encodeToByteArray(), updatedAt, "Pixel", RemoteExpectation.Unchanged(first))
        }
        assertArrayEquals(
            "Rejected write does not overwrite the other device's content",
            "other device".encodeToByteArray(),
            server.data("Kakey/vault.kakeyvault"),
        )

        val kept = backend.write("mine".encodeToByteArray(), updatedAt, "Pixel", RemoteExpectation.Any)
        assertNotEquals(first, kept)
        assertArrayEquals("mine".encodeToByteArray(), server.data("Kakey/vault.kakeyvault"))
    }

    @Test
    fun missingConnectionAndTransportFailures() {
        connections.remove()
        val reauth = assertThrows(CloudSyncException::class.java) { backend.read() }
        assertTrue(reauth.error is CoreCloudException.ReauthRequired)
        assertTrue(server.requests.isEmpty())
        assertNull(backend.displayName())

        connections.value = coreCloudWebdavConnection(MemoryDavExecutor.BASE, "alice", "pw", false, null)
        server.failNext = IOException("offline")
        assertThrows(IOException::class.java) { backend.read() }
    }

    @Test
    fun wrongCredentialsNeedReauth() {
        connections.value = coreCloudWebdavConnection(MemoryDavExecutor.BASE, "alice", "wrong", false, null)
        val server401 =
            CloudSyncBackend("Kakey", connections, { _ -> com.gicek.kakey.core.CoreHttpResponse(401u, emptyList(), ByteArray(0)) }, "t")
        val error = assertThrows(CloudSyncException::class.java) { server401.read() }
        assertTrue(error.error is CoreCloudException.ReauthRequired)
    }
}
