import SwiftUI

private struct RankingFilter: Equatable {
    var source = "douban"
    var kind: MediaKind = .movie
    var list = "day"
    var tag = "热门"
    var mode = "trending"
    var sort = "recommend"

    var tags: [String] {
        kind == .movie ? ["热门", "最新", "冷门佳片"] : ["热门", "国产剧", "美剧", "韩剧", "日剧", "动画", "综艺", "纪录片"]
    }
    func query(page: Int) -> [URLQueryItem] {
        [
            "source": source, "kind": kind.rawValue, "list": list, "tag": tag,
            "mode": tag == "冷门佳片" ? "web" : mode, "sort": sort, "page": String(page)
        ].sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
    }
}

struct DiscoverView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var filter = RankingFilter()
    @State private var items: [MediaItem] = []
    @State private var availability: Set<String> = []
    @State private var page = 0
    @State private var hasMore = false
    @State private var loading = false
    @State private var error: String?
    @State private var availabilityNote: String?
    @State private var selection: MediaItem?
    @State private var requestID = UUID()
    @State private var subscriptions: [ResourceSubscription]?
    @State private var subscriptionsError: String?
    @State private var subscriptionsRequestID = UUID()
    @State private var subscribing: Set<String> = []
    @State private var notice: InlineNotice?

    var body: some View {
        NavigationStack {
            ConnectionGate {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        intro
                        controls
                        if let error { ErrorBanner(message: error) { Task { await load(reset: page == 0) } } }
                        if let availabilityNote {
                            Text(availabilityNote).font(.caption).foregroundStyle(.secondary)
                        }
                        if let subscriptionsError {
                            ErrorBanner(message: subscriptionsError) { Task { await loadSubscriptions() } }
                        }
                        if items.isEmpty, loading {
                            ProgressView("正在发现好作品…").frame(maxWidth: .infinity).padding(.vertical, 70)
                        } else if items.isEmpty, error == nil {
                            ContentUnavailableView("暂无榜单", systemImage: "film", description: Text("试试其他分类或下拉刷新。"))
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 16)], spacing: 24) {
                                ForEach(items, id: \.stableID) { item in
                                    posterCard(item)
                                }
                            }
                            if hasMore {
                                Button { Task { await load(reset: false) } } label: {
                                    HStack {
                                        if loading { ProgressView() }
                                        Text(loading ? "加载中…" : "发现更多")
                                    }.frame(maxWidth: .infinity).padding(.vertical, 10)
                                }
                                .buttonStyle(.bordered).disabled(loading)
                            }
                        }
                    }
                    .padding(20)
                }
                .refreshable {
                    await load(reset: true)
                    await loadSubscriptions()
                }
                .task(id: filter) { await load(reset: true) }
                .task(id: "\(store.subscriptionsRevision):\(store.selectedTab == .discover && scenePhase == .active)") {
                    guard store.selectedTab == .discover, scenePhase == .active else { return }
                    await loadSubscriptions()
                }
            }
            .background(CineBackdrop())
            .navigationTitle("发现")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { ServerIndicator() } }
            .sheet(item: $selection) { item in MediaDetailView(item: item) }
            .cineNotice($notice)
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionEyebrow(text: "METACINE / DISCOVER")
                Spacer()
                Image(systemName: "sparkle").foregroundStyle(CineTheme.accent)
            }
            Text("下一部，\n值得期待。")
                .font(.system(size: 36, weight: .semibold, design: .serif)).tracking(-1)
            Text("从热门榜单出发，把喜欢的作品加入订阅。")
                .font(.subheadline).foregroundStyle(.secondary)
        }.padding(.vertical, 8)
    }

    private var controls: some View {
        VStack(spacing: 14) {
            Picker("榜单来源", selection: $filter.source) {
                Text("豆瓣").tag("douban")
                Text("TMDB").tag("tmdb")
            }.pickerStyle(.segmented)
            HStack {
                Picker("作品类型", selection: $filter.kind) {
                    ForEach(MediaKind.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).frame(maxWidth: 200)
                Spacer(minLength: 0)
                if filter.source == "tmdb" {
                    Picker("榜单", selection: $filter.list) {
                        Text("今日趋势").tag("day")
                        Text("本周趋势").tag("week")
                        Text("热门作品").tag("popular")
                        Text("高分佳作").tag("top_rated")
                    }.labelsHidden()
                } else {
                    Menu {
                        Picker("模式", selection: $filter.mode) {
                            Text("实时趋势").tag("trending")
                            Text("标签热度").tag("web")
                        }
                        Picker("排序", selection: $filter.sort) {
                            Text("推荐顺序").tag("recommend")
                            Text("本页评分").tag("rating")
                        }
                    } label: {
                        Label("筛选", systemImage: "slider.horizontal.3").font(.subheadline)
                    }
                }
            }
            if filter.source == "douban" {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(filter.tags, id: \.self) { tag in
                            Button { filter.tag = tag } label: {
                                Text(tag).font(.subheadline.weight(filter.tag == tag ? .semibold : .regular))
                                    .padding(.horizontal, 15).padding(.vertical, 9)
                                    .background(filter.tag == tag ? CineTheme.accent : Color.secondary.opacity(0.08), in: Capsule())
                                    .foregroundStyle(filter.tag == tag ? Color.white : .primary)
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .onChange(of: filter.kind) { _, _ in filter.tag = "热门" }
    }

    private func posterCard(_ item: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Button { selection = item } label: {
                PosterView(path: item.poster).aspectRatio(2 / 3, contentMode: .fit)
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
    private func load(reset: Bool) async {
        if !reset && loading { return }
        let identity = UUID()
        requestID = identity
        let currentFilter = filter
        let nextPage = reset ? 1 : page + 1
        if reset {
            items = []
            availability = []
            availabilityNote = nil
            page = 0
            hasMore = false
        }
        loading = true
        error = nil
        defer { if requestID == identity { loading = false } }
        do {
            let api = try store.requireClient()
            let result: RankingPage = try await api.get("api/resources/rankings", query: currentFilter.query(page: nextPage))
            try Task.checkCancellation()
            guard requestID == identity, filter == currentFilter else { return }
            let added = result.items ?? []
            var known = Set(items.map(\.stableID))
            items += added.filter { known.insert($0.stableID).inserted }
            page = result.page
            hasMore = result.hasMore
            // Availability is optional: a cache error must not hide the ranking.
            do {
                guard !added.isEmpty else { return }
                let response: AvailabilityResponse = try await api.send(
                    "POST", "api/resources/availability",
                    body: AvailabilityRequest(items: added.prefix(50).map(AvailabilityRequest.AvailabilityItem.init))
                )
                try Task.checkCancellation()
                guard requestID == identity else { return }
                for (item, available) in zip(added, response.available) where available {
                    availability.insert(item.stableID)
                }
            } catch {
                if !isCancellation(error), requestID == identity { availabilityNote = "资源标记暂不可用，榜单仍可正常浏览。" }
            }
        } catch {
            if !isCancellation(error), requestID == identity { self.error = error.localizedDescription }
        }
    }
}
