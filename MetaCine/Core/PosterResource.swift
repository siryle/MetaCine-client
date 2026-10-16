import Foundation

struct PosterResource {
    let endpoint: String
    let query: [URLQueryItem]
    var cacheKey: String { endpoint + "?" + query.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&") }

    init(_ address: String) throws {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private static func tmdbQuery(_ path: String) -> [URLQueryItem] {
        [URLQueryItem(name: "path", value: path), URLQueryItem(name: "size", value: "w342")]
    }
}
