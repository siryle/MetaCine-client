import Foundation

enum ResourceSource: String, Codable, CaseIterable, Identifiable {
    case all, re0, telegram
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "全部来源"
        case .re0: "RE0"
        case .telegram: "Telegram"
        }
    }
    var includesRE0: Bool { self != .telegram }
    static let providers: [Self] = [.re0, .telegram]
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

struct RE0UnlockBody: Encodable {
    let slug: String
    let allowPaid: Bool
    let maxPoints: Int

    init(_ result: ResourceResult) throws {
        guard result.needsUnlock, let slug = result.slug, !slug.isEmpty else {
            throw APIError.validation("RE0 资源缺少有效标识或已获取链接。")
        }
        guard result.unlocked == true || (result.unlockPoints.map { (0...10000).contains($0) } ?? false) else {
            throw APIError.validation("资源积分未知或超过上限，请在 RE0 核对后重试。")
        }
        self.slug = slug
        allowPaid = result.unlocked != true && (result.unlockPoints ?? 0) > 0
        maxPoints = result.unlocked == true ? 0 : result.unlockPoints ?? 0
    }
}

struct RE0UnlockResponse: Decodable {
    let text: String
    let type: String
}

struct RE0UnlockConfig: Decodable {
    let maxPoints: Int
}

extension APIClient {
    func defaultUnlockPoints() async throws -> Int {
        let config: RE0UnlockConfig = try await get("api/re0/unlock/config")
        guard (0...10000).contains(config.maxPoints) else { throw APIError.invalidResponse }
        return config.maxPoints
    }

    func saveSubscription(_ draft: SubscriptionDraft) async throws -> ResourceSubscription {
        var value = try draft.validated()
        if value.maxPoints == nil {
            // PUT does not inherit defaults; existing subscriptions must keep their saved limit.
            if value.id == nil && value.source.includesRE0 {
                value.maxPoints = try await defaultUnlockPoints()
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
            throw APIError.validation("请分别查询 RE0 或 Telegram 资源。")
        }
        if source == .re0, let media, media.tmdbID <= 0 {
            throw APIError.validation("尚未匹配唯一 TMDB 条目，匹配后可查看 RE0 资源。")
        }
        return try await send("POST", "api/resources/search", body: ResourceSearchBody(
            query: query, source: source, media: source == .re0 ? media : nil
        ))
    }

    func unlockResource(_ result: ResourceResult) async throws -> ResourceResult {
        let response: RE0UnlockResponse = try await send(
            "POST", "api/re0/resources/unlock", body: RE0UnlockBody(result)
        )
        guard !response.text.isEmpty, response.type == result.type else { throw APIError.invalidResponse }
        var unlocked = result
        unlocked.shareURL = response.text
        unlocked.unlocked = true
        return unlocked
    }
}
