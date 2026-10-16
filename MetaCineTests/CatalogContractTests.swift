import XCTest
@testable import MetaCine

@MainActor
final class CatalogContractTests: XCTestCase {
    func testMaoyanImageAddressesNormalizeToSupportedProxyURLs() async throws {
        let expected = "https://p0.meituan.net/movie/example.jpg"
        for address in [
            expected, "//p0.meituan.net/movie/example.jpg",
            "http://p0.meituan.net/w.h/movie/example.jpg",
            expected + "@160w_220h_1e_1c", expected + "?imageView2/1/w/160/h/220"
        ] {
            let resource = try PosterResource(address)
            XCTAssertEqual(resource.endpoint, "api/resources/catalog/image")
            XCTAssertEqual(resource.query, [URLQueryItem(name: "url", value: expected)])
            XCTAssertEqual(resource.cacheKey, try PosterResource(expected).cacheKey)
        }
        let pipi = try PosterResource("//p1.pipi.cn/mediaplus/example.jpg?imageView2/1/w/160")
        XCTAssertEqual(pipi.query.first?.value, "https://p1.pipi.cn/mediaplus/example.jpg")
        XCTAssertThrowsError(try PosterResource("http://unknown.test/movie/example.jpg"))
        XCTAssertThrowsError(try PosterResource("//unknown.test/movie/example.jpg"))
    }

    func testRecommendationProvidersMatchBackendBoards() async throws {
        XCTAssertEqual(RecommendationProvider.all.map(\.id), [
            "popular", "netflix", "hbo", "apple", "disney", "crunchyroll",
            "prime", "amazon", "hulu", "maoyan", "douban", "tencent"
        ])
        let filter = RecommendationFilter()
        XCTAssertEqual(filter.categories.map(\.id), [
            "imdb_popular_movie", "imdb_popular_tv", "tmdb_trending",
            "anilist_trending", "bangumi_calendar_today"
        ])
        XCTAssertEqual(filter.endpoint, "api/resources/recommendations")
        XCTAssertEqual(values(filter.query(category: "tmdb_trending", refresh: true)), [
            "provider": "popular", "category": "tmdb_trending", "page": "1", "refresh": "1"
        ])
    }

    func testStreamingProviderChangesResetCategoryAndUnsupportedRegion() async throws {
        var filter = RecommendationFilter()
        filter.selectProvider("netflix")
        filter.region = "KR"
        filter.category = "tv"
        XCTAssertEqual(filter.endpoint, "api/resources/rankings")
        XCTAssertEqual(values(filter.query(category: "tv")), [
            "provider": "netflix", "source": "re0", "kind": "tv", "region": "KR", "page": "1"
        ])
        filter.selectProvider("prime")
        XCTAssertEqual(filter.category, "all")
        XCTAssertEqual(filter.region, "US")
        XCTAssertEqual(filter.categories.map(\.id), ["movie", "tv"])
        XCTAssertEqual(filter.provider.regions.map(\.id), ["US", "GB", "DE"])
        filter.category = "movie"
        XCTAssertEqual(filter.categories.map(\.id), ["movie"])
        filter.selectProvider("douban")
        XCTAssertEqual(filter.categories.count, 19)
        XCTAssertTrue(filter.categories.contains { $0.id == "movie_top250" })
    }

    func testNativeCatalogIDsStayDistinctAndNeverBecomeTMDBIDs() async throws {
        for source in ["anilist", "bangumi", "imdb", "maoyan", "tencent", "douban"] {
            let item = try media(source: source, id: 42, originID: "native-42")
            XCTAssertEqual(item.tmdbID, 0, source)
            XCTAssertEqual(item.subscription().tmdbID, 0, source)
            XCTAssertEqual(AvailabilityRequest.AvailabilityItem(item).tmdbID, 0, source)
            XCTAssertEqual(item.stableID, "\(source):movie:native-42")
        }
        XCTAssertEqual(try media(source: "tmdb", id: 42).tmdbID, 42)
        XCTAssertEqual(try media(source: "re0", id: 42).tmdbID, 42)
        XCTAssertNotEqual(
            try media(source: "tencent", originID: "one").stableID,
            try media(source: "tencent", originID: "two").stableID
        )
        XCTAssertNotEqual(
            try media(source: "re0", title: "First").stableID,
            try media(source: "re0", title: "Second").stableID
        )
    }

    func testRecommendationPageDecodesNativeArtworkAndStaleCache() async throws {
        let json = """
        {"items":[{"id":0,"kind":"movie","title":"Example","source":"imdb","origin_id":"tt123",
        "image_url":"https://m.media-amazon.com/images/M/example.jpg","poster":"","heat":"1234"}],
        "page":1,"total_pages":1,"has_more":false,"source":"imdb","stale":true}
        """
        let page = try APIClient.decoder.decode(RankingPage.self, from: Data(json.utf8))
        let item = try XCTUnwrap(page.items?.first)
        XCTAssertEqual(item.originID, "tt123")
        XCTAssertEqual(item.imageURL, "https://m.media-amazon.com/images/M/example.jpg")
        XCTAssertEqual(item.artwork, item.imageURL)
        XCTAssertEqual(item.heat, "1234")
        XCTAssertTrue(page.stale == true)
        XCTAssertFalse(page.hasMore)
        XCTAssertEqual(item.stableID, "imdb:movie:tt123")
    }

    func testNativeRankingBadgeMatchesResolvedSubscriptionsByOriginalTitle() async throws {
        let item = try media(source: "imdb", originID: "tt123", title: "Example")
        let subscription = try APIClient.decoder.decode(ResourceSubscription.self, from: Data("""
        {"id":"sub1","title":"本地片名","original_title":"Example","kind":"movie","tmdb_id":42,
        "year":2026,"resource_type":"any","interval_minutes":60,"enabled":true,"created_at":"2026-10-16T10:00:00Z"}
        """.utf8))
        XCTAssertTrue(subscription.matches(item))
        XCTAssertFalse(subscription.matches(try media(source: "tmdb", id: 43, title: "Example")))
        XCTAssertTrue(subscription.matches(try media(source: "tmdb", id: 42, title: "Another title")))
    }

    private func values(_ query: [URLQueryItem]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
    }

    private func media(source: String, id: Int = 0, originID: String = "", title: String = "Example") throws -> MediaItem {
        let data = try JSONSerialization.data(withJSONObject: [
            "id": id, "kind": "movie", "title": title, "year": 2026, "source": source, "origin_id": originID
        ] as [String: Any])
        return try APIClient.decoder.decode(MediaItem.self, from: data)
    }
}
