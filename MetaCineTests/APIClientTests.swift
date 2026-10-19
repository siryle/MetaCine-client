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

private func requestJSON(_ request: URLRequest) throws -> [String: Any] {
    var data = request.httpBody ?? Data()
    if data.isEmpty, let stream = request.httpBodyStream {
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? APIError.invalidResponse }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func savedSubscription(_ values: [String: Any]) throws -> Data {
    var body = values
    body["id"] = body["id"] ?? "sub1"
    body["created_at"] = "2026-10-16T10:00:00Z"
    return try JSONSerialization.data(withJSONObject: body)
}

@MainActor
final class APIClientTests: XCTestCase {
    private func client(
        profile: ServerProfile = ServerProfile(name: "测试", address: "http://example.test:8080/cinema"),
        credential: ServerCredential = ServerCredential(username: "admin", password: "secret"),
        posterCache: PosterCache = .shared
    ) throws -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return try APIClient(
            profile: profile, credential: credential, configuration: configuration, posterCache: posterCache
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
            "https://m.media-amazon.com/images/M/example.jpg", "https://lain.bgm.tv/pic/cover/l/example.jpg",
            "https://s4.anilist.co/file/anilistcdn/media/anime/cover/large/example.jpg",
            "https://p0.meituan.net/movie/example.jpg", "https://vcover-hz-pic.puui.qpic.cn/vcover_hz_pic/example"
        ] {
            _ = try await api.poster(path)
        }
        XCTAssertEqual(requests.all.map { $0.url!.path }, [
            "/cinema/api/tmdb/image", "/cinema/api/resources/rankings/image",
            "/cinema/api/resources/catalog/image", "/cinema/api/resources/catalog/image",
            "/cinema/api/resources/catalog/image",
            "/cinema/api/resources/catalog/image", "/cinema/api/resources/catalog/image"
        ])
        XCTAssertTrue(requests.all.allSatisfy { $0.url?.host == "example.test" })
        XCTAssertTrue(requests.all.allSatisfy { $0.value(forHTTPHeaderField: "Accept") == "image/*" })
    }

    func testOneClickSubscriptionLoadsAccountLimitBeforeSavingAllSources() async throws {
        let requests = RecordedRequests()
        StubURLProtocol.lock.withLock {
            StubURLProtocol.handler = { request in
                requests.append(request)
                if request.url!.path.hasSuffix("/unlock/config") {
                    return (200, [:], Data(#"{"max_points":7}"#.utf8))
                }
                let body = try requestJSON(request)
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(body["source"] as? String, "all")
                XCTAssertEqual(body["auto_unlock"] as? Bool, true)
                XCTAssertEqual(body["max_points"] as? Int, 7)
                return (200, [:], try savedSubscription(body))
            }
        }
        let api = try client()
        defer { api.invalidate() }
        let saved = try await api.saveSubscription(SubscriptionDraft(title: "Example", tmdbID: 42))
        XCTAssertEqual(saved.maxPoints, 7)
        XCTAssertEqual(requests.all.map { $0.url!.path }, [
            "/cinema/api/re0/unlock/config", "/cinema/api/resources/subscriptions"
        ])
    }

    func testExplicitLimitsAndSubscriptionEditsDoNotReadAccountDefaults() async throws {
        let requests = RecordedRequests()
        StubURLProtocol.lock.withLock {
            StubURLProtocol.handler = { request in
                requests.append(request)
                XCTAssertTrue(request.url!.path.contains("/subscriptions"))
                return (200, [:], try savedSubscription(requestJSON(request)))
            }
        }
        let api = try client()
        defer { api.invalidate() }
        let saved = try await api.saveSubscription(SubscriptionDraft(title: "Example", maxPoints: 0))
        XCTAssertEqual(saved.maxPoints, 0)
        var paused = saved.draft
        paused.enabled = false
        paused.maxPoints = 3
        let edited = try await api.saveSubscription(paused)
        XCTAssertEqual(edited.maxPoints, 3)
        XCTAssertFalse(edited.enabled)
        XCTAssertEqual(requests.all.map(\.httpMethod), ["POST", "PUT"])
        XCTAssertEqual(requests.all.last?.url?.path, "/cinema/api/resources/subscriptions/sub1")
    }

    func testFailedOrInvalidAccountDefaultNeverCreatesSubscription() async throws {
        for source in [ResourceSource.all, .re0, .hdhaven] {
            let provider = source == .hdhaven ? "hdhaven" : "re0"
            for (status, response) in [(500, #"{"error":"Settings unavailable"}"#), (200, #"{"max_points":-1}"#),
                                       (200, #"{"max_points":10001}"#), (200, #"{"max_points":null}"#)] {
                let requests = RecordedRequests()
                StubURLProtocol.lock.withLock {
                    StubURLProtocol.handler = { request in
                        requests.append(request)
                        return (status, [:], Data(response.utf8))
                    }
                }
                let api = try client()
                do {
                    _ = try await api.saveSubscription(SubscriptionDraft(title: "Example", tmdbID: 42, source: source))
                    XCTFail("A missing account limit must not silently allow spending or save a zero limit.")
                } catch {
                    XCTAssertEqual(requests.all.map { $0.url!.path }, ["/cinema/api/\(provider)/unlock/config"])
                }
                api.invalidate()
            }
        }
    }

    func testIndependentSubscriptionsDefaultToFreeWithoutRE0Configuration() async throws {
        let requests = RecordedRequests()
        StubURLProtocol.lock.withLock {
            StubURLProtocol.handler = { request in
                requests.append(request)
                XCTAssertEqual(request.httpMethod, "POST")
                return (200, [:], try savedSubscription(requestJSON(request)))
            }
        }
        let api = try client()
        defer { api.invalidate() }
        for source in [ResourceSource.telegram, .jying] {
            let saved = try await api.saveSubscription(SubscriptionDraft(title: "Example", tmdbID: 42, source: source))
            XCTAssertEqual(saved.maxPoints, 0)
            XCTAssertEqual(saved.resourceSource, source)
        }
        XCTAssertEqual(requests.all.count, 2)
        XCTAssertTrue(requests.all.allSatisfy { $0.url!.path.hasSuffix("/resources/subscriptions") })
    }

    func testHDHavenSubscriptionReadsCurrentServerLimitWithoutRE0Configuration() async throws {
        let requests = RecordedRequests()
        StubURLProtocol.lock.withLock {
            StubURLProtocol.handler = { request in
                requests.append(request)
                if request.url!.path == "/cinema/api/hdhaven/unlock/config" {
                    let reads = requests.all.filter { $0.httpMethod == "GET" }.count
                    return (200, [:], Data("{\"max_points\":\(reads == 1 ? 6 : 9)}".utf8))
                }
                XCTAssertEqual(request.url!.path, "/cinema/api/resources/subscriptions")
                XCTAssertEqual(request.httpMethod, "POST")
                let body = try requestJSON(request)
                XCTAssertEqual(body["source"] as? String, "hdhaven")
                XCTAssertEqual(body["auto_unlock"] as? Bool, true)
                return (200, [:], try savedSubscription(body))
            }
        }
        let api = try client()
        defer { api.invalidate() }
        for points in [6, 9] {
            let saved = try await api.saveSubscription(SubscriptionDraft(title: "Example", tmdbID: 42, source: .hdhaven))
            XCTAssertEqual(saved.maxPoints, points)
            XCTAssertEqual(saved.resourceSource, .hdhaven)
        }
        XCTAssertEqual(requests.all.map { $0.url!.path }, [
            "/cinema/api/hdhaven/unlock/config", "/cinema/api/resources/subscriptions",
            "/cinema/api/hdhaven/unlock/config", "/cinema/api/resources/subscriptions"
        ])
    }

    func testUnlockDefaultsRouteBySourceAndDoNotRequestSettingsForDirectLinks() async throws {
        let requests = RecordedRequests()
        StubURLProtocol.lock.withLock {
            StubURLProtocol.handler = { request in
                requests.append(request)
                let points = request.url!.path.contains("/hdhaven/") ? 5 : 3
                return (200, [:], Data("{\"max_points\":\(points)}".utf8))
            }
        }
        let api = try client()
        defer { api.invalidate() }
        for source in ResourceSource.allCases {
            let points = try await api.defaultUnlockPoints(for: source)
            XCTAssertEqual(points, source == .hdhaven ? 5 : source.usesUnlockPoints ? 3 : 0)
        }
        XCTAssertEqual(requests.all.map { $0.url!.path }, [
            "/cinema/api/re0/unlock/config", "/cinema/api/re0/unlock/config", "/cinema/api/hdhaven/unlock/config"
        ])
    }

    func testHDHavenSubscriptionPreservesExplicitPaidLimitAndEdits() async throws {
        let requests = RecordedRequests()
        StubURLProtocol.lock.withLock {
            StubURLProtocol.handler = { request in
                requests.append(request)
                XCTAssertTrue(request.url!.path.contains("/subscriptions"))
                return (200, [:], try savedSubscription(requestJSON(request)))
            }
        }
        let api = try client()
        defer { api.invalidate() }
        let saved = try await api.saveSubscription(SubscriptionDraft(
            title: "Example", tmdbID: 42, source: .hdhaven, maxPoints: 6
        ))
        var draft = saved.draft
        draft.enabled = false
        let edited = try await api.saveSubscription(draft)
        XCTAssertEqual(edited.resourceSource, .hdhaven)
        XCTAssertEqual(edited.maxPoints, 6)
        XCTAssertEqual(edited.autoUnlock, true)
        XCTAssertFalse(edited.enabled)
        XCTAssertEqual(requests.all.map(\.httpMethod), ["POST", "PUT"])
    }

    func testResourceSearchUsesAllProvidersAndKeepsFailuresIndependent() async throws {
        let requests = RecordedRequests()
        StubURLProtocol.lock.withLock {
            StubURLProtocol.handler = { request in
                requests.append(request)
                let body = try requestJSON(request)
                XCTAssertEqual(body["query"] as? String, "Example")
                if body["source"] as? String == "re0" {
                    XCTAssertEqual((body["media"] as? [String: Any])?["tmdb_id"] as? Int, 42)
                    return (503, [:], Data(#"{"error":"RE0 unavailable"}"#.utf8))
                }
                if body["source"] as? String == "telegram" {
                    XCTAssertNil(body["media"])
                } else {
                    XCTAssertTrue(["hdhaven", "jying"].contains(body["source"] as? String ?? ""))
                    XCTAssertEqual((body["media"] as? [String: Any])?["tmdb_id"] as? Int, 42)
                }
                return (200, [:], Data(#"{"results":[],"warnings":["Channel unavailable"]}"#.utf8))
            }
        }
        let api = try client()
        defer { api.invalidate() }
        let hint = ResourceMediaHint(SubscriptionDraft(title: "Example", tmdbID: 42))
        do {
            _ = try await api.searchResources(" Example ", source: .re0, media: hint)
            XCTFail("RE0 failure must be reported independently.")
        } catch { XCTAssertEqual(error.localizedDescription, "RE0 unavailable") }
        let telegram = try await api.searchResources(" Example ", source: .telegram, media: hint)
        XCTAssertEqual(telegram.warnings, ["Channel unavailable"])
        for source in [ResourceSource.hdhaven, .jying] {
            let response = try await api.searchResources(" Example ", source: source, media: hint)
            XCTAssertEqual(response.results?.count, 0)
        }
        do {
            _ = try await api.searchResources("Example", source: .all)
            XCTFail("Providers must be searched independently.")
        } catch { }
        XCTAssertEqual(ResourceSource.providers, [.re0, .telegram, .hdhaven, .jying])
        XCTAssertEqual(ResourceSource.allCases, [.all, .re0, .telegram, .hdhaven, .jying])
        XCTAssertEqual(requests.all.count, 4)
    }

    func testRE0CanResolveNativeTitlesWithoutTMDBIdentity() async throws {
        let requests = RecordedRequests()
        StubURLProtocol.lock.withLock {
            StubURLProtocol.handler = { request in
                requests.append(request)
                let body = try requestJSON(request)
                let hint = try XCTUnwrap(body["media"] as? [String: Any])
                XCTAssertEqual(hint["tmdb_id"] as? Int, 0)
                XCTAssertEqual(hint["kind"] as? String, "tv")
                return (200, [:], Data(#"{"results":[]}"#.utf8))
            }
        }
        let api = try client()
        defer { api.invalidate() }
        let hint = ResourceMediaHint(SubscriptionDraft(title: "Example", kind: .tv))
        _ = try await api.searchResources("Example", source: .re0, media: hint)
        XCTAssertEqual(requests.all.count, 1)
    }

    func testEditedSearchQueryDoesNotReusePreviousMediaIdentity() async throws {
        StubURLProtocol.lock.withLock {
            StubURLProtocol.handler = { request in
                let body = try requestJSON(request)
                XCTAssertEqual(body["query"] as? String, "Another")
                XCTAssertNil(body["media"])
                return (200, [:], Data(#"{"results":[]}"#.utf8))
            }
        }
        let api = try client()
        defer { api.invalidate() }
        let hint = ResourceMediaHint(SubscriptionDraft(title: "Example", tmdbID: 42))
        for source in ResourceSource.providers {
            _ = try await api.searchResources("Another", source: source, media: hint)
        }
    }

    func testTitleOnlySearchReachesAllProvidersWithoutMediaHint() async throws {
        let requests = RecordedRequests()
        StubURLProtocol.lock.withLock {
            StubURLProtocol.handler = { request in
                requests.append(request)
                let body = try requestJSON(request)
                XCTAssertNil(body["media"])
                return (200, [:], Data(#"{"results":[]}"#.utf8))
            }
        }
        let api = try client()
        defer { api.invalidate() }
        for source in ResourceSource.providers {
            _ = try await api.searchResources("Example", source: source)
        }
        XCTAssertEqual(requests.all.count, 4)
    }

    func testRE0UnlockOnlyObtainsLinkAndNeverSubmitsTransfer() async throws {
        let requests = RecordedRequests()
        StubURLProtocol.lock.withLock {
            StubURLProtocol.handler = { request in
                requests.append(request)
                XCTAssertEqual(request.url?.path, "/cinema/api/re0/resources/unlock")
                let body = try requestJSON(request)
                XCTAssertEqual(body["slug"] as? String, "0123456789abcdef0123456789abcdef")
                XCTAssertEqual(body["allow_paid"] as? Bool, true)
                XCTAssertEqual(body["max_points"] as? Int, 4)
                XCTAssertNil(body["tmdb_id"])
                XCTAssertNil(body["kind"])
                return (200, [:], Data(#"{"text":"https://115.com/s/example?password=abc1","type":"share"}"#.utf8))
            }
        }
        let api = try client()
        defer { api.invalidate() }
        let result = try APIClient.decoder.decode(ResourceResult.self, from: Data("""
        {"source":"re0","slug":"0123456789abcdef0123456789abcdef","unlock_points":4,
        "title":"Example","channel":"RE0","post_url":"https://re0.me/resource/example","share_url":"","type":"share"}
        """.utf8))
        let unlocked = try await api.unlockResource(result)
        XCTAssertEqual(unlocked.id, result.id)
        XCTAssertEqual(unlocked.shareURL, "https://115.com/s/example?password=abc1")
        XCTAssertTrue(unlocked.unlocked == true)
        XCTAssertEqual(requests.all.count, 1)
    }

    func testNewProviderLinkAccessUsesDedicatedEndpointsWithoutTransfer() async throws {
        let requests = RecordedRequests()
        StubURLProtocol.lock.withLock {
            StubURLProtocol.handler = { request in
                requests.append(request)
                XCTAssertEqual(request.httpMethod, "POST")
                let body = try requestJSON(request)
                switch request.url!.path {
                case "/cinema/api/hdhaven/resources/unlock":
                    XCTAssertEqual(body["slug"] as? String, "0123456789abcdef0123456789abcdef")
                    XCTAssertEqual(body["allow_paid"] as? Bool, true)
                    XCTAssertEqual(body["max_points"] as? Int, 4)
                case "/cinema/api/jying/resources/access":
                    XCTAssertEqual(body["slug"] as? String, "123/456")
                    XCTAssertEqual(Set(body.keys), ["slug"])
                default:
                    XCTFail("Link access must never submit a transfer or use another provider's endpoint.")
                }
                return (200, [:], Data(#"{"text":"https://115.com/s/example?password=abc1","type":"share"}"#.utf8))
            }
        }
        let api = try client()
        defer { api.invalidate() }
        for source in [ResourceSource.hdhaven, .jying] {
            let slug = source == .jying ? "123/456" : "0123456789abcdef0123456789abcdef"
            let result = try APIClient.decoder.decode(ResourceResult.self, from: Data("""
            {"source":"\(source.rawValue)","slug":"\(slug)","unlock_points":4,
            "title":"Example","channel":"\(source.title)","post_url":"https://example.test/resource",
            "share_url":"","type":"share","details":{"accessible":"true"}}
            """.utf8))
            let unlocked = try await api.unlockResource(result)
            XCTAssertEqual(unlocked.id, result.id)
            XCTAssertEqual(unlocked.shareURL, "https://115.com/s/example?password=abc1")
            XCTAssertFalse(unlocked.needsUnlock)
        }
        XCTAssertEqual(requests.all.count, 2)
    }

    func testNewProviderLinkFailuresAreNotRetried() async throws {
        let requests = RecordedRequests()
        StubURLProtocol.lock.withLock {
            StubURLProtocol.handler = { request in
                requests.append(request)
                return (503, [:], Data(#"{"error":"Provider unavailable"}"#.utf8))
            }
        }
        let api = try client()
        defer { api.invalidate() }
        for source in [ResourceSource.hdhaven, .jying] {
            let slug = source == .jying ? "123/456" : "0123456789abcdef0123456789abcdef"
            let result = try APIClient.decoder.decode(ResourceResult.self, from: Data("""
            {"source":"\(source.rawValue)","slug":"\(slug)","unlock_points":0,
            "title":"Example","channel":"provider","post_url":"https://example.test/resource",
            "share_url":"","type":"share"}
            """.utf8))
            do {
                _ = try await api.unlockResource(result)
                XCTFail("Provider failure must be reported without retrying.")
            } catch { XCTAssertEqual(error.localizedDescription, "Provider unavailable") }
        }
        XCTAssertEqual(requests.all.count, 2)
    }

    func testPostersCoalesceConcurrentRequestsAndReuseNormalizedTMDBPaths() async throws {
        let requests = RecordedRequests()
        let imageData = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 1200)).pngData { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 800, height: 1200))
        }
        StubURLProtocol.lock.withLock {
            StubURLProtocol.handler = { request in
                requests.append(request)
                XCTAssertEqual(request.cachePolicy, .useProtocolCachePolicy)
                XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "image/*")
                return (200, ["Content-Type": "image/png"], imageData)
            }
        }
        let api = try client()
        defer { api.invalidate() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<8 {
                group.addTask {
                    let path = index.isMultiple(of: 2) ? "/poster.jpg" : "https://image.tmdb.org/t/p/original/poster.jpg"
                    let image = try await api.poster(path)
                    XCTAssertLessThanOrEqual(max(image.cgImage!.width, image.cgImage!.height), 600)
                }
            }
            try await group.waitForAll()
        }
        _ = try await api.poster("/poster.jpg")
        XCTAssertEqual(requests.all.count, 1)
        let parts = try XCTUnwrap(URLComponents(url: requests.all[0].url!, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.path, "/cinema/api/tmdb/image")
        XCTAssertEqual(parts.queryItems?.first(where: { $0.name == "size" })?.value, "w342")
        api.invalidate()
        do {
            _ = try await api.poster("/poster.jpg")
            XCTFail("An invalidated client must not return cached artwork.")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testMissingAndBrokenRankingPostersUseBackendTMDBFallback() async throws {
        for source in ["re0", "imdb"] {
            let requests = RecordedRequests()
            let imageData = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).pngData { _ in }
            StubURLProtocol.lock.withLock {
                StubURLProtocol.handler = { request in
                    requests.append(request)
                    switch request.url!.lastPathComponent {
                    case "image":
                        let broken = request.url!.query?.contains("broken.jpg") == true
                        return broken ? (404, [:], Data()) : (200, ["Content-Type": "image/png"], imageData)
                    case "resolve":
                        return (200, [:], Data("""
                        {"matched":true,"media":{"id":42,"source":"tmdb","kind":"movie","title":"Example","poster":"/fallback.jpg"}}
                        """.utf8))
                    default:
                        return (200, [:], Data(#"{"title":"Example","poster":"/fallback.jpg"}"#.utf8))
                    }
                }
            }
            let api = try client()
            let poster = source == "re0" ? "" : "/broken.jpg"
            let item = try APIClient.decoder.decode(MediaItem.self, from: Data("""
            {"id":42,"kind":"movie","title":"Example","source":"\(source)","poster":"\(poster)"}
            """.utf8))
            let image = try await api.poster(path: source == "re0" ? nil : item.artwork, fallback: item)
            XCTAssertNotNil(image)
            let count = requests.all.count
            XCTAssertEqual(count, source == "re0" ? 2 : 3)
            let cached = try await api.poster(path: item.artwork, fallback: item)
            XCTAssertNotNil(cached)
            XCTAssertEqual(requests.all.count, count)
            XCTAssertTrue(requests.all.contains { $0.url!.path.hasSuffix(source == "re0" ? "/tmdb/movie/42" : "/catalog/resolve") })
            api.invalidate()
        }
    }

    func testAmbiguousNativeArtworkDoesNotUseUnrelatedPoster() async throws {
        let requests = RecordedRequests()
        StubURLProtocol.lock.withLock {
            StubURLProtocol.handler = { request in
                requests.append(request)
                return (200, [:], Data(#"{"matched":false}"#.utf8))
            }
        }
        let api = try client()
        defer { api.invalidate() }
        let item = try APIClient.decoder.decode(MediaItem.self, from: Data("""
        {"id":123,"kind":"tv","source":"bangumi","title":"Example","image_url":""}
        """.utf8))
        let image = try await api.poster(path: item.artwork, fallback: item)
        XCTAssertNil(image)
        XCTAssertEqual(requests.all.map { $0.url!.path }, ["/cinema/api/resources/catalog/resolve"])
    }

    func testMaoyanPosterAndResolvedPathSurviveNewClientAndCacheInstances() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let requests = RecordedRequests()
        let imageData = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).pngData { _ in }
        StubURLProtocol.lock.withLock {
            StubURLProtocol.handler = { request in
                requests.append(request)
                if request.url!.lastPathComponent == "resolve" {
                    return (200, [:], Data("""
                    {"matched":true,"media":{"id":42,"kind":"tv","title":"Example","poster":"/maoyan-fallback.jpg"}}
                    """.utf8))
                }
                return (200, ["Content-Type": "image/png"], imageData)
            }
        }
        let profile = ServerProfile(name: "Test", address: "http://example.test:8080/cinema")
        let item = try APIClient.decoder.decode(MediaItem.self, from: Data("""
        {"id":0,"kind":"tv","title":"Example","source":"maoyan","origin_id":"42","image_url":""}
        """.utf8))
        let first = try client(profile: profile, posterCache: PosterCache(directory: directory))
        let image = try await first.poster(path: item.artwork, fallback: item)
        XCTAssertNotNil(image)
        XCTAssertNotNil(first.cachedPoster(path: nil, fallback: item))
        first.invalidate()
        XCTAssertEqual(requests.all.count, 2)
        for _ in 0..<12 {
            let restoredClient = try client(
                profile: profile, credential: ServerCredential(username: "admin", password: "secret"),
                posterCache: PosterCache(directory: directory)
            )
            let restored = try await restoredClient.poster(path: item.artwork, fallback: item)
            XCTAssertNotNil(restored)
            XCTAssertNotNil(restoredClient.cachedPoster(path: nil, fallback: item))
            restoredClient.invalidate()
            XCTAssertEqual(requests.all.count, 2, "Disk hits must not re-resolve titles or download artwork.")
        }
    }

    func testPosterDiskCacheIsolatesServersAndCredentialsAndRecoversCorruptFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let requests = RecordedRequests()
        let imageData = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).pngData { _ in }
        StubURLProtocol.lock.withLock {
            StubURLProtocol.handler = { request in
                requests.append(request)
                return (200, ["Content-Type": "image/png"], imageData)
            }
        }
        let profile = ServerProfile(name: "Test", address: "http://example.test:8080/cinema")
        let first = try client(profile: profile, posterCache: PosterCache(directory: directory))
        _ = try await first.poster("/poster.jpg")
        first.invalidate()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        try Data("corrupt image".utf8).write(to: XCTUnwrap(files.first))
        let repaired = try client(profile: profile, posterCache: PosterCache(directory: directory))
        _ = try await repaired.poster("/poster.jpg")
        repaired.invalidate()
        XCTAssertEqual(requests.all.count, 2)
        let otherAccount = try client(
            profile: profile, credential: ServerCredential(username: "other", password: "secret"),
            posterCache: PosterCache(directory: directory)
        )
        _ = try await otherAccount.poster("/poster.jpg")
        otherAccount.invalidate()
        var otherServer = profile
        otherServer.address = "http://other.test:8080/cinema"
        let other = try client(profile: otherServer, posterCache: PosterCache(directory: directory))
        defer { other.invalidate() }
        _ = try await other.poster("/poster.jpg")
        XCTAssertEqual(requests.all.count, 4)
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
