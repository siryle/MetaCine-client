import Foundation

struct MediaLibraryStatus: Equatable {
    let inLibrary: Bool
    let subscribed: Bool

    var canSubscribe: Bool { !subscribed && !inLibrary }
    var title: String { subscribed ? "已订阅" : inLibrary ? "已入库" : "订阅" }
}

private struct LibraryStatusResponse: Decodable {
    let inLibrary: [Bool]
    let subscribed: [Bool]
}

extension APIClient {
    func libraryStatuses(for items: [AvailabilityRequest.AvailabilityItem]) async throws -> [MediaLibraryStatus] {
        guard !items.isEmpty, items.count <= 50 else {
            throw APIError.validation("每次可检查 1 至 50 部作品的库存和订阅状态。")
        }
        let response: LibraryStatusResponse = try await send(
            "POST", "api/resources/library-status", body: AvailabilityRequest(items: items)
        )
        guard response.inLibrary.count == items.count, response.subscribed.count == items.count else {
            throw APIError.invalidResponse
        }
        return zip(response.inLibrary, response.subscribed).map {
            MediaLibraryStatus(inLibrary: $0.0, subscribed: $0.1)
        }
    }

    func libraryIdentity(for item: MediaItem) async throws -> AvailabilityRequest.AvailabilityItem {
        guard item.source?.hasPrefix("douban") == true else {
            return AvailabilityRequest.AvailabilityItem(item)
        }
        var detail: MediaDetail?
        if let id = item.doubanID, !id.isEmpty, id.allSatisfy(\.isNumber) {
            detail = try await get(
                "api/resources/rankings/douban/\(id)", query: [URLQueryItem(name: "kind", value: item.kind)]
            )
        }
        let resolution = try await resolveCatalog(item, detail: detail)
        if resolution.matched, let media = resolution.media, media.tmdbID > 0, media.kind == item.kind {
            return AvailabilityRequest.AvailabilityItem(media)
        }
        return AvailabilityRequest.AvailabilityItem(item, detail: detail)
    }
}
