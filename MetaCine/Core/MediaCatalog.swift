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

struct MediaExploreFilter: Equatable {
    var kind: MediaKind = .movie
    var query = ""
    var genre = ""
    var region = ""
    var year = ""
    var sort = "popular"

    var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var genres: [CatalogChoice] {
        kind == .movie ? [
            .init("28", "动作"), .init("12", "冒险"), .init("16", "动画"), .init("35", "喜剧"),
            .init("80", "犯罪"), .init("99", "纪录片"), .init("18", "剧情"), .init("10751", "家庭"),
            .init("14", "奇幻"), .init("36", "历史"), .init("27", "恐怖"), .init("10402", "音乐"),
            .init("9648", "悬疑"), .init("10749", "爱情"), .init("878", "科幻"), .init("53", "惊悚"),
            .init("10752", "战争"), .init("37", "西部")
        ] : [
            .init("10759", "动作冒险"), .init("16", "动画"), .init("35", "喜剧"), .init("80", "犯罪"),
            .init("99", "纪录片"), .init("18", "剧情"), .init("10751", "家庭"), .init("10762", "儿童"),
            .init("9648", "悬疑"), .init("10763", "新闻"), .init("10764", "真人秀"),
            .init("10765", "科幻奇幻"), .init("10766", "肥皂剧"), .init("10767", "脱口秀"),
            .init("10768", "战争政治"), .init("37", "西部")
        ]
    }
    static let regions: [CatalogChoice] = [
        .init("CN", "大陆"), .init("HK", "香港"), .init("TW", "台湾"), .init("JP", "日本"),
        .init("KR", "韩国"), .init("western", "欧美")
    ]
    static var years: [String] {
        stride(from: Calendar.current.component(.year, from: Date()), through: 2007, by: -1).map(String.init)
    }

    func query(page: Int, refresh: Bool = false) -> [URLQueryItem] {
        var values = ["source": "tmdb", "kind": kind.rawValue, "page": String(page), "year": year]
        if searching {
            values["q"] = query.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            values["genre"] = genre
            values["region"] = region
            values["sort"] = sort
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

extension APIClient {
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
