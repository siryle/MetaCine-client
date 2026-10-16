import SwiftUI

struct MediaSearchView: View {
    @Environment(AppStore.self) private var store
    @FocusState private var searchFocused: Bool
    @State private var searchFieldBounds = CGRect.zero
    @State private var query = ""
    @State private var submittedQuery = ""
    @State private var searchID = UUID()
    @State private var requestID = UUID()
    @State private var refreshID = UUID()
    @State private var items: [MediaItem] = []
    @State private var page = 0
    @State private var remainingKinds: Set<MediaKind> = []
    @State private var stale = false
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ConnectionGate {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        searchField
                        if let error {
                            ErrorBanner(message: error) { Task { await load(reset: page == 0) } }
                        }
                        if loading, items.isEmpty {
                            ProgressView("正在搜索 TMDB 片库…")
                                .frame(maxWidth: .infinity).padding(.vertical, 60)
                        } else if submittedQuery.isEmpty {
                            ContentUnavailableView(
                                "搜索电影和电视剧", systemImage: "magnifyingglass",
                                description: Text("输入片名，搜索 TMDB 片库。")
                            )
                        } else if items.isEmpty, error == nil {
                            ContentUnavailableView(
                                "暂无匹配作品", systemImage: "film",
                                description: Text("试试其他片名或关键词。")
                            )
                        } else if !items.isEmpty {
                            Text("“\(submittedQuery)” · 已加载 \(items.count) 部作品")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        if !items.isEmpty {
                            MediaCatalogView(
                                sections: [MediaCatalogSection(id: "tmdb", items: items, stale: stale)],
                                tab: .search, refreshID: refreshID
                            )
                        }
                        if !remainingKinds.isEmpty {
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
                .refreshable {
                    if !submittedQuery.isEmpty { await load(reset: true, refresh: true) }
                }
                .task(id: searchID) { await load(reset: true) }
                .onAppear { consumeQuery() }
                .onChange(of: store.searchQuery) { _, _ in consumeQuery() }
                .onChange(of: query) { _, value in
                    if !submittedQuery.isEmpty, value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        submit()
                    }
                }
                .onDisappear { searchFocused = false }
            }
            .background(CineBackdrop())
            .navigationTitle("片名搜索")
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
                    .foregroundStyle(.secondary).accessibilityLabel("清空片名和搜索结果")
            }
            Button("搜索", action: submit).fontWeight(.semibold)
                .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(14).background(.background, in: RoundedRectangle(cornerRadius: 16))
    }

    private func consumeQuery() {
        guard !store.searchQuery.isEmpty else { return }
        query = store.searchQuery
        store.searchQuery = ""
        submit()
    }

    private func submit() {
        searchFocused = false
        submittedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchID = UUID()
    }

    @MainActor
    private func load(reset: Bool, refresh: Bool = false) async {
        if !reset && loading { return }
        let identity = UUID()
        requestID = identity
        let currentQuery = submittedQuery
        let nextPage = reset ? 1 : page + 1
        let kinds = reset ? MediaKind.allCases : MediaKind.allCases.filter { remainingKinds.contains($0) }
        if reset {
            refreshID = identity
            items = []
            page = 0
            remainingKinds = []
            stale = false
        }
        loading = true
        error = nil
        defer { if requestID == identity { loading = false } }
        guard !currentQuery.isEmpty else { return }
        do {
            let result = try await store.requireClient().searchTitles(
                currentQuery, page: nextPage, kinds: kinds, refresh: refresh
            )
            try Task.checkCancellation()
            guard requestID == identity, submittedQuery == currentQuery else { return }
            var seen = Set(items.map(\.stableID))
            items += result.items.filter { seen.insert($0.stableID).inserted }
            page = nextPage
            remainingKinds = result.remainingKinds
            stale = stale || result.stale
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
