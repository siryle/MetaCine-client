import XCTest
@testable import MetaCine

@MainActor
final class JobCorrectionTests: XCTestCase {
    func testPreviewAndFinishedResourceJobsFollowServerReviewRules() throws {
        XCTAssertTrue(try job().canReviewMatches)
        for status in ["partial", "failed", "cancelled", "interrupted"] {
            XCTAssertTrue(try job(status: status, resourceKey: "share:example").canReviewMatches)
            XCTAssertFalse(try job(status: status).canReviewMatches)
        }
        for status in ["queued", "scanning", "executing", "deduplicating", "completed"] {
            XCTAssertFalse(try job(status: status, resourceKey: "share:example").canReviewMatches)
        }
        for mode in ["strm", "scrape", "subtitle"] {
            XCTAssertTrue(try job(mode: mode).canReviewMatches)
            XCTAssertFalse(try job(status: "failed", mode: mode, resourceKey: "share:example").canReviewMatches)
        }
    }

    func testOnlyUnmovedEligibleEntriesCanBeCorrected() throws {
        for status in ["ready", "unmatched", "ambiguous", "error", "conflict", "no_subtitle"] {
            let value = try job(entryStatus: status)
            XCTAssertTrue(value.canCorrect(try XCTUnwrap(value.entries?.first)))
        }
        for status in ["done", "skipped", "processing"] {
            let value = try job(entryStatus: status)
            XCTAssertFalse(value.canCorrect(try XCTUnwrap(value.entries?.first)))
        }
        for moved in [true, nil] as [Bool?] {
            let value = try job(moved: moved)
            XCTAssertFalse(value.canCorrect(try XCTUnwrap(value.entries?.first)))
        }
    }

    func testExecutableFilesNeedPreviewReadyMediaAndUnmovedState() throws {
        XCTAssertEqual(try job(entryStatus: "ready").executableEntries.map(\.id), ["entry1"])
        XCTAssertTrue(try job(status: "partial", resourceKey: "share:example", entryStatus: "ready").executableEntries.isEmpty)
        XCTAssertTrue(try job(entryStatus: "conflict").executableEntries.isEmpty)
        XCTAssertTrue(try job(entryStatus: "ready", moved: true).executableEntries.isEmpty)
        XCTAssertTrue(try job(entryStatus: "ready", moved: nil).executableEntries.isEmpty)
        XCTAssertTrue(try job(entryStatus: "ready", hasMedia: false).executableEntries.isEmpty)
    }

    func testIdentityAndTMDBMediaDecodeWithoutLosingEpisodeInformation() throws {
        let entry = try XCTUnwrap(job().entries?.first)
        XCTAssertEqual(entry.identity?.tmdbID, 42)
        XCTAssertEqual(entry.identity?.season, 0)
        XCTAssertEqual(entry.identity?.episode, 3)
        XCTAssertEqual(entry.media?.tmdbID, 42)
        XCTAssertEqual(entry.moved, false)
    }

    func testMovieCorrectionOmitsSeasonAndEpisodeAndUsesSnakeCase() throws {
        let body = try JobCorrectionBody(kind: .movie, tmdbID: 42, season: 8, episode: 9).validated()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: APIClient.encoder.encode(body)) as? [String: Any])
        XCTAssertEqual(json["kind"] as? String, "movie")
        XCTAssertEqual(json["tmdb_id"] as? Int, 42)
        XCTAssertNil(json["season"])
        XCTAssertNil(json["episode"])
    }

    func testTVCorrectionAllowsSpecialsAndRejectsInvalidIdentity() throws {
        let body = try JobCorrectionBody(kind: .tv, tmdbID: 42, season: 0, episode: 3).validated()
        XCTAssertEqual(body.season, 0)
        XCTAssertEqual(body.episode, 3)
        for id in [-1, 0] {
            XCTAssertThrowsError(try JobCorrectionBody(kind: .movie, tmdbID: id).validated())
        }
        for (season, episode) in [(nil, 1), (1, nil), (-1, 1), (1000, 1), (1, 0), (1, 10000)] as [(Int?, Int?)] {
            XCTAssertThrowsError(try JobCorrectionBody(kind: .tv, tmdbID: 42, season: season, episode: episode).validated())
        }
    }

    func testQueuedJobsRemainActiveAndCannotBeDeletedAsFinished() throws {
        XCTAssertTrue(try job(status: "queued").isActive)
        XCTAssertEqual(JobStatus.title("queued"), "排队中")
    }

    private func job(
        status: String = "preview", mode: String = "organize", resourceKey: String? = nil,
        entryStatus: String = "ambiguous", moved: Bool? = false, hasMedia: Bool = true
    ) throws -> Job {
        var entry: [String: Any] = [
            "id": "entry1", "source": "/incoming/Example.S00E03.mkv", "destination": "/library/Example.mkv",
            "status": entryStatus, "message": "", "size": 1024,
            "identity": ["title": "Example", "kind": "tv", "tmdb_id": 42, "season": 0, "episode": 3]
        ]
        if let moved { entry["moved"] = moved }
        if hasMedia { entry["media"] = ["id": 42, "kind": "tv", "title": "Example", "year": 2026] }
        var object: [String: Any] = [
            "id": "job1", "rule": ["name": "Example", "mode": mode], "status": status,
            "created_at": "2026-10-19T00:00:00Z", "updated_at": "2026-10-19T00:00:00Z",
            "scanned": 1, "processed": 0, "message": "", "entries": [entry]
        ]
        if let resourceKey { object["resource_key"] = resourceKey }
        return try APIClient.decoder.decode(Job.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
