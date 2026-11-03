import XCTest

@testable import Kakey

/// `URLSessionHTTPExecutor`: sends requests unchanged, returns responses unchanged, truncates the body at the limit, and stores no
/// cookies. The network is stubbed with `URLProtocol`.
final class URLSessionHTTPExecutorTests: XCTestCase {
    override func tearDown() {
        StubProtocol.reset()
        super.tearDown()
    }

    private func executor(maxBodyBytes: Int = 1024) -> URLSessionHTTPExecutor {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSessionHTTPExecutor(configuration: configuration, maxBodyBytes: maxBodyBytes)
    }

    func testSendsRequestVerbatimAndReturnsResponse() async throws {
        StubProtocol.respond(status: 207, headers: ["ETag": "\"v1\"", "Content-Type": "application/xml"], body: Data("<ok/>".utf8))
        let request = CoreHttpRequest(
            method: "PROPFIND", url: "https://dav.example.com/dav/Kakey/",
            headers: [CoreHttpHeader(name: "Depth", value: "1"), CoreHttpHeader(name: "Authorization", value: "Basic eA==")],
            body: Data("<propfind/>".utf8))
        let response = try await executor().execute(request)

        let seen = try XCTUnwrap(StubProtocol.requests.first)
        XCTAssertEqual(seen.request.httpMethod, "PROPFIND")
        XCTAssertEqual(seen.request.url?.absoluteString, "https://dav.example.com/dav/Kakey/")
        XCTAssertEqual(seen.request.value(forHTTPHeaderField: "Depth"), "1")
        XCTAssertEqual(seen.request.value(forHTTPHeaderField: "Authorization"), "Basic eA==")
        XCTAssertEqual(seen.body, Data("<propfind/>".utf8))

        XCTAssertEqual(response.status, 207)
        XCTAssertEqual(response.body, Data("<ok/>".utf8))
        XCTAssertEqual(response.headers.first { $0.name.caseInsensitiveCompare("etag") == .orderedSame }?.value, "\"v1\"")
    }

    func testCapsBodyAtLimitPlusOne() async throws {
        StubProtocol.respond(status: 200, headers: [:], body: Data(repeating: 7, count: 5000))
        let response = try await executor(maxBodyBytes: 100).execute(
            CoreHttpRequest(method: "GET", url: "https://dav.example.com/big", headers: [], body: Data()))
        XCTAssertEqual(response.body.count, 101, "Reads one extra byte so the core can report the response as too large")
    }

    func testDoesNotKeepCookies() async throws {
        StubProtocol.respond(status: 200, headers: ["Set-Cookie": "session=abc; Path=/"], body: Data())
        let executor = executor()
        let request = CoreHttpRequest(method: "GET", url: "https://dav.example.com/a", headers: [], body: Data())
        _ = try await executor.execute(request)
        _ = try await executor.execute(request)
        XCTAssertEqual(StubProtocol.requests.count, 2)
        XCTAssertNil(StubProtocol.requests[1].request.value(forHTTPHeaderField: "Cookie"))
    }

    func testRejectsInvalidURL() async {
        do {
            _ = try await executor().execute(CoreHttpRequest(method: "GET", url: "not a url", headers: [], body: Data()))
            XCTFail("Invalid URL")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .badURL)
        } catch {
            XCTFail("\(error)")
        }
    }

    /// Certificate challenge (docs/SECURITY.md): trusted by the system means default handling; otherwise only a leaf
    /// certificate matching the pinned value is accepted, and anything else fails with its fingerprint.
    func testServerTrustDecision() {
        let mine = Data(repeating: 1, count: 32)
        let other = Data(repeating: 2, count: 32)
        let decide = ServerTrustDecision.decide
        XCTAssertEqual(decide(true, mine, nil), .systemDefault)
        XCTAssertEqual(decide(true, other, mine), .systemDefault, "Once a valid certificate is in place the pin is ignored")
        XCTAssertEqual(decide(false, nil, mine), .systemDefault, "Without a certificate, defer to the system, which fails as usual")
        XCTAssertEqual(decide(false, mine, nil), .reject(.untrusted(fingerprint: mine)))
        XCTAssertEqual(decide(false, mine, mine), .acceptPinned)
        XCTAssertEqual(decide(false, other, mine), .reject(.changed(fingerprint: other)))
        XCTAssertFalse(ServerTrustDecision.constantTimeEqual(mine, mine.prefix(31)))
    }
}

/// `URLProtocol` that records requests and returns canned responses. The request body arrives via `httpBodyStream`, so it is read
/// out here for assertions.
private final class StubProtocol: URLProtocol {
    struct Seen {
        var request: URLRequest
        var body: Data
    }

    private static let state = Locked<(responses: [(Int, [String: String], Data)], requests: [Seen])>(([], []))

    static var requests: [Seen] { state.value.requests }

    static func respond(status: Int, headers: [String: String], body: Data) {
        state.withLock { $0.responses = [(status, headers, body)] }
    }

    static func reset() {
        state.value = ([], [])
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
            stream.close()
        }
        let response = Self.state.withLock { state -> (Int, [String: String], Data) in
            state.requests.append(Seen(request: request, body: body))
            return state.responses.first ?? (500, [:], Data())
        }
        let http = HTTPURLResponse(url: request.url!, statusCode: response.0, httpVersion: "HTTP/1.1", headerFields: response.1)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.2)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
