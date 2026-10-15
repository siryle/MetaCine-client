import Foundation

enum MediaKind: String, Codable, CaseIterable, Identifiable {
    case movie, tv
    var id: String { rawValue }
    var title: String { self == .movie ? "电影" : "电视剧" }
}

enum ResourceKind: String, Codable, CaseIterable, Identifiable {
    case any, share, magnet, ed2k
    var id: String { rawValue }
    var title: String {
        switch self {
        case .any: "全部类型"
        case .share: "115 分享"
        case .magnet: "磁力链接"
        case .ed2k: "电驴链接"
        }
    }
}

struct ServerProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var address: String
    var authMethod: AuthMethod = .password

    enum AuthMethod: String, Codable, CaseIterable, Identifiable {
        case password, token
        var id: String { rawValue }
        var title: String { self == .password ? "账号密码" : "访问令牌" }
    }

    static func normalizedURL(_ input: String) throws -> URL {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: value),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else {
            throw APIError.validation("请输入完整的 HTTP 或 HTTPS 服务地址，不要包含账号、查询参数或锚点。")
        }
        parts.scheme = parts.scheme?.lowercased()
        var path = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path == "api" { path = "" }
        else if path.hasSuffix("/api") { path = String(path.dropLast(4)) }
        guard !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw APIError.validation("服务地址不能包含相对路径。")
        }
        parts.path = path.isEmpty ? "" : "/" + path
        guard let url = parts.url else { throw APIError.validation("服务地址无效。") }
        return url
    }
}

struct ServerCredential: Codable, Equatable {
    var username = ""
    var password = ""
    var token = ""
}

struct AuthStatus: Decodable {
    let authenticated: Bool
    let passwordLogin: Bool?
    let tokenLogin: Bool?
}

struct ServerSession: Decodable {
    let name: String
    let version: String
    let mediaRoot: String
    let tmdbConfigured: Bool
}

struct RankingPage: Decodable {
    let items: [MediaItem]?
    let page: Int
    let totalPages: Int
    let hasMore: Bool
    let source: String
}

struct MediaActor: Decodable {
    let name: String
    let role: String?
}

struct MediaItem: Decodable, Identifiable {
    let id: Int
    let kind: String
    let title: String
    let originalTitle: String?
    let year: Int?
    let overview: String?
    let poster: String?
    let rating: Double?
    let genres: [String]?
    let directors: [String]?
    let cast: [MediaActor]?
    let source: String?
    let doubanID: String?

    enum CodingKeys: String, CodingKey {
        case id, kind, title, originalTitle, year, overview, poster, rating, genres, directors, cast, source
        case doubanID = "doubanId"
    }

    // Douban's numeric ID is never a TMDB identity.
    var tmdbID: Int { source?.hasPrefix("douban") == true ? 0 : id }
    var stableID: String { "\(source ?? "tmdb"):\(kind):\(doubanID ?? String(id))" }
    var mediaKind: MediaKind { MediaKind(rawValue: kind) ?? .movie }
    var subtitle: String {
        [year.flatMap { $0 > 0 ? String($0) : nil }, mediaKind.title]
            .compactMap { $0 }.joined(separator: " · ")
    }

    func subscription() -> SubscriptionDraft {
        var draft = SubscriptionDraft()
        draft.title = title
        draft.originalTitle = originalTitle ?? ""
        draft.tmdbID = tmdbID
        draft.kind = mediaKind
        draft.year = year ?? 0
        draft.poster = poster ?? ""
        return draft
    }
}

struct MediaDetail: Decodable {
    let title: String?
    let originalTitle: String?
    let year: Int?
    let overview: String?
    let poster: String?
    let rating: Double?
    let genres: [String]?
    let directors: [String]?
    let cast: [MediaActor]?
    let actors: [String]?
    let duration: String?
    let runtime: Int?
    let region: String?
    let episodes: String?

    var actorNames: [String] { actors ?? cast?.map(\.name) ?? [] }
}

struct AvailabilityRequest: Encodable {
    let items: [AvailabilityItem]
    struct AvailabilityItem: Encodable {
        let title: String
        let originalTitle: String
        let tmdbID: Int
        let kind: String
        let year: Int
        init(_ media: MediaItem) {
            title = media.title
            originalTitle = media.originalTitle ?? ""
            tmdbID = media.tmdbID
            kind = media.kind
            year = media.year ?? 0
        }
    }
}

struct AvailabilityResponse: Decodable { let available: [Bool] }

struct SearchResponse: Decodable {
    let results: [ResourceResult]?
    let warnings: [String]?
}

struct ResourceResult: Decodable, Identifiable {
    let title: String
    let channel: String
    let postURL: String
    let shareURL: String
    let type: String
    let tmdbID: Int?
    let kind: String?
    let season: Int?
    let episode: Int?
    let rawText: String?
    let details: [String: String]?

    enum CodingKeys: String, CodingKey {
        case title, channel, type, kind, season, episode, rawText, details
        case postURL = "postUrl"
        case shareURL = "shareUrl"
        case tmdbID = "tmdbId"
    }

    var id: String { "\(channel):\(postURL):\(shareURL)" }
    var resourceKind: ResourceKind { ResourceKind(rawValue: type) ?? .any }
    var specifications: String {
        ["resolution", "size", "source", "created"]
            .compactMap { details?[$0] }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
    func subscription() -> SubscriptionDraft {
        var draft = SubscriptionDraft()
        draft.title = title
        draft.kind = MediaKind(rawValue: kind ?? "") ?? .movie
        draft.tmdbID = tmdbID ?? 0
        draft.season = draft.kind == .tv ? (season ?? 0) : 0
        draft.resourceType = resourceKind
        return draft
    }
}

struct ResourceSubscription: Decodable, Identifiable {
    let id: String
    let title: String
    let originalTitle: String?
    let tmdbID: Int?
    let kind: String
    let year: Int?
    let poster: String?
    let season: Int?
    let resourceType: String
    let quality: String?
    let intervalMinutes: Int
    let enabled: Bool
    let createdAt: String
    let lastChecked: String?
    let lastJobID: String?
    let lastJobStatus: String?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case id, title, originalTitle, kind, year, poster, season, resourceType, quality
        case intervalMinutes, enabled, createdAt, lastChecked, lastJobStatus, message
        case tmdbID = "tmdbId"
        case lastJobID = "lastJobId"
    }

    var draft: SubscriptionDraft {
        SubscriptionDraft(
            id: id, title: title, originalTitle: originalTitle ?? "", tmdbID: tmdbID ?? 0,
            kind: MediaKind(rawValue: kind) ?? .movie, year: year ?? 0, poster: poster ?? "",
            season: season ?? 0, resourceType: ResourceKind(rawValue: resourceType) ?? .any,
            quality: quality ?? "", intervalMinutes: intervalMinutes, enabled: enabled
        )
    }
}

struct SubscriptionDraft: Encodable, Identifiable {
    var id: String?
    var title = ""
    var originalTitle = ""
    var tmdbID = 0
    var kind: MediaKind = .movie
    var year = 0
    var poster = ""
    var season = 0
    var resourceType: ResourceKind = .any
    var quality = ""
    var intervalMinutes = 60
    var enabled = true

    func validated() throws -> Self {
        var value = self
        value.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        value.originalTitle = originalTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        value.quality = quality.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == .movie { value.season = 0 }
        guard !value.title.isEmpty, value.title.utf8.count <= 200,
              value.originalTitle.utf8.count <= 200 else {
            throw APIError.validation("作品名称必填，名称和原名最多各 200 字节。")
        }
        guard tmdbID >= 0, year == 0 || (1900...2100).contains(year),
              (0...999).contains(value.season) else {
            throw APIError.validation("年份须为 1900–2100 或 0，季数须为 0–999，TMDB ID 不能为负数。")
        }
        guard (30...10080).contains(intervalMinutes), value.quality.utf8.count <= 100 else {
            throw APIError.validation("检查间隔须为 30–10080 分钟，版本关键词最多 100 字节。")
        }
        return value
    }

    mutating func clearMediaIdentity() {
        tmdbID = 0
        originalTitle = ""
        poster = ""
    }
}

struct JobRule: Decodable {
    let name: String
    let mode: String
    let kind: String?
    let source: String?
    let destination: String?
}

struct Job: Decodable, Identifiable {
    let id: String
    let rule: JobRule
    let status: String
    let createdAt: String
    let updatedAt: String
    let entries: [JobEntry]?
    let scanned: Int
    let processed: Int
    let message: String
    let warnings: [String]?

    var isActive: Bool { ["scanning", "executing", "deduplicating"].contains(status) }
    var isProblem: Bool { ["failed", "error", "partial", "interrupted"].contains(status) }
    var progress: Double { scanned > 0 ? min(Double(processed) / Double(scanned), 1) : 0 }
}

struct JobEntry: Decodable, Identifiable {
    let id: String
    let source: String
    let destination: String
    let status: String
    let message: String
    let size: Int64
}

struct JobDeletionResponse: Decodable {
    let deleted: [String]
    let skipped: [String]
    let failures: [String: String]?
    let storageError: String?
}

struct TransferResponse: Decodable {
    let job: Job
    let duplicate: Bool
}

enum JobStatus {
    static func title(_ value: String) -> String {
        [
            "scanning": "扫描中", "executing": "执行中", "deduplicating": "去重中",
            "preview": "待确认", "completed": "已完成", "partial": "部分完成",
            "failed": "失败", "error": "错误", "cancelled": "已取消",
            "interrupted": "已中断", "ready": "就绪", "skipped": "已跳过",
            "moved": "已移动", "pending": "等待中", "matched": "已匹配",
            "done": "已完成", "unmatched": "待匹配"
        ][value] ?? value
    }
}

enum ServerDate {
    static func parse(_ value: String?) -> Date? {
        guard let value, !value.hasPrefix("0001-") else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    static func display(_ value: String?) -> String {
        parse(value)?.formatted(date: .abbreviated, time: .shortened) ?? "尚无记录"
    }
}
