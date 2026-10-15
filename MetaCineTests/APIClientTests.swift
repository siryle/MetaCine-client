import XCTest
@testable import MetaCine

private final class StubURLProtocol: URLProtocol {
    static let lock = NSLock()
    static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let handler = Self.lock.withLock { Self.handler }
            guard let handler else { throw URLError(.unknown) }
            let (status, headers, body) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private final class RecordedRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URLRequest] = []
    func append(_ request: URLRequest) { lock.withLock { values.append(request) } }
    var all: [URLRequest] { lock.withLock { values } }
}

@MainActor
final class APIClientTests: XCTestCase {
    private func client() throws -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return try APIClient(
            profile: ServerProfile(name: "测试", address: "http://example.test:8080/cinema"),
            credential: ServerCredential(username: "admin", password: "secret"),
            configuration: configuration
        )
    }

    func testURLCompositionPreservesServerSubpathAndEscapesQuery() async throws {
        let api = try client()
        defer { api.invalidate() }
        let url = try api.url(path: "api/resources/rankings", query: [
            URLQueryItem(name: "tag", value: "冷门佳片"),
            URLQueryItem(name: "query", value: "A&B + C")
        ])
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.path, "/cinema/api/resources/rankings")
        XCTAssertEqual(parts.queryItems?.first?.value, "冷门佳片")
        XCTAssertEqual(parts.queryItems?.last?.value, "A&B + C")
    }

    func testUnauthorizedRequestAuthenticatesAndRetriesOnce() async throws {
        let requests = RecordedRequests()
        StubURLProtocol.lock.withLock {
            StubURLProtocol.handler = { request in
                requests.append(request)
                let path = request.url!.path
                let status: Int
                let json: String
                if path.hasSuffix("/auth") { status = 200; json = #"{"authenticated":false}"# }
                else if path.hasSuffix("/auth/login") { status = 200; json = #"{"authenticated":true}"# }
                else if requests.all.filter({ $0.url!.path.hasSuffix("/jobs") }).count == 1 {
                    status = 401; json = #"{"error":"expired"}"#
                } else { status = 200; json = "[]" }
                return (status, ["Content-Type": "application/json"], Data(json.utf8))
            }
        }
        let api = try client()
        defer { api.invalidate() }
        let jobs: [Job] = try await api.get("api/jobs")
        XCTAssertTrue(jobs.isEmpty)
        XCTAssertEqual(requests.all.map { $0.url!.lastPathComponent }, ["jobs", "auth", "login", "jobs"])
        XCTAssertEqual(requests.all[2].httpMethod, "POST")
        XCTAssertEqual(requests.all[2].value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testAuthenticationFailureDoesNotLoop() async throws {
        let requests = RecordedRequests()
        StubURLProtocol.lock.withLock {
            StubURLProtocol.handler = { request in
                requests.append(request)
                if request.url!.path.hasSuffix("/auth") {
                    return (200, [:], Data(#"{"authenticated":false}"#.utf8))
                }
                return (401, [:], Data(#"{"error":"凭据无效"}"#.utf8))
            }
        }
        let api = try client()
        defer { api.invalidate() }
        do {
            let _: [Job] = try await api.get("api/jobs")
            XCTFail("Invalid credentials must throw.")
        } catch {
            XCTAssertEqual(error.localizedDescription, "凭据无效")
        }
        XCTAssertEqual(requests.all.count, 3)
    }

    func testBackendErrorsPreserveActionableMessage() async throws {
        StubURLProtocol.lock.withLock {
            StubURLProtocol.handler = { _ in (409, [:], Data(#"{"error":"已有任务运行"}"#.utf8)) }
        }
        let api = try client()
        defer { api.invalidate() }
        do {
            try await api.perform("POST", "api/resources/subscriptions/test/check", body: EmptyBody())
            XCTFail("A conflict must throw.")
        } catch {
            XCTAssertEqual(error.localizedDescription, "已有任务运行")
        }
    }

    func testInvalidatedClientNeverSendsAnotherRequest() async throws {
        let api = try client()
        api.invalidate()
        do {
            let _: [Job] = try await api.get("api/jobs")
            XCTFail("An invalidated server context must not issue requests.")
        } catch { XCTAssertTrue(error is CancellationError) }
    }
}
