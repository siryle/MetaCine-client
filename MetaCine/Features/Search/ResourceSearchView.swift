import SwiftUI

struct ResourceSearchView: View {
    @Environment(AppStore.self) private var store
    @FocusState private var searchFocused: Bool
    @State private var searchFieldBounds = CGRect.zero
    @State private var query = ""
    @State private var submittedQuery = ""
    @State private var searchID = UUID()
    @State private var requestID = UUID()
    @State private var results: [ResourceResult] = []
    @State private var warnings: [String] = []
    @State private var loading = false
    @State private var searched = false
    @State private var error: String?
    @State private var draft: SubscriptionDraft?
    @State private var expanded: Set<String> = []
    @State private var transfer: ResourceResult?
    @State private var transferring: Set<String> = []
    @State private var notice: InlineNotice?
    @State private var openedJob: Job?
    @State private var media: [ResourceMediaIdentity: MediaItem] = [:]

    private var channels: [String] { Array(Set(results.map(\.channel))).sorted() }

    var body: some View {
        NavigationStack {
            ConnectionGate {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        SectionEyebrow(text: "SEARCH / RESOURCES")
                        HStack(spacing: 12) {
                            Image(systemName: "magnifyingglass").foregroundStyle(CineTheme.accent)
                            TextField("搜索电影、电视剧…", text: $query)
                                .focused($searchFocused)
                                .submitLabel(.search).onSubmit(submit)
                                .autocorrectionDisabled()
                                .background {
                                    GeometryReader { geometry in
                                        Color.clear.preference(
                                            key: SearchFieldBoundsKey.self,
                                            value: geometry.frame(in: .named("resource-search"))
                                        )
                                    }
                                }
                            if !query.isEmpty {
                                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                                    .foregroundStyle(.secondary).accessibilityLabel("清空关键词")
                            }
                            Button("搜索", action: submit).fontWeight(.semibold).disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        .padding(14).background(.background, in: RoundedRectangle(cornerRadius: 16))
                        searchResults
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(20)
                }
                .coordinateSpace(name: "resource-search")
                .contentShape(Rectangle())
                .onPreferenceChange(SearchFieldBoundsKey.self) { searchFieldBounds = $0 }
                .simultaneousGesture(
                    SpatialTapGesture(coordinateSpace: .named("resource-search")).onEnded { value in
                        if !searchFieldBounds.isEmpty, !searchFieldBounds.contains(value.location) {
                            searchFocused = false
                        }
                    }
                )
                .scrollDismissesKeyboard(.interactively)
                .refreshable { if searched { await search() } }
                .task(id: searchID) { if !submittedQuery.isEmpty { await search() } }
                .onAppear { consumeQuery() }
                .onChange(of: store.searchQuery) { _, _ in consumeQuery() }
                .onDisappear { searchFocused = false }
            }
            .background(CineBackdrop())
            .navigationTitle("资源搜索")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { ServerIndicator() }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { searchFocused = false }
                }
            }
            .sheet(item: $draft) { value in SubscriptionEditor(draft: value) }
            .sheet(item: $openedJob) { job in NavigationStack { JobDetailView(jobID: job.id) } }
            .confirmationDialog("将此资源交给服务器转存或离线下载？", isPresented: Binding(
                get: { transfer != nil }, set: { if !$0 { transfer = nil } }
            ), titleVisibility: .visible, presenting: transfer) { result in
                Button("开始转存 / 下载") { Task { await performTransfer(result) } }
                Button("取消", role: .cancel) {}
            } message: { result in Text(result.title) }
            .cineNotice($notice)
        }
    }

    private var searchResults: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let error { ErrorBanner(message: error, retry: submit) }
            ForEach(warnings, id: \.self) { ErrorBanner(message: $0) }
            if loading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在搜索已配置的频道…").font(.subheadline).foregroundStyle(.secondary)
                    Text("首次搜索可能需要一些时间").font(.caption).foregroundStyle(.tertiary)
                }.frame(maxWidth: .infinity).padding(.vertical, 60)
            } else if !searched {
                ContentUnavailableView {
                    Label("好资源，从这里找到", systemImage: "sparkle.magnifyingglass")
                } description: {
                    Text("搜索服务器已配置的公开频道与缓存，支持 115、磁力和电驴资源。")
                }
            } else if results.isEmpty, error == nil {
                ContentUnavailableView.search(text: submittedQuery)
            } else {
                Text("“\(submittedQuery)” · \(results.count) 个资源")
                    .font(.subheadline).foregroundStyle(.secondary)
                ForEach(channels, id: \.self) { channel in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(channel).font(.headline)
                            Spacer()
                            Text("\(results.filter { $0.channel == channel }.count)")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        ForEach(results.filter { $0.channel == channel }) { result in
                            resourceCard(result)
                        }
                    }
                }
            }
        }
    }

    private func resourceCard(_ result: ResourceResult) -> some View {
        let identity = ResourceMediaIdentity(result)
        let matched = media[identity]
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                PosterView(path: matched?.poster)
                    .frame(width: 76, height: 114)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 8) {
                    Text(matched?.title ?? identity.title)
                        .font(.subheadline.weight(.semibold)).lineLimit(3).textSelection(.enabled)
                    HStack(spacing: 6) {
                        StatusPill(title: result.resourceKind.title)
                        Text([
                            (matched?.mediaKind ?? identity.kind)?.title,
                            (matched?.year ?? identity.year) > 0 ? String(matched?.year ?? identity.year) : nil
                        ].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    if let season = result.season, season > 0 {
                        Text("第 \(season) 季" + ((result.episode ?? 0) > 0 ? " · 第 \(result.episode!) 集" : ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !result.specifications.isEmpty {
                        Text(result.specifications).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    resourceLinkActions(result).fixedSize()
                    Spacer(minLength: 8)
                    resourcePrimaryActions(result).fixedSize()
                }
                VStack(alignment: .leading, spacing: 8) {
                    resourceLinkActions(result)
                    HStack {
                        Spacer(minLength: 0)
                        resourcePrimaryActions(result)
                    }
                }
            }
            if expanded.contains(result.id) {
                Text(result.rawText ?? result.shareURL).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled).padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(14).background(.background, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.secondary.opacity(0.09)))
    }

    private func resourceLinkActions(_ result: ResourceResult) -> some View {
        HStack(spacing: 12) {
            Button {
                if expanded.contains(result.id) { expanded.remove(result.id) }
                else { expanded.insert(result.id) }
            } label: {
                Label(expanded.contains(result.id) ? "收起" : "原文", systemImage: "text.alignleft")
                    .frame(minHeight: 32)
            }
            ShareLink(item: result.shareURL) {
                Image(systemName: "square.and.arrow.up").frame(minWidth: 28, minHeight: 32)
            }
            .accessibilityLabel("分享资源链接")
            Button {
                UIPasteboard.general.string = result.shareURL
                notice = InlineNotice(title: "链接已复制", message: "已保留完整链接及提取码。")
            } label: {
                Image(systemName: "doc.on.doc").frame(minWidth: 28, minHeight: 32)
            }.accessibilityLabel("复制资源链接")
        }.font(.caption)
    }

    private func resourcePrimaryActions(_ result: ResourceResult) -> some View {
        HStack(spacing: 8) {
            Button {
                if let matched = media[ResourceMediaIdentity(result)] {
                    var value = matched.subscription()
                    value.season = matched.mediaKind == .tv ? (result.season ?? 0) : 0
                    value.resourceType = result.resourceKind
                    draft = value
                } else {
                    draft = result.subscription()
                }
            } label: { Label("追更", systemImage: "bookmark") }
            .buttonStyle(.bordered)
            Button { transfer = result } label: {
                HStack(spacing: 4) {
                    if transferring.contains(result.id) { ProgressView() }
                    Text(result.type == "share" ? "转存" : "下载")
                }
            }
            .buttonStyle(.borderedProminent).disabled(transferring.contains(result.id))
            .accessibilityLabel(result.type == "share" ? "转存资源" : "离线下载资源")
        }.font(.caption).controlSize(.small)
    }

    private func consumeQuery() {
        guard !store.searchQuery.isEmpty else { return }
        query = store.searchQuery
        store.searchQuery = ""
        submit()
    }

    private func submit() {
        searchFocused = false
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        submittedQuery = value
        searchID = UUID()
    }

    @MainActor private func search() async {
        let identity = UUID()
        requestID = identity
        loading = true
        searched = true
        error = nil
        results = []
        warnings = []
        expanded = []
        media = [:]
        defer { if requestID == identity { loading = false } }
        do {
            let api = try store.requireClient()
            let response: SearchResponse = try await api.send(
                "POST", "api/resources/search", body: QueryBody(query: submittedQuery)
            )
            try Task.checkCancellation()
            guard requestID == identity else { return }
            var seen: Set<String> = []
            results = (response.results ?? []).filter { seen.insert($0.id).inserted }
            warnings = Array(Set(response.warnings ?? [])).sorted()
            loading = false
            await enrichResults(using: api, identity: identity)
        } catch {
            if !isCancellation(error), requestID == identity { self.error = error.localizedDescription }
        }
    }

    @MainActor private func enrichResults(using api: APIClient, identity: UUID) async {
        guard !results.isEmpty else { return }
        let session: ServerSession? = try? await api.get("api/session")
        guard requestID == identity, !Task.isCancelled,
              session?.tmdbConfigured ?? (store.serverSession?.tmdbConfigured ?? false) else { return }
        var known: Set<ResourceMediaIdentity> = []
        let identities = results.map(ResourceMediaIdentity.init).filter { known.insert($0).inserted }
        await withTaskGroup(of: (ResourceMediaIdentity, MediaItem?).self) { group in
            var next = 0
            // Resolve each work once, with at most three requests in flight.
            for key in identities.prefix(3) {
                group.addTask { (key, try? await api.resourceMedia(for: key)) }
                next += 1
            }
            for await (key, value) in group {
                guard requestID == identity, !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                if let value { media[key] = value }
                if next < identities.count {
                    let key = identities[next]
                    group.addTask { (key, try? await api.resourceMedia(for: key)) }
                    next += 1
                }
            }
        }
    }

    @MainActor private func performTransfer(_ result: ResourceResult) async {
        guard !transferring.contains(result.id) else { return }
        transferring.insert(result.id)
        defer { transferring.remove(result.id) }
        do {
            let response: TransferResponse = try await store.requireClient().send(
                "POST", "api/resources/transfer", body: TransferBody(text: result.shareURL)
            )
            openedJob = response.job
            if response.duplicate {
                notice = InlineNotice(title: "资源已提交过", message: "已打开对应任务，不会重复下载。")
            }
        } catch {
            if !isCancellation(error) { notice = InlineNotice(title: "提交失败", message: error.localizedDescription) }
        }
    }
}

private struct SearchFieldBoundsKey: PreferenceKey {
    static var defaultValue: CGRect { .zero }

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}
