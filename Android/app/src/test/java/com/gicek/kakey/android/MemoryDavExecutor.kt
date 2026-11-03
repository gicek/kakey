package com.gicek.kakey.android

import com.gicek.kakey.android.domain.HttpExecutor
import com.gicek.kakey.core.CoreHttpRequest
import com.gicek.kakey.core.CoreHttpResponse
import java.io.IOException
import java.net.URLDecoder

/**
 * In-memory WebDAV server for tests, injected as the [HttpExecutor]. Implements what the core sends: PROPFIND (Depth 0 / 1),
 * GET, PUT, MKCOL and conditional requests, so `CloudSyncBackend` drives the real core protocol. ETags look like `"v3"` and
 * increase with every write.
 */
class MemoryDavExecutor : HttpExecutor {
    private val files = mutableMapOf<String, Pair<ByteArray, Int>>()
    private val dirs = mutableSetOf("")
    private var version = 0
    val requests = mutableListOf<CoreHttpRequest>()

    /** Content "another device" writes just before the next PUT. */
    var concurrentWriteBeforeNextPut: ByteArray? = null

    /** Thrown by the next request (simulates losing the network). */
    var failNext: IOException? = null

    fun data(path: String): ByteArray? = files[path]?.first

    fun putExternal(path: String, data: ByteArray) {
        dirs += path.substringBeforeLast('/', "")
        files[path] = data to ++version
    }

    override fun execute(request: CoreHttpRequest): CoreHttpResponse {
        requests += request
        failNext?.let {
            failNext = null
            throw it
        }
        if (!request.url.startsWith(BASE)) return response(404)
        val path = URLDecoder.decode(request.url.removePrefix(BASE).trim('/'), "UTF-8")
        val parent = path.substringBeforeLast('/', "")
        val file = files[path]
        return when (request.method) {
            "PROPFIND" -> propfind(path, file, request)
            "GET" -> get(file, request)
            "PUT" -> put(path, parent, request)
            "MKCOL" -> mkcol(path, parent)
            else -> response(405)
        }
    }

    private fun get(file: Pair<ByteArray, Int>?, request: CoreHttpRequest): CoreHttpResponse = when {
        file == null -> response(404)
        header(request, "If-Match")?.let { it != etag(file.second) } == true -> response(412)
        else -> CoreHttpResponse(200u, emptyList(), file.first)
    }

    private fun mkcol(path: String, parent: String): CoreHttpResponse = when {
        path in dirs -> response(405)
        parent !in dirs -> response(409)
        else -> {
            dirs += path
            response(201)
        }
    }

    private fun put(path: String, parent: String, request: CoreHttpRequest): CoreHttpResponse {
        concurrentWriteBeforeNextPut?.let {
            concurrentWriteBeforeNextPut = null
            files[path] = it to ++version
        }
        if (parent !in dirs) return response(409)
        val current = files[path]
        if (header(request, "If-None-Match") == "*" && current != null) return response(412)
        val expected = header(request, "If-Match")
        if (expected != null && current?.let { etag(it.second) } != expected) return response(412)
        files[path] = request.body to ++version
        return response(if (current == null) 201 else 204)
    }

    private fun propfind(path: String, file: Pair<ByteArray, Int>?, request: CoreHttpRequest): CoreHttpResponse {
        val entries = mutableListOf<String>()
        when {
            file != null -> entries += entry(path, isDir = false, size = file.first.size, etag = etag(file.second))
            path in dirs -> {
                entries += entry(path, isDir = true, size = null, etag = "\"dir\"")
                if (header(request, "Depth") == "1") {
                    files.filterKeys { it.substringBeforeLast('/', "") == path }
                        .forEach { (child, value) -> entries += entry(child, false, value.first.size, etag(value.second)) }
                }
            }
            else -> return response(404)
        }
        return response(207, """<?xml version="1.0"?><d:multistatus xmlns:d="DAV:">${entries.joinToString("")}</d:multistatus>""")
    }

    private fun entry(path: String, isDir: Boolean, size: Int?, etag: String): String {
        val href = "/dav/$path" + if (isDir && path.isNotEmpty()) "/" else ""
        val type = if (isDir) "<d:resourcetype><d:collection/></d:resourcetype>" else "<d:resourcetype/>"
        val length = size?.let { "<d:getcontentlength>$it</d:getcontentlength>" } ?: ""
        return "<d:response><d:href>$href</d:href><d:propstat><d:prop>$type$length<d:getetag>${etag.replace("\"", "&quot;")}</d:getetag>" +
            "</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
    }

    private fun header(request: CoreHttpRequest, name: String) = request.headers.firstOrNull {
        it.name.equals(name, ignoreCase = true)
    }?.value

    private fun etag(version: Int) = "\"v$version\""

    private fun response(status: Int, body: String = "") = CoreHttpResponse(status.toUShort(), emptyList(), body.encodeToByteArray())

    companion object {
        const val BASE = "https://dav.example.com/dav/"
    }
}
