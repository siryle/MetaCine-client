import Foundation
import CryptoKit

actor PosterCache {
    static let shared = PosterCache()

    private struct Entry {
        let size: Int
        let date: Date
    }

    private let directory: URL
    private let byteLimit: Int
    private let lifetime: TimeInterval
    private var entries: [String: Entry] = [:]
    private var totalBytes = 0
    private var prepared = false

    init(
        directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Posters-v1", isDirectory: true),
        byteLimit: Int = 200 * 1024 * 1024,
        lifetime: TimeInterval = 30 * 24 * 60 * 60
    ) {
        self.directory = directory
        self.byteLimit = byteLimit
        self.lifetime = lifetime
    }

    static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func data(for key: String) -> Data? {
        prepare()
        let name = Self.fingerprint(Data(key.utf8))
        guard let entry = entries[name] else { return nil }
        guard Date().timeIntervalSince(entry.date) < lifetime,
              let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else {
            removeEntry(name)
            return nil
        }
        return data
    }

    func store(_ data: Data, for key: String) {
        prepare()
        guard !data.isEmpty, data.count <= byteLimit else { return }
        let name = Self.fingerprint(Data(key.utf8))
        do {
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
            totalBytes -= entries[name]?.size ?? 0
            entries[name] = Entry(size: data.count, date: Date())
            totalBytes += data.count
            prune()
        } catch {
            // Artwork can still load when the device cannot write its disposable cache.
        }
    }

    func remove(_ key: String) {
        prepare()
        removeEntry(Self.fingerprint(Data(key.utf8)))
    }

    private func prepare() {
        guard !prepared else { return }
        prepared = true
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let files = try? manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        ) else { return }
        for file in files {
            guard let values = try? file.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
            ), values.isRegularFile == true else { continue }
            let entry = Entry(size: values.fileSize ?? 0, date: values.contentModificationDate ?? .distantPast)
            entries[file.lastPathComponent] = entry
            totalBytes += entry.size
        }
        prune()
    }

    private func prune() {
        let expired = entries.filter { Date().timeIntervalSince($0.value.date) >= lifetime }.map(\.key)
        for name in expired { removeEntry(name) }
        if totalBytes > byteLimit {
            for (name, _) in entries.sorted(by: { $0.value.date < $1.value.date }) {
                removeEntry(name)
                if totalBytes <= byteLimit { break }
            }
        }
    }

    private func removeEntry(_ name: String) {
        totalBytes -= entries.removeValue(forKey: name)?.size ?? 0
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }
}
