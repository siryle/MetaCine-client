import Foundation

enum ResourceSource: String, Codable, CaseIterable, Identifiable {
    case all, re0, hdhaven, telegram
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "全部来源"
        case .re0: "RE0"
        case .hdhaven: "HDHaven"
        case .telegram: "Telegram"
        }
    }
    var supportsUnlock: Bool { self == .re0 || self == .hdhaven }
    var usesUnlockPoints: Bool { self != .telegram }
    var unlockProvider: Self { self == .hdhaven ? .hdhaven : .re0 }
    static let providers: [Self] = [.re0, .hdhaven, .telegram]
}

struct ResourceMediaHint: Encodable {
    let title: String
    let originalTitle: String
    let tmdbID: Int
    let kind: String
    let year: Int
    var season: Int

    init(_ draft: SubscriptionDraft) {
        title = draft.title
        originalTitle = draft.originalTitle
        tmdbID = draft.tmdbID
        kind = draft.kind.rawValue
        year = draft.year
        season = draft.kind == .tv ? draft.season : 0
    }

    func matchesQuery(_ query: String) -> Bool {
        let name = Self.normalized(query)
        return !name.isEmpty && [title, originalTitle].contains { Self.normalized($0) == name }
    }

    func matches(_ result: ResourceResult) -> Bool {
        if let kind = result.kind, !kind.isEmpty, kind != self.kind { return false }
        if tmdbID > 0, let id = result.tmdbID, id > 0, id != tmdbID { return false }
        let identity = ResourceMediaIdentity(result)
        if kind == "movie", year > 0, identity.year > 0, year != identity.year { return false }
        return season == 0 || (result.season ?? 0) == 0 || season == result.season
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased().replacingOccurrences(of: "[^\\p{L}\\p{N}]", with: "", options: .regularExpression)
    }
}

struct ResourceSearchBody: Encodable {
    let query: String
    let source: ResourceSource
    var media: ResourceMediaHint?
}

struct ResourceUnlockBody: Encodable {
    let slug: String
    let allowPaid: Bool
    let maxPoints: Int
    let tmdbID: Int?
    let kind: String?

    init(_ result: ResourceResult) throws {
        guard result.needsUnlock, let slug = result.slug, !slug.isEmpty else {
            throw APIError.validation("\(result.resourceSource.title) 资源缺少有效标识或已获取链接。")
        }
        guard result.unlocked == true || (result.unlockPoints.map { (0...10000).contains($0) } ?? false) else {
            throw APIError.validation("资源积分未知或超过上限，请在 \(result.resourceSource.title) 核对后重试。")
        }
        if result.resourceSource == .hdhaven {
            guard (result.tmdbID ?? 0) > 0, MediaKind(rawValue: result.kind ?? "") != nil else {
                throw APIError.validation("HDHaven 解锁需要有效的 TMDB ID 和媒体类型。")
            }
        }
        self.slug = slug
        allowPaid = result.unlocked != true && (result.unlockPoints ?? 0) > 0
        maxPoints = result.unlocked == true ? 0 : result.unlockPoints ?? 0
        tmdbID = result.resourceSource == .hdhaven ? result.tmdbID : nil
        kind = result.resourceSource == .hdhaven ? result.kind : nil
    }
}

struct ResourceUnlockResponse: Decodable {
    let text: String
    let type: String
}

struct ResourceUnlockConfig: Decodable {
    let maxPoints: Int
}

extension APIClient {
    func defaultUnlockPoints(source: ResourceSource = .re0) async throws -> Int {
        let config: ResourceUnlockConfig = try await get(
            source == .hdhaven ? "api/hdhaven/config" : "api/re0/unlock/config"
        )
        guard (0...10000).contains(config.maxPoints) else { throw APIError.invalidResponse }
        return config.maxPoints
    }

    func saveSubscription(_ draft: SubscriptionDraft) async throws -> ResourceSubscription {
        var value = try draft.validated()
        if value.maxPoints == nil {
            // PUT does not inherit defaults; existing subscriptions must keep their saved limit.
            if value.id == nil && value.source.usesUnlockPoints {
                value.maxPoints = try await defaultUnlockPoints(source: value.source)
            } else {
                value.maxPoints = 0
            }
        }
        try Task.checkCancellation()
        let path = "api/resources/subscriptions" + (value.id.map { "/\($0)" } ?? "")
        return try await send(value.id == nil ? "POST" : "PUT", path, body: value)
    }

    func searchResources(
        _ query: String, source: ResourceSource, media: ResourceMediaHint? = nil
    ) async throws -> SearchResponse {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.utf8.count <= 200 else {
            throw APIError.validation("请输入 1–200 字节的搜索关键词。")
        }
        guard ResourceSource.providers.contains(source) else {
            throw APIError.validation("请分别查询 RE0、HDHaven 或 Telegram 资源。")
        }
        let hint = media.flatMap { $0.matchesQuery(query) ? $0 : nil }
        return try await send("POST", "api/resources/search", body: ResourceSearchBody(
            query: query, source: source, media: source.supportsUnlock ? hint : nil
        ))
    }

    func unlockResource(_ result: ResourceResult) async throws -> ResourceResult {
        let response: ResourceUnlockResponse = try await send(
            "POST", "api/\(result.resourceSource.rawValue)/resources/unlock", body: ResourceUnlockBody(result)
        )
        guard !response.text.isEmpty, response.type == result.type else { throw APIError.invalidResponse }
        var unlocked = result
        unlocked.shareURL = response.text
        unlocked.unlocked = true
        return unlocked
    }
}
