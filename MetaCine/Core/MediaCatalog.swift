import Foundation

struct CatalogChoice: Identifiable, Equatable {
    let id: String
    let title: String

    init(_ id: String, _ title: String) {
        self.id = id
        self.title = title
    }
}

struct RecommendationProvider: Identifiable {
    let id: String
    let title: String
    let categories: [CatalogChoice]
    var streaming: Bool { !["popular", "maoyan", "douban", "tencent"].contains(id) }
    var regions: [CatalogChoice] {
        let values = [CatalogChoice("US", "美国"), .init("KR", "韩国"), .init("GB", "英国"), .init("DE", "德国")]
        return ["prime", "amazon"].contains(id) ? values.filter { $0.id != "KR" } : values
    }

    private static let streamingCategories = [CatalogChoice("movie", "电影 Top 10"), .init("tv", "剧集 Top 10")]
    static let all: [Self] = [
        .init(id: "popular", title: "热门", categories: [
            .init("imdb_popular_movie", "IMDb 最热门电影"), .init("imdb_popular_tv", "IMDb 最热门剧集"),
            .init("tmdb_trending", "TMDB 趋势"), .init("anilist_trending", "AniList 热门"),
            .init("bangumi_calendar_today", "Bangumi 今日动漫")
        ]),
        .init(id: "netflix", title: "Netflix", categories: streamingCategories),
        .init(id: "hbo", title: "HBO", categories: streamingCategories),
        .init(id: "apple", title: "Apple TV+", categories: streamingCategories),
        .init(id: "disney", title: "Disney+", categories: streamingCategories),
        .init(id: "crunchyroll", title: "Crunchyroll", categories: streamingCategories),
        .init(id: "prime", title: "Amazon Prime", categories: streamingCategories),
        .init(id: "amazon", title: "Amazon", categories: streamingCategories),
        .init(id: "hulu", title: "Hulu", categories: streamingCategories),
        .init(id: "maoyan", title: "猫眼", categories: [
            .init("tv", "电视剧榜"), .init("web_tv", "网络剧榜"),
            .init("variety", "综艺榜"), .init("movie", "网络电影榜")
        ]),
        .init(id: "douban", title: "豆瓣", categories: [
            .init("movie_coming", "即将上映"), .init("movie_playing", "正在上映"),
            .init("movie_later", "近期热门电影"), .init("movie_new", "新片榜"),
            .init("movie_hot", "豆瓣热门电影"), .init("movie_realtime", "实时热门电影"),
            .init("movie_weekly", "一周口碑榜"), .init("movie_us_top", "北美票房榜"),
            .init("movie_top250", "豆瓣电影 Top250"), .init("tv_coming", "近期热门剧集"),
            .init("tv_realtime", "实时热门电视"), .init("tv_domestic", "近期热门国产剧"),
            .init("tv_korean", "近期热门韩剧"), .init("tv_japanese", "近期热门日剧"),
            .init("tv_american", "近期热门欧美剧"), .init("tv_variety_show", "近期热门综艺"),
            .init("tv_animation", "近期热门动画"), .init("tv_documentary", "近期热门纪录片"),
            .init("recommended", "豆瓣推荐")
        ]),
        .init(id: "tencent", title: "腾讯视频", categories: [
            .init("hot", "腾讯热播"), .init("tv", "腾讯电视剧"), .init("child", "腾讯少儿"),
            .init("movie", "腾讯电影"), .init("cartoon", "腾讯动漫"), .init("doco", "腾讯纪录片")
        ])
    ]
}

struct RecommendationFilter: Equatable {
    var providerID = "popular"
    var category = "all"
    var region = "US"

    var provider: RecommendationProvider {
        RecommendationProvider.all.first { $0.id == providerID } ?? RecommendationProvider.all[0]
    }
    var categories: [CatalogChoice] {
        provider.categories.filter { category == "all" || $0.id == category }
    }
    var endpoint: String { provider.streaming ? "api/resources/rankings" : "api/resources/recommendations" }

    mutating func selectProvider(_ id: String) {
        providerID = id
        category = "all"
        if !provider.regions.contains(where: { $0.id == region }) { region = "US" }
    }

    func query(category: String, refresh: Bool = false) -> [URLQueryItem] {
        var values = ["provider": providerID, "page": "1"]
        if provider.streaming {
            values["source"] = "re0"
            values["kind"] = category
            values["region"] = region
        } else {
            values["category"] = category
        }
        if refresh { values["refresh"] = "1" }
        return values.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
    }
}

struct MediaCatalogSection: Identifiable {
    let id: String
    var title = ""
    var items: [MediaItem] = []
    var loading = false
    var stale = false
    var error: String?
}

struct CatalogResolution: Decodable {
    let matched: Bool
    let media: MediaItem?
}

struct MediaTitleSearchPage {
    let items: [MediaItem]
    let remainingKinds: Set<MediaKind>
    let stale: Bool
}

extension APIClient {
    func searchTitles(
        _ title: String, page: Int = 1, kinds: [MediaKind] = MediaKind.allCases, refresh: Bool = false
    ) async throws -> MediaTitleSearchPage {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            return MediaTitleSearchPage(items: [], remainingKinds: [], stale: false)
        }
        guard title.utf8.count <= 200 else {
            throw APIError.validation("搜索片名最多 200 字节，请缩短关键词。")
        }
        return try await withThrowingTaskGroup(of: (MediaKind, RankingPage).self) { group in
            for kind in Set(kinds) {
                group.addTask {
                    var query = [
                        URLQueryItem(name: "source", value: "tmdb"),
                        URLQueryItem(name: "kind", value: kind.rawValue),
                        URLQueryItem(name: "q", value: title),
                        URLQueryItem(name: "page", value: String(page))
                    ]
                    if refresh { query.append(URLQueryItem(name: "refresh", value: "1")) }
                    let result: RankingPage = try await self.get("api/resources/explore", query: query)
                    return (kind, result)
                }
            }
            var pages: [MediaKind: RankingPage] = [:]
            for try await (kind, result) in group { pages[kind] = result }
            try Task.checkCancellation()
            var items: [MediaItem] = []
            // Interleave movie and TV matches while preserving each source's result order.
            let count = pages.values.map { $0.items?.count ?? 0 }.max() ?? 0
            for index in 0..<count {
                for kind in MediaKind.allCases {
                    if let values = pages[kind]?.items, index < values.count { items.append(values[index]) }
                }
            }
            return MediaTitleSearchPage(
                items: items, remainingKinds: Set(pages.filter { $0.value.hasMore }.map { $0.key }),
                stale: pages.values.contains { $0.stale == true }
            )
        }
    }

    func resolveCatalog(_ item: MediaItem, detail: MediaDetail? = nil) async throws -> CatalogResolution {
        struct Hint: Encodable {
            let title: String
            let originalTitle: String
            let kind: String
            let year: Int
        }
        return try await send("POST", "api/resources/catalog/resolve", body: Hint(
            title: detail?.title ?? item.title, originalTitle: detail?.originalTitle ?? item.originalTitle ?? "",
            kind: item.kind, year: detail?.year ?? item.year ?? 0
        ))
    }
}
