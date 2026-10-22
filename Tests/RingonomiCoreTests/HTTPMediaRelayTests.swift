import Foundation
import XCTest
@testable import RingonomiCore

private final class MediaRelayFixtureProtocol: URLProtocol {
    struct Stub {
        var status = 200
        var body = Data()
        var headers: [String: String] = [:]
        var hold = false
    }
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var handler: ((URLRequest) -> Stub)?
        var requests: [URLRequest] = []
        var stops = 0
        func reset(_ handler: ((URLRequest) -> Stub)? = nil) {
            lock.lock(); defer { lock.unlock() }
            self.handler = handler; requests = []; stops = 0
        }
        func response(_ request: URLRequest) -> Stub {
            lock.lock(); requests.append(request); let handler = handler; lock.unlock()
            return handler?(request) ?? Stub(status: 404)
        }
        func snapshot() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
        func stopped() { lock.lock(); stops += 1; lock.unlock() }
    }
    private static let state = State()
    static func reset(_ handler: @escaping (URLRequest) -> Stub) { state.reset(handler) }
    static var requests: [URLRequest] { state.snapshot() }
    static func clear() { state.reset() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let stub = Self.state.response(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: stub.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !stub.body.isEmpty { client?.urlProtocol(self, didLoad: stub.body) }
        if !stub.hold { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() { Self.state.stopped() }
}

final class HTTPMediaRelayTests: XCTestCase, @unchecked Sendable {
    override func tearDown() { MediaRelayFixtureProtocol.clear(); super.tearDown() }

    private func start(kind: HTTPMediaResourceKind = .playlist, path: String = "master.m3u8") async throws -> (HTTPMediaRelay, URL) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MediaRelayFixtureProtocol.self]
        let relay = try HTTPMediaRelay(
            scope: HTTPBasicAuthenticationScope(address: "https://example.test/proxy/"),
            credential: HTTPBasicCredential(username: "fixture-user", password: "fixture-password"),
            sessionConfiguration: configuration
        )
        addTeardownBlock { await relay.stop() }
        let url = try await relay.start(source: URL(string: "https://example.test/proxy/" + path)!, kind: kind)
        return (relay, url)
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 5
        configuration.connectionProxyDictionary = [:]
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    private func urls(in data: Data) -> [URL] {
        let text = String(decoding: data, as: UTF8.self)
        var values = text.split(separator: "\n").filter { !$0.hasPrefix("#") }.compactMap { URL(string: String($0)) }
        let regex = try! NSRegularExpression(pattern: "URI=\"([^\"]+)\"")
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let range = Range(match.range(at: 1), in: text), let url = URL(string: String(text[range])) { values.append(url) }
        }
        return values
    }

    func testListenerSocketIsBoundOnlyToLoopback() async throws {
        MediaRelayFixtureProtocol.reset { _ in .init() }
        let (_, local) = try await start()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-a", "-p", String(ProcessInfo.processInfo.processIdentifier),
                             "-iTCP:" + String(local.port!), "-sTCP:LISTEN", "-Fn"]
        let pipe = Pipe(); process.standardOutput = pipe
        let errors = Pipe(); process.standardError = errors
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let names = String(decoding: output, as: UTF8.self).split(separator: "\n").filter { $0.hasPrefix("n") }
        XCTAssertEqual(names.count, 1)
        XCTAssertTrue(names.contains(Substring("n127.0.0.1:" + String(local.port!))), "Listener must bind only to loopback")
        XCTAssertTrue(MediaRelayFixtureProtocol.requests.isEmpty)
    }

    func testMasterChildKeyMapAndSegmentUseAuthenticatedUpstreamOverLoopback() async throws {
        MediaRelayFixtureProtocol.reset { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic Zml4dHVyZS11c2VyOmZpeHR1cmUtcGFzc3dvcmQ=")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            switch request.url!.path {
            case "/proxy/master.m3u8":
                return .init(body: Data("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nvideo/index.m3u8\n".utf8))
            case "/proxy/video/index.m3u8":
                return .init(body: Data("#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-KEY:METHOD=AES-128,URI=\"../key.bin\"\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:6,\nsegment.m4s\n#EXT-X-ENDLIST\n".utf8))
            default:
                let body = Data("synthetic-binary".utf8)
                return .init(body: body, headers: ["Content-Type": "application/octet-stream", "Content-Length": String(body.count)])
            }
        }
        let (_, local) = try await start()
        XCTAssertEqual(local.host, "127.0.0.1")
        let client = session(); defer { client.invalidateAndCancel() }
        let (master, masterResponse) = try await client.data(from: local)
        XCTAssertEqual((masterResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual((masterResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        let children = urls(in: master); XCTAssertEqual(children.count, 1)
        let (child, _) = try await client.data(from: children[0])
        let resources = urls(in: child); XCTAssertEqual(resources.count, 3)
        for url in resources {
            XCTAssertEqual(url.host, "127.0.0.1")
            let (data, response) = try await client.data(from: url)
            XCTAssertEqual(data, Data("synthetic-binary".utf8))
            XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        }
        XCTAssertEqual(MediaRelayFixtureProtocol.requests.count, 5)
    }

    func testPlaylistRangeUsesRewrittenOffsetsAndHEADHasNoBody() async throws {
        MediaRelayFixtureProtocol.reset { _ in .init(body: Data("#EXTM3U\n#EXTINF:6,\nsegment.ts\n#EXT-X-ENDLIST\n".utf8)) }
        let (_, local) = try await start()
        let client = session(); defer { client.invalidateAndCancel() }
        let (full, _) = try await client.data(from: local)
        var request = URLRequest(url: local); request.setValue("bytes=0-6", forHTTPHeaderField: "Range")
        let (partial, response) = try await client.data(for: request)
        XCTAssertEqual(partial, Data(full.prefix(7)))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 206)
        XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range"), "bytes 0-6/\(full.count)")
        request.httpMethod = "HEAD"; request.setValue("bytes=999999-", forHTTPHeaderField: "Range")
        let (head, headResponse) = try await client.data(for: request)
        XCTAssertTrue(head.isEmpty)
        XCTAssertNil((headResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length"))
        XCTAssertEqual(MediaRelayFixtureProtocol.requests.count, 2)
        XCTAssertTrue(MediaRelayFixtureProtocol.requests.allSatisfy { $0.httpMethod == "GET" && $0.value(forHTTPHeaderField: "Range") == nil })
    }

    func testBinaryHEADIgnoresRangeAndDoesNotForwardIt() async throws {
        MediaRelayFixtureProtocol.reset { request in
            XCTAssertEqual(request.httpMethod, "HEAD")
            XCTAssertNil(request.value(forHTTPHeaderField: "Range"))
            return .init(headers: ["Content-Type": "video/mp4", "Content-Length": "100"])
        }
        let (_, local) = try await start(kind: .media, path: "video.mp4")
        let client = session(); defer { client.invalidateAndCancel() }
        var request = URLRequest(url: local); request.httpMethod = "HEAD"
        request.setValue("bytes=999999-", forHTTPHeaderField: "Range")
        let (data, response) = try await client.data(for: request)
        XCTAssertTrue(data.isEmpty)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length"), "100")
        XCTAssertNil((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range"))
        XCTAssertEqual(MediaRelayFixtureProtocol.requests.count, 1)
    }

    func testBinaryRangePreserves206AndContentRange() async throws {
        MediaRelayFixtureProtocol.reset { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=10-19")
            return .init(status: 206, body: Data(repeating: 7, count: 10),
                         headers: ["Content-Type": "video/mp4", "Content-Length": "10", "Content-Range": "bytes 10-19/100", "Accept-Ranges": "bytes"])
        }
        let (_, local) = try await start(kind: .media, path: "video.mp4")
        let client = session(); defer { client.invalidateAndCancel() }
        var request = URLRequest(url: local); request.setValue("bytes=10-19", forHTTPHeaderField: "Range")
        let (data, response) = try await client.data(for: request)
        XCTAssertEqual(data, Data(repeating: 7, count: 10))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 206)
        XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range"), "bytes 10-19/100")
    }

    func testIgnoredInitialRangeCanPlayButIgnoredNonzeroSeekDoesNotDownloadWholeFile() async throws {
        for (range, status) in [("bytes=0-", 200), ("bytes=10-", 416), ("bytes=0-999", 416)] {
            MediaRelayFixtureProtocol.reset { _ in
                .init(body: Data("synthetic-binary".utf8), headers: ["Content-Length": "16", "Accept-Ranges": "bytes"])
            }
            let (_, local) = try await self.start(kind: .media, path: "live.ts")
            let client = session(); defer { client.invalidateAndCancel() }
            var request = URLRequest(url: local); request.setValue(range, forHTTPHeaderField: "Range")
            let (data, response) = try await client.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, status)
            XCTAssertEqual(data, status == 200 ? Data("synthetic-binary".utf8) : Data())
            XCTAssertNil((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Accept-Ranges"))
        }
    }

    func testPlaylistOutOfRangeReturns416WithoutAnErrorPage() async throws {
        MediaRelayFixtureProtocol.reset { _ in .init(body: Data("#EXTM3U\n#EXTINF:1,\na.ts\n".utf8)) }
        let (_, local) = try await start()
        let client = session(); defer { client.invalidateAndCancel() }
        var request = URLRequest(url: local); request.setValue("bytes=9223372036854775807-", forHTTPHeaderField: "Range")
        let (data, response) = try await client.data(for: request)
        XCTAssertTrue(data.isEmpty)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 416)
        XCTAssertTrue((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range")?.hasPrefix("bytes */") == true)
    }

    func testWrongContentRangeAndDisguisedPlaylistAreRejected() async throws {
        for disguised in [false, true] {
            MediaRelayFixtureProtocol.reset { _ in
                if disguised { return .init(body: Data("#EXTM3U\nhttps://other.test/file.ts\n".utf8)) }
                return .init(status: 206, body: Data(repeating: 7, count: 10), headers: ["Content-Length": "10", "Content-Range": "bytes 0-9/100"])
            }
            let (_, local) = try await start(kind: .media, path: "video.mp4")
            let client = session(); defer { client.invalidateAndCancel() }
            var request = URLRequest(url: local)
            if !disguised { request.setValue("bytes=10-19", forHTTPHeaderField: "Range") }
            let (data, response) = try await client.data(for: request)
            XCTAssertTrue(data.isEmpty)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 502)
            XCTAssertEqual(MediaRelayFixtureProtocol.requests.count, 1)
        }
    }

    func test401AndExternalPlaylistFailWithoutFetchingOtherOrigins() async throws {
        for unauthorized in [false, true] {
            MediaRelayFixtureProtocol.reset { _ in
                .init(status: unauthorized ? 401 : 200, body: Data("#EXTM3U\n#EXTINF:6,\nhttps://other.test/file.ts\n".utf8))
            }
            let (_, local) = try await start()
            let client = session(); defer { client.invalidateAndCancel() }
            let (data, response) = try await client.data(from: local)
            XCTAssertTrue(data.isEmpty)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 502)
            XCTAssertEqual(MediaRelayFixtureProtocol.requests.count, 1)
            XCTAssertTrue(MediaRelayFixtureProtocol.requests.allSatisfy { $0.url?.host == "example.test" })
        }
    }

    func testStopCancelsPendingUpstreamAndRejectsFurtherConnections() async throws {
        MediaRelayFixtureProtocol.reset { _ in .init(body: Data("pending".utf8), hold: true) }
        let (relay, local) = try await start(kind: .media, path: "live.ts")
        let client = session(); defer { client.invalidateAndCancel() }
        let reading = Task { try await client.data(from: local) }
        for _ in 0..<100 {
            if !MediaRelayFixtureProtocol.requests.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(MediaRelayFixtureProtocol.requests.count, 1)
        await relay.stop()
        let result = await reading.result
        if case .success = result { XCTFail("Stopped connection unexpectedly succeeded") }
        do { _ = try await client.data(from: local); XCTFail("Stopped listener accepted another request") } catch {}
        let failure = await relay.lastFailure
        XCTAssertNil(failure)
        XCTAssertEqual(MediaRelayFixtureProtocol.requests.count, 1)
    }

    func testBinaryTransferPreservesPayloadAcrossMultipleWrites() async throws {
        let body = Data((0..<(256 * 1024)).map { UInt8($0 % 251) })
        MediaRelayFixtureProtocol.reset { _ in .init(body: body, headers: ["Content-Type": "video/mp2t", "Content-Length": String(body.count)]) }
        let (_, local) = try await start(kind: .media, path: "live.ts")
        let client = session(); defer { client.invalidateAndCancel() }
        let started = Date()
        let (data, _) = try await client.data(from: local)
        XCTAssertEqual(data, body)
        print("RelayFixtureTransfer: bytes=\(data.count) seconds=\(Date().timeIntervalSince(started))")
    }
}
