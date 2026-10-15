import Foundation
import UIKit

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
struct QueryBody: Encodable { let query: String }
struct TransferBody: Encodable { let text: String }
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
    private let images = NSCache<NSString, UIImage>()
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

    init(profile: ServerProfile, credential: ServerCredential, configuration: URLSessionConfiguration = .ephemeral) throws {
        self.profile = profile
        self.credential = credential
        self.baseURL = try ServerProfile.normalizedURL(profile.address)
        configuration.timeoutIntervalForRequest = 100
        configuration.timeoutIntervalForResource = 120
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.httpCookieAcceptPolicy = .always
        self.session = URLSession(configuration: configuration, delegate: RedirectPolicy(), delegateQueue: nil)
        images.totalCostLimit = 40 * 1024 * 1024
    }

    func invalidate() {
        invalidated = true
        authentication?.cancel()
        authentication = nil
        session.invalidateAndCancel()
        images.removeAllObjects()
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
        retryAuthentication: Bool = true
    ) async throws -> Data {
        guard !invalidated else { throw CancellationError() }
        try Task.checkCancellation()
        var request = URLRequest(url: try url(path: path, query: query))
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard !invalidated else { throw CancellationError() }
        guard let response = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        if response.statusCode == 401, retryAuthentication {
            try await authenticate()
            return try await self.request(path, query: query, method: method, body: body, retryAuthentication: false)
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
        if let cached = images.object(forKey: path as NSString) { return cached }
        let endpoint: String
        let query: [URLQueryItem]
        if path.hasPrefix("https://") {
            endpoint = "api/resources/rankings/image"
            query = [URLQueryItem(name: "url", value: path)]
        } else {
            endpoint = "api/tmdb/image"
            query = [URLQueryItem(name: "path", value: path), URLQueryItem(name: "size", value: "w500")]
        }
        let data = try await request(endpoint, query: query)
        guard let image = UIImage(data: data) else { throw APIError.invalidResponse }
        images.setObject(image, forKey: path as NSString, cost: Int(image.size.width * image.size.height * 4))
        return image
    }
}
