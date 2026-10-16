import XCTest
@testable import MetaCine

final class PosterCacheTests: XCTestCase {
    func testDiskEntriesSurviveCacheRecreationAndExpire() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = Data("poster".utf8)
        let cache = PosterCache(directory: directory)
        await cache.store(data, for: "image")
        let restored = PosterCache(directory: directory)
        let loaded = await restored.data(for: "image")
        XCTAssertEqual(loaded, data)
        let file = directory.appendingPathComponent(PosterCache.fingerprint(Data("image".utf8)))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -31 * 24 * 60 * 60)], ofItemAtPath: file.path
        )
        let expired = PosterCache(directory: directory)
        let missing = await expired.data(for: "image")
        XCTAssertNil(missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testCacheEvictsOldestFilesAndRejectsOversizedEntries() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = PosterCache(directory: directory, byteLimit: 6)
        await cache.store(Data([1, 2, 3]), for: "old")
        await cache.store(Data([4, 5, 6]), for: "new")
        await cache.store(Data([7, 8, 9]), for: "latest")
        await cache.store(Data(repeating: 0, count: 7), for: "oversized")
        let old = await cache.data(for: "old")
        let new = await cache.data(for: "new")
        let latest = await cache.data(for: "latest")
        let oversized = await cache.data(for: "oversized")
        XCTAssertNil(old)
        XCTAssertEqual(new, Data([4, 5, 6]))
        XCTAssertEqual(latest, Data([7, 8, 9]))
        XCTAssertNil(oversized)
    }
}
