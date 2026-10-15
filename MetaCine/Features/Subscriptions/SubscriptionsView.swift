import SwiftUI

struct SubscriptionsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var subscriptions: [ResourceSubscription] = []
    @State private var filter = "all"
    @State private var loading = false
    @State private var busy: Set<String> = []
    @State private var error: String?
    @State private var draft: SubscriptionDraft?
    @State private var deleting: ResourceSubscription?
    @State private var notice: InlineNotice?
    @State private var refreshID = UUID()

    private var visible: [ResourceSubscription] {
        subscriptions.filter {
            switch filter {
            case "enabled": $0.enabled
            case "paused": !$0.enabled
            case "matched": !($0.lastJobID ?? "").isEmpty
            default: true
            }
        }
    }

    var body: some View {
        NavigationStack {
            ConnectionGate {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        header
                        Picker("订阅状态", selection: $filter) {
                            Text("全部").tag("all")
                            Text("订阅中").tag("enabled")
                            Text("已暂停").tag("paused")
                            Text("已匹配").tag("matched")
                        }.pickerStyle(.segmented)
                        if let error { ErrorBanner(message: error) { Task { await load() } } }
                        if loading && subscriptions.isEmpty {
                            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 70)
                        } else if visible.isEmpty {
                            ContentUnavailableView {
                                Label("留一份期待", systemImage: "bookmark")
                            } description: {
                                Text(subscriptions.isEmpty ? "从榜单选择作品，或手动添加订阅。\n服务器会替你持续寻找资源。" : "此筛选条件下暂无订阅。")
                            } actions: {
                                Button("新增订阅") { draft = SubscriptionDraft() }.buttonStyle(.borderedProminent)
                            }
                        } else {
                            LazyVStack(spacing: 14) {
                                ForEach(visible) { sub in subscriptionCard(sub) }
                            }
                        }
                    }.padding(20)
                }
                .refreshable { await load() }
                .task(id: refreshID) { await load() }
                .task(id: scenePhase) {
                    guard scenePhase == .active else { return }
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(15)) } catch { return }
                        await load(silent: true)
                    }
                }
            }
            .background(CineBackdrop())
            .navigationTitle("订阅任务")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { Task { await checkAll() } } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    .accessibilityLabel("检查所有启用的订阅")
                    .disabled(!store.isConnected || !busy.isEmpty || !subscriptions.contains(where: \.enabled))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { draft = SubscriptionDraft() } label: { Image(systemName: "plus") }
                        .accessibilityLabel("新增订阅").disabled(!store.isConnected)
                }
            }
            .sheet(item: $draft) { value in SubscriptionEditor(draft: value) { refreshID = UUID() } }
            .confirmationDialog("删除订阅？", isPresented: Binding(
                get: { deleting != nil }, set: { if !$0 { deleting = nil } }
            ), titleVisibility: .visible, presenting: deleting) { sub in
                Button("删除订阅", role: .destructive) { Task { await delete(sub) } }
            } message: { sub in Text("删除“\(sub.title)”的订阅配置。已启动的任务将继续运行。") }
            .cineNotice($notice)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionEyebrow(text: "YOUR WATCHLIST / ALWAYS ON")
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(subscriptions.filter(\.enabled).count)")
                    .font(.system(size: 42, weight: .semibold, design: .serif)).foregroundStyle(CineTheme.accent)
                Text("部作品订阅中").foregroundStyle(.secondary)
                Spacer()
                Text("共 \(subscriptions.count) 部").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func subscriptionCard(_ sub: ResourceSubscription) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                PosterView(path: sub.poster).frame(width: 70, height: 105).clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .top) {
                        Text(sub.title).font(.headline)
                        Spacer(minLength: 4)
                        StatusPill(title: sub.enabled ? "订阅中" : "已暂停", color: sub.enabled ? CineTheme.accent : .secondary)
                    }
                    Text(subscriptionInfo(sub)).font(.caption).foregroundStyle(.secondary)
                    if let quality = sub.quality, !quality.isEmpty { Text(quality).font(.caption).foregroundStyle(.secondary) }
                    Text("每 \(sub.intervalMinutes) 分钟检查").font(.caption2).foregroundStyle(.secondary)
                    if let message = sub.message, !message.isEmpty {
                        Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(4)
                    }
                }
            }
            Divider()
            HStack {
                Text("上次：\(ServerDate.display(sub.lastChecked))")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                if let jobID = sub.lastJobID, !jobID.isEmpty {
                    NavigationLink { JobDetailView(jobID: jobID) } label: {
                        Label("任务", systemImage: "arrow.up.right.square")
                    }.font(.caption)
                }
                Menu {
                    Button("编辑订阅", systemImage: "pencil") { draft = sub.draft }
                    Button(sub.enabled ? "暂停订阅" : "恢复订阅", systemImage: sub.enabled ? "pause" : "play") {
                        Task { await toggle(sub) }
                    }
                    Button("立即检查", systemImage: "arrow.clockwise") { Task { await check(sub) } }.disabled(!sub.enabled)
                    Button("删除订阅", systemImage: "trash", role: .destructive) { deleting = sub }
                } label: {
                    if busy.contains(sub.id) { ProgressView() }
                    else { Image(systemName: "ellipsis.circle").font(.title3).padding(.leading, 8) }
                }.disabled(busy.contains(sub.id)).accessibilityLabel("管理 \(sub.title)")
            }
        }.padding(16).background(.background, in: RoundedRectangle(cornerRadius: 18))
    }

    private func subscriptionInfo(_ sub: ResourceSubscription) -> String {
        var parts = [MediaKind(rawValue: sub.kind)?.title ?? sub.kind]
        if let year = sub.year, year > 0 { parts.append(String(year)) }
        if sub.kind == "tv" { parts.append((sub.season ?? 0) > 0 ? "第 \(sub.season!) 季" : "全部季") }
        parts.append(ResourceKind(rawValue: sub.resourceType)?.title ?? sub.resourceType)
        return parts.joined(separator: " · ")
    }

    @MainActor private func load(silent: Bool = false) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let values: [ResourceSubscription]? = try await store.requireClient().get("api/resources/subscriptions")
            try Task.checkCancellation()
            subscriptions = (values ?? []).sorted { $0.createdAt > $1.createdAt }
            error = nil
        } catch {
            if !silent, !isCancellation(error) { self.error = error.localizedDescription }
        }
    }

    @MainActor private func toggle(_ sub: ResourceSubscription) async {
        guard busy.insert(sub.id).inserted else { return }
        defer { busy.remove(sub.id) }
        do {
            var value = sub.draft
            value.enabled.toggle()
            let _: ResourceSubscription = try await store.requireClient().send("PUT", "api/resources/subscriptions/\(sub.id)", body: value)
            await load()
        } catch { showError(error) }
    }

    @MainActor private func check(_ sub: ResourceSubscription) async {
        guard busy.insert(sub.id).inserted else { return }
        defer { busy.remove(sub.id) }
        do {
            try await store.requireClient().perform("POST", "api/resources/subscriptions/\(sub.id)/check", body: EmptyBody())
            notice = InlineNotice(title: "已加入检查队列", message: "服务器将查找“\(sub.title)”的资源。")
            await load()
        } catch { showError(error) }
    }

    @MainActor private func checkAll() async {
        let enabled = subscriptions.filter(\.enabled)
        guard busy.isEmpty else { return }
        busy.formUnion(enabled.map(\.id))
        defer { busy.subtract(enabled.map(\.id)) }
        var failures: [String] = []
        var count = 0
        let api: APIClient
        do { api = try store.requireClient() }
        catch { showError(error); return }
        for sub in enabled {
            if Task.isCancelled { return }
            do {
                try await api.perform("POST", "api/resources/subscriptions/\(sub.id)/check", body: EmptyBody())
                count += 1
            } catch {
                if isCancellation(error) { return }
                failures.append("\(sub.title)：\(error.localizedDescription)")
            }
        }
        notice = InlineNotice(title: "已提交 \(count) 个订阅", message: failures.isEmpty ? "启用的订阅已全部加入检查队列。" : failures.joined(separator: "\n"))
        await load()
    }

    @MainActor private func delete(_ sub: ResourceSubscription) async {
        guard busy.insert(sub.id).inserted else { return }
        defer { busy.remove(sub.id) }
        do {
            try await store.requireClient().perform("DELETE", "api/resources/subscriptions/\(sub.id)", body: EmptyBody())
            await load()
        } catch { showError(error) }
    }

    private func showError(_ error: Error) {
        if !isCancellation(error) { notice = InlineNotice(title: "操作失败", message: error.localizedDescription) }
    }
}
