import SwiftUI

struct MediaCatalogView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    let sections: [MediaCatalogSection]
    let tab: AppStore.Tab
    let refreshID: UUID
    var horizontal = false
    @State private var availability: Set<String> = []
    @State private var checkedAvailability: Set<String> = []
    @State private var availabilityRevision: UUID?
    @State private var availabilityNote: String?
    @State private var selection: MediaItem?
    @State private var subscriptions: [ResourceSubscription]?
    @State private var subscriptionsError: String?
    @State private var subscriptionsRequestID = UUID()
    @State private var subscribing: Set<String> = []
    @State private var notice: InlineNotice?

    private var items: [MediaItem] {
        var seen: Set<String> = []
        return sections.flatMap(\.items).filter { seen.insert($0.stableID).inserted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let subscriptionsError {
                ErrorBanner(message: subscriptionsError) { Task { await loadSubscriptions() } }
            }
            if let availabilityNote {
                Text(availabilityNote).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: 14) {
                    if !section.title.isEmpty {
                        HStack {
                            Text(section.title).font(.title3.weight(.semibold))
                            Spacer()
                            if section.loading { ProgressView() }
                            else { Text("\(section.items.count) 部").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    if section.stale {
                        Text("正在显示缓存数据，后台更新中，可下拉刷新。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = section.error { ErrorBanner(message: error) }
                    if section.items.isEmpty, !section.loading, section.error == nil, horizontal {
                        Text("当前榜单暂无作品，可下拉刷新或切换其他榜单。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    if horizontal {
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 16) {
                                ForEach(section.items, id: \.stableID) { item in
                                    posterCard(item).frame(width: 145)
                                }
                            }
                        }
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 16)], spacing: 24) {
                            ForEach(section.items, id: \.stableID) { item in posterCard(item) }
                        }
                    }
                }
            }
        }
        .task(id: AvailabilityKey(revision: refreshID, items: items.map(\.stableID))) {
            await loadAvailability()
        }
        .task(id: "\(refreshID):\(store.subscriptionsRevision):\(store.selectedTab == tab && scenePhase == .active)") {
            guard store.selectedTab == tab, scenePhase == .active else { return }
            await loadSubscriptions()
        }
        .sheet(item: $selection) { item in MediaDetailView(item: item) }
        .cineNotice($notice)
    }

    private struct AvailabilityKey: Equatable {
        let revision: UUID
        let items: [String]
    }

    private func posterCard(_ item: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Button { selection = item } label: {
                PosterView(path: item.artwork).aspectRatio(2 / 3, contentMode: .fit)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("查看\(item.title)详情")
            .overlay(alignment: .topLeading) {
                if let rating = item.rating, rating > 0 {
                    Text(String(format: "%.1f", rating))
                        .font(.caption.bold()).foregroundStyle(.white)
                        .padding(7).background(.black.opacity(0.7), in: Capsule()).padding(8)
                        .accessibilityLabel("评分 \(String(format: "%.1f", rating))")
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottom) {
                HStack(alignment: .bottom, spacing: 4) {
                    if availability.contains(item.stableID) {
                        Text("有资源").font(.caption2.bold()).foregroundStyle(.white)
                            .padding(.horizontal, 7).padding(.vertical, 6)
                            .background(CineTheme.accent, in: Capsule())
                            .accessibilityLabel("缓存频道中有匹配资源")
                            .allowsHitTesting(false)
                    }
                    Spacer(minLength: 0)
                    subscriptionControl(item)
                }
                .padding(8)
            }
            .clipShape(RoundedRectangle(cornerRadius: 15))
            Button { selection = item } label: {
                VStack(alignment: .leading, spacing: 9) {
                    Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text(item.subtitle).font(.caption).foregroundStyle(.secondary)
                    if let heat = item.heat, !heat.isEmpty {
                        Text("热度 \(heat)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain)
        }.frame(maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
    }

    private func isSubscribed(_ item: MediaItem) -> Bool {
        subscriptions?.contains(where: { $0.matches(item) }) == true
    }

    @ViewBuilder
    private func subscriptionControl(_ item: MediaItem) -> some View {
        if isSubscribed(item) {
            subscriptionBadge("已订阅")
                .allowsHitTesting(false)
        } else {
            let busy = subscribing.contains(item.stableID)
            Button { Task { await subscribe(item) } } label: {
                subscriptionBadge(busy ? "订阅中" : "订阅", loading: busy)
            }
            .buttonStyle(.plain)
            .disabled(subscriptions == nil || busy)
            .accessibilityLabel("订阅\(item.title)")
            .accessibilityHint(subscriptions == nil ? "等待订阅状态加载完成" : "使用默认偏好一键订阅")
        }
    }

    private func subscriptionBadge(_ title: String, loading: Bool = false) -> some View {
        HStack(spacing: 4) {
            if loading { ProgressView().tint(.white).controlSize(.mini) }
            Text(title)
        }
        .font(.caption2.bold()).foregroundStyle(.white)
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(.black.opacity(0.7), in: Capsule())
    }

    @MainActor
    private func loadSubscriptions() async {
        let identity = UUID()
        subscriptionsRequestID = identity
        do {
            let values: [ResourceSubscription]? = try await store.requireClient().get("api/resources/subscriptions")
            try Task.checkCancellation()
            guard subscriptionsRequestID == identity else { return }
            subscriptions = values ?? []
            subscriptionsError = nil
        } catch {
            if !isCancellation(error), subscriptionsRequestID == identity {
                subscriptionsError = "订阅状态加载失败：\(error.localizedDescription)"
            }
        }
    }

    @MainActor
    private func subscribe(_ item: MediaItem) async {
        guard subscriptions != nil, !isSubscribed(item), subscribing.insert(item.stableID).inserted else { return }
        let context = store.contextID
        defer { subscribing.remove(item.stableID) }
        do {
            let api = try store.requireClient()
            var draft = item.subscription()
            // Douban tag rankings can omit the year; resolve it before saving, as the server UI does.
            if item.source?.hasPrefix("douban") == true, draft.year == 0 {
                guard let id = item.doubanID, !id.isEmpty, id.allSatisfy(\.isNumber) else {
                    throw APIError.validation("豆瓣条目缺少有效 ID。")
                }
                let detail: MediaDetail = try await api.get(
                    "api/resources/rankings/douban/\(id)",
                    query: [URLQueryItem(name: "kind", value: item.kind)]
                )
                draft.year = detail.year ?? draft.year
                draft.originalTitle = detail.originalTitle ?? draft.originalTitle
                draft.poster = detail.poster ?? draft.poster
            }
            let saved: ResourceSubscription = try await api.send(
                "POST", "api/resources/subscriptions", body: draft.validated()
            )
            guard store.contextID == context else { return }
            // Discard any older list response so it cannot erase the subscription just saved.
            subscriptionsRequestID = UUID()
            subscriptions?.append(saved)
            store.subscriptionsDidChange()
        } catch {
            if !isCancellation(error), store.contextID == context {
                notice = InlineNotice(title: "订阅失败", message: error.localizedDescription)
                await loadSubscriptions()
            }
        }
    }

    @MainActor
    private func loadAvailability() async {
        if availabilityRevision != refreshID {
            availabilityRevision = refreshID
            availability = []
            checkedAvailability = []
            availabilityNote = nil
        }
        let pending = items.filter { !checkedAvailability.contains($0.stableID) }
        do {
            let api = try store.requireClient()
            // The backend accepts at most 50 entries per availability request.
            for start in stride(from: 0, to: pending.count, by: 50) {
                let chunk = Array(pending[start..<min(start + 50, pending.count)])
                let response: AvailabilityResponse = try await api.send(
                    "POST", "api/resources/availability",
                    body: AvailabilityRequest(items: chunk.map(AvailabilityRequest.AvailabilityItem.init))
                )
                try Task.checkCancellation()
                for (item, available) in zip(chunk, response.available) {
                    checkedAvailability.insert(item.stableID)
                    if available { availability.insert(item.stableID) }
                }
            }
        } catch {
            if !isCancellation(error) { availabilityNote = "资源标记暂不可用，仍可正常浏览作品。" }
        }
    }
}
