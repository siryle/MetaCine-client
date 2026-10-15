import Foundation
import Observation

@MainActor
@Observable
final class AppStore {
    enum ConnectionState: Equatable {
        case idle, connecting, connected, failed(String)
    }
    enum Tab: Hashable { case discover, search, subscriptions, history, servers }

    private(set) var servers: [ServerProfile] = []
    private(set) var activeID: UUID?
    private(set) var client: APIClient?
    private(set) var serverSession: ServerSession?
    private(set) var connection: ConnectionState = .idle
    private(set) var contextID = UUID()
    private(set) var subscriptionsRevision = UUID()
    var selectedTab: Tab = .discover
    var searchQuery = ""

    private let defaults: UserDefaults
    private var connectionTask: Task<Void, Never>?
    var activeServer: ServerProfile? { servers.first { $0.id == activeID } }
    var isConnected: Bool { connection == .connected }
    var connectionLabel: String {
        switch connection {
        case .idle: "未连接"
        case .connecting: "正在连接"
        case .connected: "已连接"
        case .failed: "连接失败"
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "servers.v1"),
           let saved = try? JSONDecoder().decode([ServerProfile].self, from: data) {
            servers = saved
        }
        if let value = defaults.string(forKey: "activeServer.v1") {
            activeID = UUID(uuidString: value)
        }
        if activeServer == nil { activeID = servers.first?.id }
        if servers.isEmpty { selectedTab = .servers }
    }

    func start() { if client == nil, let activeServer { activate(activeServer) } }

    func save(_ profile: ServerProfile, credential: ServerCredential) throws {
        var normalized = profile
        normalized.address = try ServerProfile.normalizedURL(profile.address).absoluteString
        normalized.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.name.isEmpty { normalized.name = URL(string: normalized.address)?.host ?? "MetaCine" }
        let previousCredential = try CredentialStore.read(profile.id)
        try CredentialStore.save(credential, for: profile.id)
        var updated = servers
        if let index = updated.firstIndex(where: { $0.id == profile.id }) { updated[index] = normalized }
        else { updated.append(normalized) }
        do {
            defaults.set(try JSONEncoder().encode(updated), forKey: "servers.v1")
        } catch {
            try? CredentialStore.save(previousCredential, for: profile.id)
            throw error
        }
        servers = updated
        activate(normalized)
    }

    func delete(_ profile: ServerProfile) throws {
        try CredentialStore.delete(profile.id)
        let updated = servers.filter { $0.id != profile.id }
        defaults.set(try JSONEncoder().encode(updated), forKey: "servers.v1")
        servers = updated
        if activeID == profile.id {
            disconnect()
            activeID = nil
            defaults.removeObject(forKey: "activeServer.v1")
            if let first = servers.first { activate(first) }
        }
    }

    func activate(_ profile: ServerProfile) {
        disconnect()
        activeID = profile.id
        defaults.set(profile.id.uuidString, forKey: "activeServer.v1")
        connection = .connecting
        let generation = contextID
        connectionTask = Task { @MainActor in
            do {
                let api = try APIClient(profile: profile, credential: CredentialStore.read(profile.id))
                client = api
                let session = try await api.connect()
                guard !Task.isCancelled, contextID == generation else { return }
                serverSession = session
                connection = .connected
            } catch {
                guard !Task.isCancelled, contextID == generation else { return }
                client?.invalidate()
                client = nil
                connection = .failed(error.localizedDescription)
            }
        }
    }

    func reconnect() { if let activeServer { activate(activeServer) } }

    func disconnect() {
        connectionTask?.cancel()
        connectionTask = nil
        client?.invalidate()
        client = nil
        serverSession = nil
        searchQuery = ""
        connection = .idle
        contextID = UUID()
    }

    func requireClient() throws -> APIClient {
        guard isConnected, let client else { throw APIError.signedOut }
        return client
    }

    func subscriptionsDidChange() {
        subscriptionsRevision = UUID()
    }

    func search(for title: String) {
        searchQuery = title
        selectedTab = .search
    }
}
