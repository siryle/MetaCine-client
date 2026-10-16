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

    func testResourceMediaIdentityRemovesChannelHeadingsAndReleaseMetadata() async throws {
        let cases: [(String, String, Int)] = [
            (" 名称: 天地争霸美猴王 ", "天地争霸美猴王", 0),
            ("名称: 大闹天宫 蓝光1080P", "大闹天宫", 0),
            ("剧集：Example Show (2026) S02E03 2160p", "Example Show", 2026),
            ("电影：Example（1999）1080p", "Example", 1999),
            ("Example S01E02", "Example", 0),
            ("1984", "1984", 0)
        ]
        for (title, expectedTitle, expectedYear) in cases {
            let identity = ResourceMediaIdentity(try resourceResult(title: title))
            XCTAssertEqual(identity.title, expectedTitle, title)
            XCTAssertEqual(identity.year, expectedYear, title)
        }
    }

    func testResourceMediaMatchingRejectsRemakesUnrelatedTitlesAndWrongIDs() async throws {
        let json = """
        {"id":42,"kind":"tv","title":"Translated Show","original_title":"Example Show","year":2026}
        """
        let media = try APIClient.decoder.decode(MediaItem.self, from: Data(json.utf8))
        XCTAssertTrue(ResourceMediaIdentity(try resourceResult(title: "Example Show (2026)", tmdbID: 42)).matches(media))
        XCTAssertFalse(ResourceMediaIdentity(try resourceResult(title: "Example Show (2025)")).matches(media))
        XCTAssertFalse(ResourceMediaIdentity(try resourceResult(title: "Another Show (2026)")).matches(media))
        XCTAssertFalse(ResourceMediaIdentity(try resourceResult(title: "Example Show (2026)", tmdbID: 100)).matches(media))
    }

    private func resourceResult(title: String, tmdbID: Int = 0) throws -> ResourceResult {
        let data = try JSONSerialization.data(withJSONObject: [
            "title": title, "channel": "channel", "post_url": "https://t.me/channel/1",
            "share_url": "https://115.com/s/example", "type": "share", "tmdb_id": tmdbID
        ] as [String: Any])
        return try APIClient.decoder.decode(ResourceResult.self, from: data)
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
        XCTAssertEqual(json["source"] as? String, "all")
        XCTAssertEqual(json["auto_unlock"] as? Bool, true)
        XCTAssertNil(json["max_points"])
        XCTAssertNil(json["seen"])
        XCTAssertNil(json["last_job_id"])
    }

    func testSubscriptionEditsAndPausePreserveSourceAndUnlockLimit() async throws {
        for source in ["all", "re0", "telegram"] {
            let sub = try APIClient.decoder.decode(ResourceSubscription.self, from: Data("""
            {"id":"sub1","title":"Example","kind":"tv","tmdb_id":42,"resource_type":"any",
            "source":"\(source)","auto_unlock":true,"max_points":8,
            "interval_minutes":60,"enabled":true,"created_at":"2026-10-16T10:00:00Z"}
            """.utf8))
            var draft = sub.draft
            draft.enabled.toggle()
            let body = try XCTUnwrap(JSONSerialization.jsonObject(
                with: APIClient.encoder.encode(draft.validated())
            ) as? [String: Any])
            XCTAssertEqual(body["source"] as? String, source)
            XCTAssertEqual(body["auto_unlock"] as? Bool, true)
            XCTAssertEqual(body["max_points"] as? Int, 8)
            XCTAssertEqual(body["enabled"] as? Bool, false)
        }
    }

    func testLegacySubscriptionsKeepTelegramAndFreeOnlyBehavior() async throws {
        let sub = try APIClient.decoder.decode(ResourceSubscription.self, from: Data("""
        {"id":"sub1","title":"Example","kind":"movie","resource_type":"any",
        "interval_minutes":60,"enabled":true,"created_at":"2026-10-16T10:00:00Z"}
        """.utf8))
        XCTAssertEqual(sub.resourceSource, .telegram)
        XCTAssertEqual(sub.draft.source, .telegram)
        XCTAssertFalse(sub.draft.autoUnlock)
        XCTAssertEqual(sub.draft.maxPoints, 0)
    }

    func testRE0SubscriptionRequiresTMDBIdentityAndValidPointLimit() async throws {
        var draft = SubscriptionDraft(title: "Example", source: .re0)
        XCTAssertThrowsError(try draft.validated())
        draft.tmdbID = 42
        for points in [-1, 10001] {
            draft.maxPoints = points
            XCTAssertThrowsError(try draft.validated())
        }
        for points in [0, 3, 10000] {
            draft.maxPoints = points
            XCTAssertEqual(try draft.validated().maxPoints, points)
        }
        draft.source = .all
        draft.tmdbID = 0
        XCTAssertNoThrow(try draft.validated())
    }

    func testLockedRE0ResourceIdentitySurvivesUnlockAndPreservesCost() async throws {
        var result = try re0Result(points: 3)
        XCTAssertEqual(result.resourceSource, .re0)
        XCTAssertTrue(result.needsUnlock)
        XCTAssertEqual(result.link, result.postURL)
        XCTAssertEqual(result.unlockStatus, "3 积分")
        let id = result.id
        let body = try ResourceUnlockBody(result)
        XCTAssertEqual(body.maxPoints, 3)
        XCTAssertTrue(body.allowPaid)
        result.shareURL = "https://115.com/s/example?password=abc1"
        result.unlocked = true
        XCTAssertEqual(result.id, id)
        XCTAssertFalse(result.needsUnlock)
        XCTAssertEqual(result.link, result.shareURL)
        XCTAssertThrowsError(try ResourceUnlockBody(result))
    }

    func testUnlockRejectsUnknownAndInvalidCostsButAllowsOwnedResources() async throws {
        for points in [nil, -1, 10001] as [Int?] {
            XCTAssertThrowsError(try ResourceUnlockBody(re0Result(points: points)))
        }
        let owned = try ResourceUnlockBody(re0Result(points: nil, unlocked: true))
        XCTAssertFalse(owned.allowPaid)
        XCTAssertEqual(owned.maxPoints, 0)
        let free = try ResourceUnlockBody(re0Result(points: 0))
        XCTAssertFalse(free.allowPaid)
        XCTAssertEqual(free.maxPoints, 0)
    }

    func testResourceMediaHintRejectsWrongTMDBKindYearAndSeason() async throws {
        let hint = ResourceMediaHint(SubscriptionDraft(
            title: "Example", originalTitle: "Original", tmdbID: 42, kind: .tv, year: 2026, season: 2
        ))
        XCTAssertTrue(hint.matchesQuery(" ORIGINAL! "))
        XCTAssertFalse(hint.matchesQuery("Another"))
        XCTAssertTrue(hint.matches(try re0Result(points: 3)))
        XCTAssertFalse(hint.matches(try re0Result(points: 3, tmdbID: 43)))
        XCTAssertFalse(hint.matches(try re0Result(points: 3, kind: "movie")))
        XCTAssertFalse(hint.matches(try re0Result(points: 3, season: 1)))
        let movie = ResourceMediaHint(SubscriptionDraft(title: "Example", tmdbID: 42, year: 2025))
        XCTAssertFalse(movie.matches(try re0Result(points: 3, kind: "movie", season: 0)))
    }

    private func re0Result(
        points: Int?, unlocked: Bool = false, tmdbID: Int = 42, kind: String = "tv", season: Int = 2
    ) throws -> ResourceResult {
        var object: [String: Any] = [
            "source": "re0", "slug": "0123456789abcdef0123456789abcdef", "unlocked": unlocked,
            "title": "Example (2026)", "channel": "RE0", "type": "share", "share_url": "",
            "post_url": "https://re0.me/resource/example", "tmdb_id": tmdbID, "kind": kind, "season": season
        ]
        if let points { object["unlock_points"] = points }
        return try APIClient.decoder.decode(ResourceResult.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func testSubscribedBadgeMatchesTMDBIdentityOrNormalizedTitleAndYear() async throws {
        let json = """
        {"id":42,"source":"tmdb","kind":"tv","title":"Example Show","year":2026}
        """
        let media = try APIClient.decoder.decode(MediaItem.self, from: Data(json.utf8))
        XCTAssertTrue(try badgeSubscription(title: "Translated title", tmdbID: 42, year: 2025).matches(media))
        XCTAssertTrue(try badgeSubscription(title: "EXAMPLE: Show!", year: 2026).matches(media))
        XCTAssertFalse(try badgeSubscription(title: "Example Show", year: 2025).matches(media))
        XCTAssertFalse(try badgeSubscription(title: "Example Show", tmdbID: 42, kind: "movie").matches(media))
        XCTAssertFalse(try badgeSubscription(title: "Another Show").matches(media))
    }

    func testSubscribedBadgeDoesNotTreatDoubanIDAsTMDBIdentity() async throws {
        let json = """
        {"id":42,"douban_id":"42","source":"douban","kind":"tv","title":"Example Show","year":2026}
        """
        let media = try APIClient.decoder.decode(MediaItem.self, from: Data(json.utf8))
        XCTAssertFalse(try badgeSubscription(title: "Another Show", tmdbID: 42).matches(media))
        XCTAssertTrue(try badgeSubscription(title: "Example Show", tmdbID: 100).matches(media))
    }

    func testSubscribedBadgeIncludesPausedSeasonsAndRankingsWithoutYears() async throws {
        let json = """
        {"id":0,"douban_id":"123","source":"douban","kind":"tv","title":"Example Show"}
        """
        let media = try APIClient.decoder.decode(MediaItem.self, from: Data(json.utf8))
        let pausedSeason = try badgeSubscription(title: "Example Show", year: 2026, season: 2, enabled: false)
        XCTAssertTrue(pausedSeason.matches(media))
        XCTAssertFalse(try badgeSubscription(title: "Another Show", year: 2026).matches(media))
    }

    private func badgeSubscription(
        title: String, tmdbID: Int = 0, kind: String = "tv",
        year: Int = 2026, season: Int = 0, enabled: Bool = true
    ) throws -> ResourceSubscription {
        let object: [String: Any] = [
            "id": "sub1", "title": title, "tmdb_id": tmdbID, "kind": kind,
            "year": year, "season": season, "enabled": enabled, "resource_type": "any",
            "interval_minutes": 60, "created_at": "2026-10-15T10:00:00Z"
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        return try APIClient.decoder.decode(ResourceSubscription.self, from: data)
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
