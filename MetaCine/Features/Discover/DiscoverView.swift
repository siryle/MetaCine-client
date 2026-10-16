import SwiftUI

struct DiscoverView: View {
    @Environment(AppStore.self) private var store
    @State private var filter = RecommendationFilter()
    @State private var sections: [MediaCatalogSection] = []
    @State private var loading = false
    @State private var error: String?
    @State private var requestID = UUID()

    var body: some View {
        NavigationStack {
            ConnectionGate {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        intro
                        controls
                        if let error { ErrorBanner(message: error) { Task { await load(refresh: true) } } }
                        if loading {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("正在加载榜单…").font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        if sections.contains(where: { $0.error != nil }) {
                            ErrorBanner(message: "部分榜单暂不可用，其他榜单可继续浏览。") {
                                Task { await load(refresh: true) }
                            }
                        }
                        MediaCatalogView(sections: sections, tab: .discover, refreshID: requestID, horizontal: true)
                    }
                    .padding(20)
                }
                .refreshable { await load(refresh: true) }
                .task(id: filter) { await load() }
            }
            .background(CineBackdrop())
            .navigationTitle("发现")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { ServerIndicator() } }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionEyebrow(text: "METACINE / RANKINGS")
                Spacer()
                Image(systemName: "sparkle").foregroundStyle(CineTheme.accent)
            }
            Text("下一部，\n值得期待。")
                .font(.system(size: 36, weight: .semibold, design: .serif)).tracking(-1)
            Text("\(filter.provider.title)榜单推荐 · 横向滑动，发现更多作品。")
                .font(.subheadline).foregroundStyle(.secondary)
        }.padding(.vertical, 8)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(RecommendationProvider.all) { provider in
                        Button { filter.selectProvider(provider.id) } label: {
                            Text(provider.title).font(.subheadline.weight(filter.providerID == provider.id ? .semibold : .regular))
                                .padding(.horizontal, 15).padding(.vertical, 9)
                                .background(filter.providerID == provider.id ? CineTheme.accent : Color.secondary.opacity(0.08), in: Capsule())
                                .foregroundStyle(filter.providerID == provider.id ? Color.white : .primary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(filter.providerID == provider.id ? .isSelected : [])
                    }
                }
            }
            HStack {
                Picker("榜单分类", selection: $filter.category) {
                    Text("全部榜单").tag("all")
                    ForEach(filter.provider.categories) { Text($0.title).tag($0.id) }
                }
                Spacer(minLength: 0)
                if filter.provider.streaming {
                    Picker("国家与地区", selection: $filter.region) {
                        ForEach(filter.provider.regions) { Text($0.title).tag($0.id) }
                    }
                }
            }
            .font(.subheadline)
        }
    }

    @MainActor
    private func load(refresh: Bool = false) async {
        let identity = UUID()
        requestID = identity
        let currentFilter = filter
        let categories = currentFilter.categories
        sections = categories.map { MediaCatalogSection(id: $0.id, title: $0.title, loading: true) }
        loading = true
        error = nil
        defer { if requestID == identity { loading = false } }
        do {
            let api = try store.requireClient()
            // Bound concurrent upstream requests when loading every board for a provider.
            await withTaskGroup(of: (String, Result<RankingPage, Error>).self) { group in
                var next = 0
                func enqueue(_ category: CatalogChoice) {
                    group.addTask {
                        do {
                            let page: RankingPage = try await api.get(
                                currentFilter.endpoint, query: currentFilter.query(category: category.id, refresh: refresh)
                            )
                            return (category.id, .success(page))
                        } catch { return (category.id, .failure(error)) }
                    }
                }
                for category in categories.prefix(4) {
                    enqueue(category)
                    next += 1
                }
                for await (id, result) in group {
                    guard !Task.isCancelled, requestID == identity, filter == currentFilter else {
                        group.cancelAll()
                        return
                    }
                    if let index = sections.firstIndex(where: { $0.id == id }) {
                        sections[index].loading = false
                        switch result {
                        case .success(let page):
                            var seen: Set<String> = []
                            sections[index].items = (page.items ?? []).filter { seen.insert($0.stableID).inserted }
                            sections[index].stale = page.stale == true
                        case .failure(let failure):
                            if !isCancellation(failure) { sections[index].error = failure.localizedDescription }
                        }
                    }
                    if next < categories.count {
                        enqueue(categories[next])
                        next += 1
                    }
                }
            }
        } catch {
            if !isCancellation(error), requestID == identity {
                self.error = error.localizedDescription
                sections = []
            }
        }
    }
}
