import Foundation
import UIKit
import ImageIO

enum APIError: LocalizedError {
    case validation(String)
    case http(Int, String)
    case invalidResponse
    case decoding
    case signedOut
    case serverChanged

    var errorDescription: String? {
        switch self {
        case .validation(let message): message
        case .http(let status, let message):
            message.isEmpty ? "服务器返回 HTTP \(status)。" : message
        case .invalidResponse: "服务器返回了无效响应，请检查地址是否指向 MetaCine。"
        case .decoding: "响应格式不兼容，请确认服务端版本及反向代理配置。"
        case .signedOut: "请在服务器页面填写有效的账号密码或令牌，然后重新连接。"
        case .serverChanged: "服务器已切换，请重新操作。"
        }
    }

    var isUnauthorized: Bool {
        if case .http(401, _) = self { return true }
        if case .signedOut = self { return true }
        return false
    }
}

struct EmptyBody: Encodable {}
struct TransferBody: Encodable {
    let text: String
    var media: ResourceMediaHint?
}
struct DeleteJobsBody: Encodable { let ids: [String] }

// Reject redirects instead of forwarding login bodies or cookies to another origin.
final class RedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let from = task.originalRequest?.url, let to = request.url,
              from.scheme == to.scheme, from.host == to.host,
              Self.port(from) == Self.port(to) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    private static func port(_ url: URL) -> Int { url.port ?? (url.scheme == "https" ? 443 : 80) }
}

@MainActor
final class APIClient {
    let id = UUID()
    let profile: ServerProfile
    let baseURL: URL
    private let credential: ServerCredential
    private let session: URLSession
    private let posterCache: PosterCache
    private let posterCacheScope: String
    private let images = NSCache<NSString, UIImage>()
    private let posterPaths = NSCache<NSString, NSString>()
    private var imageRequests: [String: Task<UIImage, Error>] = [:]
    private var posterResolutions: [String: Task<String?, Error>] = [:]
    private var authentication: Task<Void, Error>?
    private var invalidated = false

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }

    init(
        profile: ServerProfile, credential: ServerCredential,
        configuration: URLSessionConfiguration = .ephemeral, posterCache: PosterCache = .shared
    ) throws {
        self.profile = profile
        self.credential = credential
        self.baseURL = try ServerProfile.normalizedURL(profile.address)
        self.posterCache = posterCache
        self.posterCacheScope = "\(profile.id):\(baseURL.absoluteString):\(profile.authMethod.rawValue):"
            + PosterCache.fingerprint(try Self.encoder.encode(credential))
        configuration.timeoutIntervalForRequest = 100
        configuration.timeoutIntervalForResource = 120
        configuration.waitsForConnectivity = false
        // Keep authenticated artwork cached in memory, isolated to this server connection.
        configuration.urlCache = URLCache(memoryCapacity: 24 * 1024 * 1024, diskCapacity: 0, diskPath: nil)
        configuration.httpCookieAcceptPolicy = .always
        self.session = URLSession(configuration: configuration, delegate: RedirectPolicy(), delegateQueue: nil)
        images.totalCostLimit = 40 * 1024 * 1024
        posterPaths.countLimit = 300
    }

    func invalidate() {
        invalidated = true
        authentication?.cancel()
        authentication = nil
        imageRequests.values.forEach { $0.cancel() }
        imageRequests.removeAll()
        posterResolutions.values.forEach { $0.cancel() }
        posterResolutions.removeAll()
        session.configuration.urlCache?.removeAllCachedResponses()
        session.invalidateAndCancel()
        images.removeAllObjects()
        posterPaths.removeAllObjects()
    }

    func url(path: String, query: [URLQueryItem] = []) throws -> URL {
        var parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        parts.path = baseURL.path + "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        parts.queryItems = query.isEmpty ? nil : query
        guard let url = parts.url else { throw APIError.validation("请求地址无效。") }
        return url
    }

    func connect() async throws -> ServerSession {
        try await authenticate()
        return try await get("api/session")
    }

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let data = try await request(path, query: query)
        return try decode(data)
    }

    func send<T: Decodable, Body: Encodable>(
        _ method: String, _ path: String, body: Body
    ) async throws -> T {
        let data = try await request(path, method: method, body: Self.encoder.encode(body))
        return try decode(data)
    }

    func perform<Body: Encodable>(_ method: String, _ path: String, body: Body) async throws {
        _ = try await request(path, method: method, body: Self.encoder.encode(body))
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try Self.decoder.decode(T.self, from: data) }
        catch { throw APIError.decoding }
    }

    private func request(
        _ path: String, query: [URLQueryItem] = [], method: String = "GET", body: Data? = nil,
        retryAuthentication: Bool = true, artwork: Bool = false
    ) async throws -> Data {
        guard !invalidated else { throw CancellationError() }
        try Task.checkCancellation()
        var request = URLRequest(url: try url(path: path, query: query))
        request.httpMethod = method
        request.httpBody = body
        request.cachePolicy = artwork ? .useProtocolCachePolicy : .reloadIgnoringLocalCacheData
        request.setValue(artwork ? "image/*" : "application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard !invalidated else { throw CancellationError() }
        guard let response = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        if response.statusCode == 401, retryAuthentication {
            try await authenticate()
            return try await self.request(
                path, query: query, method: method, body: body, retryAuthentication: false, artwork: artwork
            )
        }
        guard (200..<300).contains(response.statusCode) else {
            struct ErrorResponse: Decodable { let error: String }
            var message = (try? Self.decoder.decode(ErrorResponse.self, from: data))?.error ?? ""
            if response.statusCode == 429 {
                message += " 请稍后重试（\(response.value(forHTTPHeaderField: "Retry-After") ?? "60") 秒）。"
            }
            throw APIError.http(response.statusCode, message)
        }
        return data
    }

    private func authenticate() async throws {
        if let authentication { return try await authentication.value }
        let task = Task { @MainActor in
            let auth: AuthStatus = try self.decode(
                await self.request("api/auth", retryAuthentication: false)
            )
            if auth.authenticated { return }
            let body: [String: String]
            switch self.profile.authMethod {
            case .password:
                guard !self.credential.username.isEmpty, !self.credential.password.isEmpty else {
                    throw APIError.signedOut
                }
                body = ["username": self.credential.username, "password": self.credential.password]
            case .token:
                guard !self.credential.token.isEmpty else { throw APIError.signedOut }
                body = ["token": self.credential.token]
            }
            let result: AuthStatus = try self.decode(await self.request(
                "api/auth/login", method: "POST", body: Self.encoder.encode(body), retryAuthentication: false
            ))
            guard result.authenticated else { throw APIError.signedOut }
        }
        authentication = task
        defer { authentication = nil }
        try await task.value
    }

    func poster(_ path: String) async throws -> UIImage {
        guard !invalidated else { throw CancellationError() }
        try Task.checkCancellation()
        let resource = try PosterResource(path)
        let key = resource.cacheKey
        if let cached = images.object(forKey: key as NSString) { return cached }
        if let pending = imageRequests[key] {
            let image = try await pending.value
            try Task.checkCancellation()
            return image
        }
        let task = Task {
            let diskKey = self.posterCacheScope + ":image:" + key
            let image: UIImage
            if let data = await self.posterCache.data(for: diskKey),
               let cached = try? await Self.decodePoster(data) {
                image = cached
            } else {
                await self.posterCache.remove(diskKey)
                let data = try await self.request(resource.endpoint, query: resource.query, artwork: true)
                image = try await Self.decodePoster(data)
                try Task.checkCancellation()
                guard !self.invalidated else { throw CancellationError() }
                await self.posterCache.store(data, for: diskKey)
            }
            try Task.checkCancellation()
            guard !self.invalidated else { throw CancellationError() }
            self.images.setObject(
                image, forKey: key as NSString,
                cost: (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0)
            )
            return image
        }
        imageRequests[key] = task
        defer { imageRequests[key] = nil }
        let image = try await task.value
        try Task.checkCancellation()
        return image
    }

    private static func decodePoster(_ data: Data) async throws -> UIImage {
        try await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 600,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { throw APIError.invalidResponse }
            return UIImage(cgImage: thumbnail)
        }.value
    }

    func cachedPoster(path: String?, fallback item: MediaItem?) -> UIImage? {
        guard !invalidated else { return nil }
        let resolved = item.flatMap { posterPaths.object(forKey: $0.stableID as NSString) }.map { $0 as String }
        let candidates = [resolved, path, item?.poster]
        for case let path? in candidates {
            if let resource = try? PosterResource(path),
               let image = images.object(forKey: resource.cacheKey as NSString) { return image }
        }
        return nil
    }

    private func posterPathKey(_ item: MediaItem) -> String {
        posterCacheScope + ":path:" + item.stableID + ":\(item.artwork ?? ""):\(item.poster ?? "")"
    }

    private func rememberPoster(_ path: String, for item: MediaItem) async {
        posterPaths.setObject(path as NSString, forKey: item.stableID as NSString)
        await posterCache.store(Data(path.utf8), for: posterPathKey(item))
    }

    private func forgetPoster(for item: MediaItem) async {
        posterPaths.removeObject(forKey: item.stableID as NSString)
        await posterCache.remove(posterPathKey(item))
    }

    func poster(path: String?, fallback item: MediaItem?) async throws -> UIImage? {
        guard !invalidated else { throw CancellationError() }
        try Task.checkCancellation()
        if let item, posterPaths.object(forKey: item.stableID as NSString) == nil,
           let data = await posterCache.data(for: posterPathKey(item)),
           let cached = String(data: data, encoding: .utf8) {
            try Task.checkCancellation()
            guard !invalidated else { throw CancellationError() }
            posterPaths.setObject(cached as NSString, forKey: item.stableID as NSString)
        }
        if let item, let cached = posterPaths.object(forKey: item.stableID as NSString) {
            do { return try await poster(cached as String) }
            catch {
                if isCancellation(error) || (error as? APIError)?.isUnauthorized == true { throw error }
                await forgetPoster(for: item)
            }
        }
        if let path, !path.isEmpty {
            do { return try await poster(path) }
            catch {
                if isCancellation(error) || (error as? APIError)?.isUnauthorized == true { throw error }
                guard item != nil else { throw error }
            }
        }
        guard let item else { return nil }
        if let alternate = item.poster, !alternate.isEmpty, alternate != path {
            do {
                let image = try await poster(alternate)
                await rememberPoster(alternate, for: item)
                return image
            }
            catch {
                if isCancellation(error) || (error as? APIError)?.isUnauthorized == true { throw error }
            }
        }
        guard let fallback = try await resolvedPoster(for: item), fallback != path else { return nil }
        do {
            let image = try await poster(fallback)
            await rememberPoster(fallback, for: item)
            return image
        }
        catch {
            if isCancellation(error) || (error as? APIError)?.isUnauthorized == true { throw error }
            await forgetPoster(for: item)
            throw error
        }
    }

    private func resolvedPoster(for item: MediaItem) async throws -> String? {
        guard !invalidated else { throw CancellationError() }
        let key = item.stableID
        if let cached = posterPaths.object(forKey: key as NSString) { return cached as String }
        if let pending = posterResolutions[key] {
            let path = try await pending.value
            try Task.checkCancellation()
            return path
        }
        let task = Task<String?, Error> {
            let path: String?
            if item.tmdbID > 0 {
                let detail: MediaDetail = try await self.get(
                    "api/resources/rankings/tmdb/\(item.kind)/\(item.tmdbID)"
                )
                path = detail.poster
            } else {
                let resolution = try await self.resolveCatalog(item)
                path = resolution.matched ? resolution.media?.artwork : nil
            }
            try Task.checkCancellation()
            if let path, !path.isEmpty { self.posterPaths.setObject(path as NSString, forKey: key as NSString) }
            return path
        }
        posterResolutions[key] = task
        defer { posterResolutions[key] = nil }
        let path = try await task.value
        try Task.checkCancellation()
        return path
    }
}
