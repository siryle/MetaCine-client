import XCTest
@testable import MetaCine

@MainActor
final class ModelContractTests: XCTestCase {
    func testServerURLSupportsSubpathsAndOptionalAPISuffix() async throws {
        XCTAssertEqual(try ServerProfile.normalizedURL(" http://192.168.1.5:8080/cinema/api/ ").absoluteString, "http://192.168.1.5:8080/cinema")
        XCTAssertEqual(try ServerProfile.normalizedURL("https://example.com/api").absoluteString, "https://example.com")
        XCTAssertThrowsError(try ServerProfile.normalizedURL("https://user:secret@example.com"))
        XCTAssertThrowsError(try ServerProfile.normalizedURL("file:///tmp/server"))
        XCTAssertThrowsError(try ServerProfile.normalizedURL("https://example.com?token=secret"))
        XCTAssertThrowsError(try ServerProfile.normalizedURL("https://example.com/../api"))
    }

    func testDoubanIDCannotBecomeTMDBIdentity() async throws {
        let json = """
        {"id":0,"douban_id":"1292052","source":"douban","kind":"movie","title":"肖申克的救赎",
        "year":1994,"poster":"https://img1.doubanio.com/view/photo/s_ratio_poster/public/p.jpg","rating":9.7}
        """
        let media = try APIClient.decoder.decode(MediaItem.self, from: Data(json.utf8))
        XCTAssertEqual(media.doubanID, "1292052")
        XCTAssertEqual(media.tmdbID, 0)
        XCTAssertEqual(media.subscription().tmdbID, 0)
        XCTAssertEqual(media.subscription().year, 1994)
    }

    func testSearchContractPreservesLinksAndAcronymKeys() async throws {
        let json = """
        {"results":[{"title":"测试剧","channel":"channel","post_url":"https://t.me/channel/1",
        "share_url":"https://115.com/s/example?password=abc1","type":"share","tmdb_id":42,
        "kind":"tv","season":2,"episode":3,"raw_text":"原文","details":{"size":"8 GB"}}],"warnings":null}
        """
        let response = try APIClient.decoder.decode(SearchResponse.self, from: Data(json.utf8))
        let result = try XCTUnwrap(response.results?.first)
        XCTAssertEqual(result.postURL, "https://t.me/channel/1")
        XCTAssertEqual(result.shareURL, "https://115.com/s/example?password=abc1")
        XCTAssertEqual(result.tmdbID, 42)
        XCTAssertEqual(result.subscription().season, 2)
        XCTAssertEqual(result.subscription().resourceType, .share)
    }

    func testSubscriptionRuntimeIdentityAndNullValuesDecode() async throws {
        let json = """
        {"id":"sub1","title":"测试","kind":"tv","tmdb_id":123,"resource_type":"any",
        "interval_minutes":60,"enabled":true,"created_at":"2026-10-15T10:00:00.123456789Z",
        "last_checked":"0001-01-01T00:00:00Z","last_job_id":"job1","poster":null}
        """
        let sub = try APIClient.decoder.decode(ResourceSubscription.self, from: Data(json.utf8))
        XCTAssertEqual(sub.tmdbID, 123)
        XCTAssertEqual(sub.lastJobID, "job1")
        XCTAssertNil(ServerDate.parse(sub.lastChecked))
        XCTAssertNotNil(ServerDate.parse(sub.createdAt))
        XCTAssertEqual(sub.draft.poster, "")
    }

    func testSubscriptionEncodingUsesBackendSnakeCaseAndNoRuntimeFields() async throws {
        var draft = SubscriptionDraft()
        draft.title = "测试"
        draft.tmdbID = 42
        draft.resourceType = .magnet
        let data = try APIClient.encoder.encode(draft)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["tmdb_id"] as? Int, 42)
        XCTAssertEqual(json["resource_type"] as? String, "magnet")
        XCTAssertEqual(json["interval_minutes"] as? Int, 60)
        XCTAssertNil(json["seen"])
        XCTAssertNil(json["last_job_id"])
    }

    func testSubscriptionValidationMatchesBackendByteLimits() async throws {
        var draft = SubscriptionDraft()
        XCTAssertThrowsError(try draft.validated())
        draft.title = String(repeating: "剧", count: 67)
        XCTAssertThrowsError(try draft.validated())
        draft.title = "  测试  "
        draft.intervalMinutes = 29
        XCTAssertThrowsError(try draft.validated())
        draft.intervalMinutes = 10081
        XCTAssertThrowsError(try draft.validated())
        draft.intervalMinutes = 30
        draft.year = 1899
        XCTAssertThrowsError(try draft.validated())
        draft.year = 2026
        draft.season = 5
        let value = try draft.validated()
        XCTAssertEqual(value.title, "测试")
        XCTAssertEqual(value.season, 0)
        draft.kind = .tv
        XCTAssertEqual(try draft.validated().season, 5)
        draft.clearMediaIdentity()
        XCTAssertEqual(draft.tmdbID, 0)
        XCTAssertTrue(draft.poster.isEmpty)
    }

    func testSummaryJobsNeedNoEntriesAndRecognizeServerActiveStatuses() async throws {
        let json = """
        {"id":"job1","rule":{"name":"资源转存","mode":"resource","kind":"tv"},
        "status":"executing","created_at":"2026-10-15T10:00:00Z","updated_at":"2026-10-15T10:00:01Z",
        "scanned":10,"processed":3,"message":"整理中","entries":null,"warnings":null}
        """
        let job = try APIClient.decoder.decode(Job.self, from: Data(json.utf8))
        XCTAssertTrue(job.isActive)
        XCTAssertNil(job.entries)
        XCTAssertEqual(job.progress, 0.3, accuracy: 0.001)
        XCTAssertEqual(JobStatus.title(job.status), "执行中")
    }

    func testRemoteSettingsRedactedProxyAndConfiguredFlagsDecode() async throws {
        let json = """
        {"language":"zh-CN","download_art":true,"request_timeout":30,"api_key_set":false,
        "read_token_set":true,"proxy_enabled":false,"proxy_set":true,"proxy_url":"http://proxy:7890"}
        """
        let value = try APIClient.decoder.decode(RemoteSettings.self, from: Data(json.utf8))
        XCTAssertTrue(value.readTokenSet)
        XCTAssertEqual(value.proxyURL, "http://proxy:7890")
    }
}
