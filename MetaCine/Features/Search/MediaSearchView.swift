import SwiftUI

struct MediaSearchView: View {
    @Environment(AppStore.self) private var store
    @FocusState private var searchFocused: Bool
    @State private var searchFieldBounds = CGRect.zero
    @State private var query = ""
    @State private var filter = MediaExploreFilter()
    @State private var searchID = UUID()
    @State private var requestID = UUID()
    @State private var refreshID = UUID()
    @State private var items: [MediaItem] = []
    @State private var page = 0
    @State private var hasMore = false
    @State private var stale = false
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ConnectionGate {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionEyebrow(text: "SEARCH / TMDB")
                            Text("探索你的下一部。").font(.system(.largeTitle, design: .serif).weight(.semibold))
                            Text("按偏好探索 TMDB 片库，或输入片名查找电影和电视剧。")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        searchField
                        controls
                        if let error {
                            ErrorBanner(message: error) { Task { await load(reset: page == 0) } }
                        }
                        if loading, items.isEmpty {
                            ProgressView("正在搜索 TMDB 片库…")
                                .frame(maxWidth: .infinity).padding(.vertical, 60)
                        } else if items.isEmpty, error == nil {
                            ContentUnavailableView(
                                "暂无匹配作品", systemImage: "film",
                                description: Text("试试其他片名、作品类型或年份，也可重置筛选。")
                            )
                        } else if !items.isEmpty {
                            Text(filter.searching ? "“\(filter.query)” · 已加载 \(items.count) 部作品" : "TMDB 片库 · 已加载 \(items.count) 部作品")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        MediaCatalogView(
                            sections: [MediaCatalogSection(id: "tmdb", items: items, stale: stale)],
                            tab: .search, refreshID: refreshID
                        )
                        if hasMore {
                            Button { Task { await load(reset: false) } } label: {
                                HStack {
                                    if loading { ProgressView() }
                                    Text(loading ? "加载中…" : "加载更多作品")
                                }
                                .frame(maxWidth: .infinity).padding(.vertical, 10)
                            }
                            .buttonStyle(.bordered).disabled(loading)
                        }
                    }.padding(20)
                }
                .coordinateSpace(name: "media-search")
                .contentShape(Rectangle())
                .onPreferenceChange(MediaSearchFieldBoundsKey.self) { searchFieldBounds = $0 }
                .scrollDismissesKeyboard(.interactively)
                .simultaneousGesture(
                    SpatialTapGesture(coordinateSpace: .named("media-search")).onEnded { value in
                        if !searchFieldBounds.isEmpty, !searchFieldBounds.contains(value.location) {
                            searchFocused = false
                        }
                    }
                )
                .refreshable { await load(reset: true, refresh: true) }
                .task(id: SearchKey(filter: filter, revision: searchID)) { await load(reset: true) }
                .onAppear { consumeQuery() }
                .onChange(of: store.searchQuery) { _, _ in consumeQuery() }
                .onDisappear { searchFocused = false }
            }
            .background(CineBackdrop())
            .navigationTitle("TMDB 片库")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { ServerIndicator() }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { searchFocused = false }
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").foregroundStyle(CineTheme.accent)
            TextField("输入电影或电视剧名称…", text: $query)
                .focused($searchFocused).submitLabel(.search).onSubmit(submit)
                .autocorrectionDisabled()
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: MediaSearchFieldBoundsKey.self,
                            value: geometry.frame(in: .named("media-search"))
                        )
                    }
                }
            if !query.isEmpty {
                Button {
                    query = ""
                    submit()
                } label: { Image(systemName: "xmark.circle.fill") }
                    .foregroundStyle(.secondary).accessibilityLabel("清空片名并浏览片库")
            }
            Button("搜索", action: submit).fontWeight(.semibold)
        }
        .padding(14).background(.background, in: RoundedRectangle(cornerRadius: 16))
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("作品类型", selection: Binding(
                get: { filter.kind },
                set: { filter.kind = $0; filter.genre = "" }
            )) {
                ForEach(MediaKind.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    genrePicker
                    regionPicker
                    yearPicker
                    sortPicker
                }
                .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 6) {
                    HStack { genrePicker; Spacer(); regionPicker }
                    HStack { yearPicker; Spacer(); sortPicker }
                }
            }
            if filter.searching {
                Text("片名搜索支持作品类型和年份；清空片名可按分类、地区和排序探索。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("重置筛选") {
                searchFocused = false
                query = ""
                filter = MediaExploreFilter()
            }.font(.caption)
        }
    }

    private var genrePicker: some View {
        Picker("分类", selection: $filter.genre) {
            Text("全部分类").tag("")
            ForEach(filter.genres) { Text($0.title).tag($0.id) }
        }.disabled(filter.searching)
    }

    private var regionPicker: some View {
        Picker("地区", selection: $filter.region) {
            Text("全部地区").tag("")
            ForEach(MediaExploreFilter.regions) { Text($0.title).tag($0.id) }
        }.disabled(filter.searching)
    }

    private var yearPicker: some View {
        Picker("年份", selection: $filter.year) {
            Text("全部年份").tag("")
            ForEach(MediaExploreFilter.years, id: \.self) { Text($0).tag($0) }
        }
    }

    private var sortPicker: some View {
        Picker("排序", selection: $filter.sort) {
            Text("热度").tag("popular")
            Text("最新").tag("latest")
            Text("评分").tag("rating")
        }.disabled(filter.searching)
    }

    private struct SearchKey: Equatable {
        let filter: MediaExploreFilter
        let revision: UUID
    }

    private func consumeQuery() {
        guard !store.searchQuery.isEmpty else { return }
        query = store.searchQuery
        store.searchQuery = ""
        submit()
    }

    private func submit() {
        searchFocused = false
        filter.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchID = UUID()
    }

    @MainActor
    private func load(reset: Bool, refresh: Bool = false) async {
        if !reset && loading { return }
        let identity = UUID()
        requestID = identity
        let currentFilter = filter
        let nextPage = reset ? 1 : page + 1
        if reset {
            refreshID = identity
            items = []
            page = 0
            hasMore = false
            stale = false
        }
        loading = true
        error = nil
        defer { if requestID == identity { loading = false } }
        do {
            guard currentFilter.query.utf8.count <= 200 else {
                throw APIError.validation("搜索片名最多 200 字节，请缩短关键词。")
            }
            let result: RankingPage = try await store.requireClient().get(
                "api/resources/explore", query: currentFilter.query(page: nextPage, refresh: refresh)
            )
            try Task.checkCancellation()
            guard requestID == identity, filter == currentFilter else { return }
            var seen = Set(items.map(\.stableID))
            items += (result.items ?? []).filter { seen.insert($0.stableID).inserted }
            page = result.page
            hasMore = result.hasMore
            stale = stale || result.stale == true
        } catch {
            if !isCancellation(error), requestID == identity { self.error = error.localizedDescription }
        }
    }
}

private struct MediaSearchFieldBoundsKey: PreferenceKey {
    static var defaultValue: CGRect { .zero }

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}
