import Foundation

@testable import Kakey

/// In-memory WebDAV server for tests, injected as `HTTPExecuting`. Implements what the core sends (PROPFIND with Depth 0 / 1, GET,
/// PUT, MKCOL, and conditional requests) so `CloudSyncBackend` drives the real core protocol implementation. ETags look like `"v3"`
/// and increase on every write.
final class MemoryDavExecutor: HTTPExecuting, @unchecked Sendable {
    static let base = "https://dav.example.com/dav/"

    private struct State {
        var files: [String: (data: Data, version: Int)] = [:]
        var dirs: Set<String> = [""]
        var version = 0
        var requests: [CoreHttpRequest] = []
        /// Content that "another device" writes just before the next PUT.
        var concurrentWriteBeforeNextPut: Data?
        /// The next request throws this error directly (simulates a network outage).
        var transportError: URLError?
        /// MKCOL under these directories always returns 405 (simulates servers such as Synology that also return 405 when access is
        /// denied).
        var mkcolForbiddenIn: Set<String> = []
        /// The server presents a certificate the system does not trust (this is its fingerprint); accepted or rejected by the same
        /// rule as the real executor (`ServerTrustDecision`).
        var selfSignedCertificate: Data?
    }

    private let state = Locked(State())

    var requests: [CoreHttpRequest] { state.value.requests }

    func data(at path: String) -> Data? {
        state.value.files[path]?.data
    }

    func putExternal(_ path: String, _ data: Data) {
        state.withLock { state in
            state.version += 1
            state.dirs.insert((path as NSString).deletingLastPathComponent)
            state.files[path] = (data, state.version)
        }
    }

    func writeBeforeNextPut(_ data: Data) {
        state.withLock { $0.concurrentWriteBeforeNextPut = data }
    }

    func forbidCreatingFolders(in path: String) {
        state.withLock { _ = $0.mkcolForbiddenIn.insert(path) }
    }

    func failNextRequest(with error: URLError) {
        state.withLock { $0.transportError = error }
    }

    func presentSelfSignedCertificate(_ fingerprint: Data?) {
        state.withLock { $0.selfSignedCertificate = fingerprint }
    }

    func execute(_ request: CoreHttpRequest) async throws -> CoreHttpResponse {
        try state.withLock { state in
            state.requests.append(request)
            if let error = state.transportError {
                state.transportError = nil
                throw error
            }
            if let certificate = state.selfSignedCertificate,
                case .reject(let error) = ServerTrustDecision.decide(
                    systemTrusted: false, leafFingerprint: certificate, pinned: request.pinnedCertificate)
            {
                throw error
            }
            return Self.handle(request, in: &state)
        }
    }

    private static func header(_ request: CoreHttpRequest, _ name: String) -> String? {
        request.headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private static func etag(_ version: Int) -> String { "\"v\(version)\"" }

    private static func response(_ status: UInt16, _ body: String = "") -> CoreHttpResponse {
        CoreHttpResponse(status: status, headers: [], body: Data(body.utf8))
    }

    private static func handle(_ request: CoreHttpRequest, in state: inout State) -> CoreHttpResponse {
        guard request.url.hasPrefix(base) else { return response(404) }
        let path =
            String(request.url.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")).removingPercentEncoding ?? ""
        let parent = (path as NSString).deletingLastPathComponent
        let file = state.files[path]
        switch request.method {
        case "PROPFIND":
            var entries: [String] = []
            if let file {
                entries.append(propEntry(path, isDir: false, size: file.data.count, etag: etag(file.version)))
            } else if state.dirs.contains(path) {
                entries.append(propEntry(path, isDir: true, size: nil, etag: "\"dir\""))
                if header(request, "Depth") == "1" {
                    for dir in state.dirs.sorted() where !dir.isEmpty && dir != path && (dir as NSString).deletingLastPathComponent == path
                    {
                        entries.append(propEntry(dir, isDir: true, size: nil, etag: "\"dir\""))
                    }
                    for (child, value) in state.files where (child as NSString).deletingLastPathComponent == path {
                        entries.append(propEntry(child, isDir: false, size: value.data.count, etag: etag(value.version)))
                    }
                }
            } else {
                return response(404)
            }
            return response(207, #"<?xml version="1.0"?><d:multistatus xmlns:d="DAV:">"# + entries.joined() + "</d:multistatus>")
        case "GET":
            guard let file else { return response(404) }
            if let expected = header(request, "If-Match"), expected != etag(file.version) { return response(412) }
            return CoreHttpResponse(status: 200, headers: [], body: file.data)
        case "PUT":
            if let other = state.concurrentWriteBeforeNextPut {
                state.concurrentWriteBeforeNextPut = nil
                state.version += 1
                state.files[path] = (other, state.version)
            }
            guard state.dirs.contains(parent) else { return response(409) }
            let current = state.files[path]
            if header(request, "If-None-Match") == "*", current != nil { return response(412) }
            if let expected = header(request, "If-Match"), current.map({ etag($0.version) }) != expected { return response(412) }
            state.version += 1
            state.files[path] = (request.body, state.version)
            return response(current == nil ? 201 : 204)
        case "MKCOL":
            if state.mkcolForbiddenIn.contains(parent) || state.dirs.contains(path) { return response(405) }
            guard state.dirs.contains(parent) else { return response(409) }
            state.dirs.insert(path)
            return response(201)
        default:
            return response(405)
        }
    }

    private static func propEntry(_ path: String, isDir: Bool, size: Int?, etag: String) -> String {
        let href = "/dav/" + path + (isDir && !path.isEmpty ? "/" : "")
        let type = isDir ? "<d:resourcetype><d:collection/></d:resourcetype>" : "<d:resourcetype/>"
        let length = size.map { "<d:getcontentlength>\($0)</d:getcontentlength>" } ?? ""
        let tag = etag.replacingOccurrences(of: "\"", with: "&quot;")
        return "<d:response><d:href>\(href)</d:href><d:propstat><d:prop>\(type)\(length)<d:getetag>\(tag)</d:getetag></d:prop>"
            + "<d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
    }
}
