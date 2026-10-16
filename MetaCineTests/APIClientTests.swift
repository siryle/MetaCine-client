import XCTest
import UIKit
@testable import MetaCine

private final class StubURLProtocol: URLProtocol {
    static let lock = NSLock()
    static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let handler = Self.lock.withLock { Self.handler }
            guard let handler else { throw URLError(.unknown) }
            let (status, headers, body) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private final class RecordedRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URLRequest] = []
    func append(_ request: URLRequest) { lock.withLock { values.append(request) } }
    var all: [URLRequest] { lock.withLock { values } }
}

@MainActor
final class APIClientTests: XCTestCase {
    private func client() throws -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return try APIClient(
            profile: ServerProfile(name: "测试", address: "http://example.test:8080/cinema"),
            credential: ServerCredential(username: "admin", password: "secret"),
            configuration: configuration
        )
    }

    func testURLCompositionPreservesServerSubpathAndEscapesQuery() async throws {
        let api = try client()
        defer { api.invalidate() }
        let url = try api.url(path: "api/resources/rankings", query: [
            URLQueryItem(name: "tag", value: "冷门佳片"),
            URLQueryItem(name: "query", value: "A&B + C")
        ])
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.path, "/cinema/api/resources/rankings")
        XCTAssertEqual(parts.queryItems?.first?.value, "冷门佳片")
        XCTAssertEqual(parts.queryItems?.last?.value, "A&B + C")
    }

    func testUnauthorizedRequestAuthenticatesAndRetriesOnce() async throws {
        let requests = RecordedRequests()
        StubURLProtocol.lock.withLock {
            StubURLProtocol.handler = { request in
                requests.append(request)
                let path = request.url!.path
                let status: Int
                let json: String
                if path.hasSuffix("/auth") { status = 200; json = #"{"authenticated":false}"# }
                else if path.hasSuffix("/auth/login") { status = 200; json = #"{"authenticated":true}"# }
                else if requests.all.filter({ $0.url!.path.hasSuffix("/jobs") }).count == 1 {
                    status = 401; json = #"{"error":"expired"}"#
                } else { status = 200; json = "[]" }
                return (status, ["Content-Type": "application/json"], Data(json.utf8))
            }
        }
        let api = try client()
        defer { api.invalidate() }
        let jobs: [Job] = try await api.get("api/jobs")
        XCTAssertTrue(jobs.isEmpty)
        XCTAssertEqual(requests.all.map { $0.url!.lastPathComponent }, ["jobs", "auth", "login", "jobs"])
        XCTAssertEqual(requests.all[2].httpMethod, "POST")
        XCTAssertEqual(requests.all[2].value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testAuthenticationFailureDoesNotLoop() async throws {
        let requests = RecordedRequests()
        StubURLProtocol.lock.withLock {
            StubURLProtocol.handler = { request in
                requests.append(request)
                if request.url!.path.hasSuffix("/auth") {
                    return (200, [:], Data(#"{"authenticated":false}"#.utf8))
                }
                return (401, [:], Data(#"{"error":"凭据无效"}"#.utf8))
            }
        }
        let api = try client()
        defer { api.invalidate() }
        do {
            let _: [Job] = try await api.get("api/jobs")
            XCTFail("Invalid credentials must throw.")
        } catch {
            XCTAssertEqual(error.localizedDescription, "凭据无效")
        }
        XCTAssertEqual(requests.all.count, 3)
    }

    func testBackendErrorsPreserveActionableMessage() async throws {
        StubURLProtocol.lock.withLock {
            StubURLProtocol.handler = { _ in (409, [:], Data(#"{"error":"已有任务运行"}"#.utf8)) }
        }
        let api = try client()
        defer { api.invalidate() }
        do {
            try await api.perform("POST", "api/resources/subscriptions/test/check", body: EmptyBody())
            XCTFail("A conflict must throw.")
        } catch {
            XCTAssertEqual(error.localizedDescription, "已有任务运行")
        }
    }

    func testInvalidatedClientNeverSendsAnotherRequest() async throws {
        let api = try client()
        api.invalidate()
        do {
            let _: [Job] = try await api.get("api/jobs")
            XCTFail("An invalidated server context must not issue requests.")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testResourceMediaUsesVerifiedTMDBDetailsBeforeSearching() async throws {
        let requests = RecordedRequests()
        StubURLProtocol.lock.withLock {
            StubURLProtocol.handler = { request in
                requests.append(request)
                return (200, [:], Data(#"{"id":42,"kind":"tv","title":"Example Show","year":2026,"poster":"/poster.jpg"}"#.utf8))
            }
        }
        let api = try client()
        defer { api.invalidate() }
        let media = try await api.resourceMedia(for: resourceIdentity(kind: "tv", tmdbID: 42))
        XCTAssertEqual(media?.poster, "/poster.jpg")
        XCTAssertEqual(requests.all.map { $0.url!.path }, ["/cinema/api/resources/rankings/tmdb/tv/42"])
    }

    func testResourceMediaCorrectsMislabeledChannelKinds() async throws {
        let requests = RecordedRequests()
        StubURLProtocol.lock.withLock {
            StubURLProtocol.handler = { request in
                requests.append(request)
                let parts = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
                let query = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
                XCTAssertEqual(query["query"], "Example Show")
                XCTAssertEqual(query["year"], "2026")
                let json = query["kind"] == "tv"
                    ? #"[{"id":42,"kind":"tv","title":"Example Show","year":2026,"poster":"/poster.jpg"}]"# : "[]"
                return (200, [:], Data(json.utf8))
            }
        }
        let api = try client()
        defer { api.invalidate() }
        let media = try await api.resourceMedia(for: resourceIdentity(kind: "movie"))
        XCTAssertEqual(media?.kind, "tv")
        XCTAssertEqual(requests.all.count, 2)
    }

    func testResourceMediaLeavesAmbiguousMatchesWithoutAPoster() async throws {
        StubURLProtocol.lock.withLock {
            StubURLProtocol.handler = { request in
                let kind = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "kind" })?.value
                let json = kind == "tv" ? """
                [{"id":42,"kind":"tv","title":"Example Show","year":2026,"poster":"/first.jpg"},
                 {"id":43,"kind":"tv","title":"Example Show","year":2026,"poster":"/second.jpg"}]
                """ : "[]"
                return (200, [:], Data(json.utf8))
            }
        }
        let api = try client()
        defer { api.invalidate() }
        let media = try await api.resourceMedia(for: resourceIdentity())
        XCTAssertNil(media)
    }

    func testResourceMediaFailuresAreOptionalButCancellationPropagates() async throws {
        let requests = RecordedRequests()
        StubURLProtocol.lock.withLock {
            StubURLProtocol.handler = { request in
                requests.append(request)
                return (500, [:], Data(#"{"error":"TMDB unavailable"}"#.utf8))
            }
        }
        let api = try client()
        defer { api.invalidate() }
        let identity = try resourceIdentity()
        let media = try await api.resourceMedia(for: identity)
        XCTAssertNil(media)
        XCTAssertEqual(requests.all.count, 2)
        api.invalidate()
        do {
            _ = try await api.resourceMedia(for: identity)
            XCTFail("Cancelled poster lookups must stop instead of trying more candidates.")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(requests.all.count, 2)
    }

    func testTitleSearchCombinesMovieAndTVResultsAndTracksPagination() async throws {
        let requests = RecordedRequests()
        StubURLProtocol.lock.withLock {
            StubURLProtocol.handler = { request in
                requests.append(request)
                let parts = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
                let query = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
                let kind = query["kind"]!
                let more = kind == "movie"
                return (200, [:], Data("""
                {"items":[{"id":42,"kind":"\(kind)","title":"Example","source":"tmdb"}],
                "page":\(query["page"]!),"total_pages":4,"has_more":\(more),"source":"tmdb","stale":false}
                """.utf8))
            }
        }
        let api = try client()
        defer { api.invalidate() }
        let page = try await api.searchTitles("  A&B + 测试  ", page: 2, refresh: true)
        XCTAssertEqual(page.items.map(\.kind), ["movie", "tv"])
        XCTAssertEqual(Set(page.items.map(\.stableID)).count, 2)
        XCTAssertEqual(page.remainingKinds, [.movie])
        XCTAssertEqual(requests.all.count, 2)
        for request in requests.all {
            let parts = try XCTUnwrap(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
            let query = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(parts.path, "/cinema/api/resources/explore")
            XCTAssertEqual(query, [
                "source": "tmdb", "kind": query["kind"]!, "q": "A&B + 测试", "page": "2", "refresh": "1"
            ])
        }
        let next = try await api.searchTitles("A&B + 测试", page: 3, kinds: Array(page.remainingKinds))
        XCTAssertEqual(next.items.map(\.kind), ["movie"])
        XCTAssertEqual(requests.all.count, 3)
    }

    func testEmptyAndOversizedTitleSearchesNeverRequestRecommendations() async throws {
        let requests = RecordedRequests()
        StubURLProtocol.lock.withLock {
            StubURLProtocol.handler = { request in
                requests.append(request)
                XCTFail("Blank or oversized titles must not issue a request.")
                return (200, [:], Data("{}".utf8))
            }
        }
        let api = try client()
        defer { api.invalidate() }
        let page = try await api.searchTitles(" \n ")
        XCTAssertTrue(page.items.isEmpty)
        XCTAssertTrue(page.remainingKinds.isEmpty)
        do {
            _ = try await api.searchTitles(String(repeating: "片", count: 67))
            XCTFail("Oversized titles must fail validation.")
        } catch {
            guard case APIError.validation = error else { return XCTFail("Expected a title validation error.") }
        }
        XCTAssertTrue(requests.all.isEmpty)
    }

    func testNativeCatalogResolutionUsesServerMatchingEndpoint() async throws {
        let requests = RecordedRequests()
        StubURLProtocol.lock.withLock {
            StubURLProtocol.handler = { request in
                requests.append(request)
                return (200, [:], Data("""
                {"matched":true,"media":{"id":42,"kind":"tv","title":"Example Show","year":2026}}
                """.utf8))
            }
        }
        let api = try client()
        defer { api.invalidate() }
        let item = try APIClient.decoder.decode(MediaItem.self, from: Data("""
        {"id":0,"origin_id":"native-42","source":"bangumi","kind":"tv","title":"Example Show","year":2026}
        """.utf8))
        let result = try await api.resolveCatalog(item)
        XCTAssertTrue(result.matched)
        XCTAssertEqual(result.media?.tmdbID, 42)
        XCTAssertEqual(requests.all.first?.httpMethod, "POST")
        XCTAssertEqual(requests.all.first?.url?.path, "/cinema/api/resources/catalog/resolve")
    }

    func testPostersUseAuthenticatedBackendProxyForEachCatalog() async throws {
        let requests = RecordedRequests()
        let imageData = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).pngData { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        StubURLProtocol.lock.withLock {
            StubURLProtocol.handler = { request in
                requests.append(request)
                return (200, ["Content-Type": "image/png"], imageData)
            }
        }
        let api = try client()
        defer { api.invalidate() }
        for path in [
            "/tmdb.jpg", "https://img1.doubanio.com/view/photo/s_ratio_poster/public/p123.jpg",
            "https://m.media-amazon.com/images/M/example.jpg", "https://lain.bgm.tv/pic/cover/l/example.jpg"
        ] {
            _ = try await api.poster(path)
        }
        XCTAssertEqual(requests.all.map { $0.url!.path }, [
            "/cinema/api/tmdb/image", "/cinema/api/resources/rankings/image",
            "/cinema/api/resources/catalog/image", "/cinema/api/resources/catalog/image"
        ])
        XCTAssertTrue(requests.all.allSatisfy { $0.url?.host == "example.test" })
    }

    private func resourceIdentity(kind: String = "", tmdbID: Int = 0) throws -> ResourceMediaIdentity {
        let data = try JSONSerialization.data(withJSONObject: [
            "title": "名称: Example Show (2026)", "channel": "channel", "kind": kind,
            "post_url": "https://t.me/channel/1", "share_url": "https://115.com/s/example",
            "type": "share", "tmdb_id": tmdbID
        ] as [String: Any])
        let result = try APIClient.decoder.decode(ResourceResult.self, from: data)
        return ResourceMediaIdentity(result)
    }
}
