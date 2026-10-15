import Foundation

struct ResourceMediaIdentity: Hashable {
    let title: String
    let year: Int
    let kind: MediaKind?
    let tmdbID: Int

    init(_ result: ResourceResult) {
        var name = result.title.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(
            of: #"^(?:(?:剧集|电影|名称|片名)\s*[:：]\s*)+"#,
            with: "", options: .regularExpression
        )
        if let range = name.range(of: #"[(（][12][0-9]{3}[)）]"#, options: .regularExpression) {
            year = Int(name[range].filter(\.isNumber)) ?? 0
            name = String(name[..<range.lowerBound])
        } else {
            year = 0
        }
        if let range = name.range(
            of: #"\b(?:S[0-9]{1,3}(?:E[0-9]{1,4})?|E[0-9]{1,4})\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) {
            name = String(name[..<range.lowerBound])
        }
        name = name.replacingOccurrences(
            of: #"\s+(?:蓝光\s*)?(?:(?:2160|1080|720)[pi]|4k|8k|uhd|blu-ray|bluray|web-dl|remux)\b.*$"#,
            with: "", options: [.regularExpression, .caseInsensitive]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        title = name.isEmpty ? result.title : name
        kind = MediaKind(rawValue: result.kind ?? "")
        tmdbID = result.tmdbID ?? 0
    }

    func matches(_ media: MediaItem) -> Bool {
        guard media.tmdbID > 0, tmdbID == 0 || tmdbID == media.tmdbID,
              year == 0 || year == (media.year ?? 0) else { return false }
        let name = Self.normalizedTitle(title)
        return !name.isEmpty && [media.title, media.originalTitle ?? ""].contains {
            Self.normalizedTitle($0) == name
        }
    }

    private static func normalizedTitle(_ value: String) -> String {
        value.lowercased().replacingOccurrences(of: "[^\\p{L}\\p{N}]", with: "", options: .regularExpression)
    }
}

extension APIClient {
    func resourceMedia(for identity: ResourceMediaIdentity) async throws -> MediaItem? {
        if identity.tmdbID > 0, let kind = identity.kind {
            do {
                let media: MediaItem = try await get("api/resources/rankings/tmdb/\(kind.rawValue)/\(identity.tmdbID)")
                if media.kind == kind.rawValue, identity.matches(media) { return media }
            } catch {
                if isCancellation(error) { throw error }
            }
        }
        guard !identity.title.isEmpty else { return nil }
        let kinds = identity.kind.map { [$0] } ?? MediaKind.allCases
        let matches = try await resourceMediaCandidates(for: identity, kinds: kinds)
        if !matches.isEmpty { return matches.count == 1 ? matches.first : nil }
        // Channel headings occasionally label a series as a movie, or vice versa.
        if let kind = identity.kind {
            let alternatives = try await resourceMediaCandidates(for: identity, kinds: [kind == .movie ? .tv : .movie])
            return alternatives.count == 1 ? alternatives.first : nil
        }
        return nil
    }

    private func resourceMediaCandidates(for identity: ResourceMediaIdentity, kinds: [MediaKind]) async throws -> [MediaItem] {
        var matches: [MediaItem] = []
        for kind in kinds {
            do {
                let values: [MediaItem]? = try await get("api/tmdb/search", query: [
                    URLQueryItem(name: "query", value: identity.title),
                    URLQueryItem(name: "kind", value: kind.rawValue),
                    URLQueryItem(name: "year", value: identity.year > 0 ? String(identity.year) : "")
                ])
                matches += (values ?? []).filter { $0.kind == kind.rawValue && identity.matches($0) }
            } catch {
                if isCancellation(error) { throw error }
            }
        }
        return matches
    }
}
