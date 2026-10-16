import Foundation

struct PosterResource {
    let endpoint: String
    let query: [URLQueryItem]
    var cacheKey: String { endpoint + "?" + query.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&") }

    init(_ address: String) throws {
        let address = Self.normalizedAddress(address)
        if let url = URL(string: address), url.scheme == "https", url.user == nil, url.password == nil {
            if url.host == "image.tmdb.org", url.path.hasPrefix("/t/p/") {
                endpoint = "api/tmdb/image"
                query = Self.tmdbQuery("/" + url.lastPathComponent)
            } else {
                let host = url.host ?? ""
                endpoint = host.hasPrefix("img") && host.hasSuffix(".doubanio.com")
                    ? "api/resources/rankings/image" : "api/resources/catalog/image"
                query = [URLQueryItem(name: "url", value: address)]
            }
        } else if address.hasPrefix("/"), !address.hasPrefix("//"),
                  !address.contains(".."), !address.contains("?"), !address.contains("#"),
                  !address.contains("\\"), address.dropFirst().contains("/") == false {
            endpoint = "api/tmdb/image"
            query = Self.tmdbQuery(address)
        } else {
            throw APIError.validation("海报地址无效。")
        }
    }

    private static func normalizedAddress(_ address: String) -> String {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let absolute = address.hasPrefix("//") ? "https:" + address : address
        guard var parts = URLComponents(string: absolute),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              ["p0.meituan.net", "p1.meituan.net", "p0.pipi.cn", "p1.pipi.cn"].contains(parts.host ?? ""),
              parts.user == nil, parts.password == nil, parts.port == nil else { return address }
        parts.scheme = "https"
        parts.path = parts.path.replacingOccurrences(of: "/w.h/", with: "/")
        if let suffix = parts.path.firstIndex(of: "@") {
            parts.path = String(parts.path[..<suffix])
        }
        parts.query = nil
        parts.fragment = nil
        return parts.string ?? address
    }

    private static func tmdbQuery(_ path: String) -> [URLQueryItem] {
        [URLQueryItem(name: "path", value: path), URLQueryItem(name: "size", value: "w342")]
    }
}
