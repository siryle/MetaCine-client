import SwiftUI

struct ResourceSearchView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let initialQuery: String
    let initialMedia: ResourceMediaHint?
    @FocusState private var searchFocused: Bool
    @State private var searchFieldBounds = CGRect.zero
    @State private var query = ""
    @State private var submittedQuery = ""
    @State private var searchID = UUID()
    @State private var requestID = UUID()
    @State private var groups: [ResourceProviderState] = []
    @State private var sourceFilter: ResourceSource = .all
    @State private var loading = false
    @State private var searched = false
    @State private var error: String?
    @State private var draft: SubscriptionDraft?
    @State private var expanded: Set<String> = []
    @State private var transfer: ResourceResult?
    @State private var transferring: Set<String> = []
    @State private var unlocking: Set<String> = []
    @State private var subscribing: Set<String> = []
    @State private var subscribed: Set<String> = []
    @State private var unlock: ResourceResult?
    @State private var notice: InlineNotice?
    @State private var openedJob: Job?
    @State private var media: [ResourceMediaIdentity: MediaItem] = [:]
    @State private var initialized = false

    init(initialQuery: String = "", media: ResourceMediaHint? = nil) {
        self.initialQuery = initialQuery
        self.initialMedia = media
    }

    private var results: [ResourceResult] { groups.flatMap(\.results) }
    private var currentMedia: ResourceMediaHint? {
        initialMedia.flatMap { $0.matchesQuery(submittedQuery) ? $0 : nil }
    }

    var body: some View {
        NavigationStack {
            searchPage
                .sheet(item: $draft) { value in SubscriptionEditor(draft: value) }
                .sheet(item: $openedJob) { job in NavigationStack { JobDetailView(jobID: job.id) } }
                .cineNotice($notice)
        }
    }

    private var searchPage: some View {
        resourceDialogs
            .background(CineBackdrop())
            .navigationTitle("资源搜索")
            .toolbar { searchToolbar }
    }

    @ToolbarContentBuilder
    private var searchToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) { Button("完成") { dismiss() } }
        ToolbarItem(placement: .topBarTrailing) { ServerIndicator() }
        ToolbarItemGroup(placement: .keyboard) {
            Spacer()
            Button("完成") { searchFocused = false }
        }
    }

    private var resourceDialogs: some View {
        transferConfirmation
            .confirmationDialog("获取 \(unlock?.resourceSource.title ?? "") 资源链接？", isPresented: Binding<Bool>(
                get: { unlock != nil }, set: { if !$0 { unlock = nil } }
            ), titleVisibility: .visible, presenting: unlock) { result in
                Button("确认获取链接") { Task { await performUnlock(result) } }
                Button("取消", role: .cancel) {}
            } message: { result in
                Text(result.unlocked == true ? "资源已解锁，确认获取链接？" : "预计消耗 \(result.unlockPoints ?? 0) 积分，服务端会在解锁前核对积分上限。")
            }
    }

    private var transferConfirmation: some View {
        ConnectionGate { searchContent }
            .confirmationDialog("将此资源交给服务器转存或离线下载？", isPresented: Binding<Bool>(
                get: { transfer != nil }, set: { if !$0 { transfer = nil } }
            ), titleVisibility: .visible, presenting: transfer) { result in
                Button("开始转存 / 下载") { Task { await performTransfer(result) } }
                Button("取消", role: .cancel) {}
            } message: { result in Text(result.title) }
    }

    private var searchContent: some View {
        searchScrollView
            .scrollDismissesKeyboard(.interactively)
            .refreshable { if searched { await search() } }
            .task(id: searchID) { if !submittedQuery.isEmpty { await search() } }
            .onAppear(perform: initializeSearch)
            .onDisappear { searchFocused = false }
    }

    private var searchScrollView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SectionEyebrow(text: "SEARCH / RESOURCES")
                searchBar
                sourcePicker
                searchResults.frame(maxWidth: .infinity, alignment: .leading)
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
    }

    private var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").foregroundStyle(CineTheme.accent)
            searchInput
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .foregroundStyle(.secondary).accessibilityLabel("清空关键词")
            }
            Button("搜索", action: submit)
                .fontWeight(.semibold)
                .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(14).background(.background, in: RoundedRectangle(cornerRadius: 16))
    }

    private var searchInput: some View {
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
    }

    private var sourcePicker: some View {
        Picker("资源来源", selection: $sourceFilter) {
            ForEach(ResourceSource.allCases) { source in
                Text("\(source.title) \(resultCount(for: source))").tag(source)
            }
        }.pickerStyle(.segmented)
    }

    private func resultCount(for source: ResourceSource) -> Int {
        source == .all ? results.count : results.filter { $0.resourceSource == source }.count
    }

    private func initializeSearch() {
        guard !initialized else { return }
        initialized = true
        query = initialQuery
        if !query.isEmpty { submit() }
    }

    private var searchResults: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let error { ErrorBanner(message: error, retry: submit) }
            if !searched {
                ContentUnavailableView {
                    Label("好资源，从这里找到", systemImage: "sparkle.magnifyingglass")
                } description: {
                    Text("同时搜索 RE0、HDHaven 和 Telegram，支持 115、磁力和电驴资源。")
                }
            } else {
                Text("“\(submittedQuery)” · \(results.count) 个资源\(loading ? " · 搜索中…" : "")")
                    .font(.subheadline).foregroundStyle(.secondary)
                ForEach(groups.filter { sourceFilter == .all || $0.source == sourceFilter }) { group in
                    providerResults(group)
                }
            }
        }
    }

    private func providerResults(_ group: ResourceProviderState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(group.source.title) · \(group.results.count) 条").font(.headline)
                Spacer()
                if group.loading { ProgressView().controlSize(.small) }
            }
            if let error = group.error { ErrorBanner(message: error, retry: submit) }
            ForEach(group.warnings, id: \.self) { ErrorBanner(message: $0) }
            if group.results.isEmpty, !group.loading, group.error == nil {
                Text("此来源暂无匹配资源。").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(Array(Set(group.results.map(\.channel))).sorted(), id: \.self) { channel in
                if group.source == .telegram {
                    Text(channel).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                }
                ForEach(group.results.filter { $0.channel == channel }) { resourceCard($0) }
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
                    if result.resourceSource.supportsUnlock {
                        Text("\(result.resourceSource.title) · \(result.unlockStatus)").font(.caption).foregroundStyle(.secondary)
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
                VStack(alignment: .leading, spacing: 8) {
                    Text(result.rawText ?? result.title).textSelection(.enabled)
                    if let url = URL(string: result.postURL) {
                        Link(result.resourceSource.supportsUnlock ? "查看 \(result.resourceSource.title) 资源" : "查看频道消息", destination: url)
                    }
                }
                    .font(.caption).foregroundStyle(.secondary).padding(12)
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
            ShareLink(item: result.link) {
                Image(systemName: "square.and.arrow.up").frame(minWidth: 28, minHeight: 32)
            }
            .accessibilityLabel(result.needsUnlock ? "分享 \(result.resourceSource.title) 资源页" : "分享资源链接")
            Button {
                UIPasteboard.general.string = result.link
                notice = InlineNotice(title: "链接已复制", message: result.needsUnlock ? "已复制 \(result.resourceSource.title) 资源页，获取链接后可复制下载地址。" : "已保留完整链接及提取码。")
            } label: {
                Image(systemName: "doc.on.doc").frame(minWidth: 28, minHeight: 32)
            }.accessibilityLabel("复制资源链接")
        }.font(.caption)
    }

    private func resourcePrimaryActions(_ result: ResourceResult) -> some View {
        HStack(spacing: 8) {
            Button { Task { await subscribe(result) } } label: {
                if subscribing.contains(result.id) { ProgressView() }
                else { Label(subscribed.contains(result.id) ? "已订阅" : "一键订阅", systemImage: "bookmark") }
            }
            .buttonStyle(.bordered)
            .disabled(subscribing.contains(result.id) || subscribed.contains(result.id))
            .contextMenu { Button("订阅设置") { draft = subscriptionDraft(result) } }
            Button {
                if result.needsUnlock {
                    do {
                        _ = try ResourceUnlockBody(result)
                        unlock = result
                    } catch {
                        notice = InlineNotice(title: "无法获取链接", message: error.localizedDescription)
                    }
                } else {
                    transfer = result
                }
            } label: {
                HStack(spacing: 4) {
                    if transferring.contains(result.id) || unlocking.contains(result.id) { ProgressView() }
                    Text(result.needsUnlock ? "获取链接" : result.type == "share" ? "转存" : "下载")
                }
            }
            .buttonStyle(.borderedProminent).disabled(transferring.contains(result.id) || unlocking.contains(result.id))
            .accessibilityLabel(result.needsUnlock ? "获取 \(result.resourceSource.title) 资源链接" : result.type == "share" ? "转存资源" : "离线下载资源")
        }.font(.caption).controlSize(.small)
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
        groups = ResourceSource.providers.map { ResourceProviderState(source: $0) }
        expanded = []
        media = [:]
        defer { if requestID == identity { loading = false } }
        do {
            let api = try store.requireClient()
            let query = submittedQuery
            let hint = currentMedia
            await withTaskGroup(of: (ResourceSource, Result<SearchResponse, Error>).self) { group in
                for source in ResourceSource.providers {
                    group.addTask {
                        do { return (source, .success(try await api.searchResources(query, source: source, media: hint))) }
                        catch { return (source, .failure(error)) }
                    }
                }
                for await (source, outcome) in group {
                    guard requestID == identity, !Task.isCancelled else {
                        group.cancelAll()
                        return
                    }
                    guard let index = groups.firstIndex(where: { $0.source == source }) else { continue }
                    groups[index].loading = false
                    switch outcome {
                    case .success(let response):
                        var seen: Set<String> = []
                        groups[index].results = (response.results ?? []).filter {
                            (hint?.matches($0) ?? true) && seen.insert($0.id).inserted
                        }
                        groups[index].warnings = Array(Set(response.warnings ?? [])).sorted()
                    case .failure(let error):
                        if !isCancellation(error) { groups[index].error = error.localizedDescription }
                    }
                }
            }
            guard requestID == identity, !Task.isCancelled else { return }
            loading = false
            await enrichResults(using: api, identity: identity)
        } catch {
            if !isCancellation(error), requestID == identity { self.error = error.localizedDescription }
        }
    }

    private func subscriptionDraft(_ result: ResourceResult) -> SubscriptionDraft {
        var value = media[ResourceMediaIdentity(result)]?.subscription() ?? result.subscription()
        if let hint = currentMedia, hint.matches(result) {
            value.title = hint.title
            value.originalTitle = hint.originalTitle
            if hint.tmdbID > 0 { value.tmdbID = hint.tmdbID }
            value.kind = MediaKind(rawValue: hint.kind) ?? value.kind
            if hint.year > 0 { value.year = hint.year }
        }
        value.season = value.kind == .tv ? (result.season ?? currentMedia?.season ?? 0) : 0
        value.resourceType = result.resourceKind
        return value
    }

    @MainActor private func subscribe(_ result: ResourceResult) async {
        guard !subscribed.contains(result.id), subscribing.insert(result.id).inserted else { return }
        defer { subscribing.remove(result.id) }
        do {
            _ = try await store.requireClient().saveSubscription(subscriptionDraft(result))
            subscribed.insert(result.id)
            store.subscriptionsDidChange()
            notice = InlineNotice(title: "订阅已创建", message: "服务器将按订阅的来源和积分上限持续检查资源。")
        } catch {
            if !isCancellation(error) { notice = InlineNotice(title: "订阅失败", message: error.localizedDescription) }
        }
    }

    @MainActor private func performUnlock(_ result: ResourceResult) async {
        guard unlocking.insert(result.id).inserted else { return }
        let identity = requestID
        defer { unlocking.remove(result.id) }
        do {
            let unlocked = try await store.requireClient().unlockResource(result)
            guard requestID == identity else { return }
            for group in groups.indices {
                if let index = groups[group].results.firstIndex(where: { $0.id == result.id }) {
                    groups[group].results[index] = unlocked
                }
            }
            notice = InlineNotice(title: "已获取资源链接", message: "可复制或分享完整链接，或继续转存 / 离线下载。")
        } catch {
            if !isCancellation(error), requestID == identity {
                notice = InlineNotice(title: "获取链接失败", message: error.localizedDescription)
            }
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
            guard !result.shareURL.isEmpty else { throw APIError.validation("请先获取 \(result.resourceSource.title) 资源链接。") }
            let hint = currentMedia ?? media[ResourceMediaIdentity(result)].map { ResourceMediaHint($0.subscription()) }
            let response: TransferResponse = try await store.requireClient().send(
                "POST", "api/resources/transfer", body: TransferBody(text: result.shareURL, media: hint)
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

private struct ResourceProviderState: Identifiable {
    let source: ResourceSource
    var results: [ResourceResult] = []
    var warnings: [String] = []
    var error: String?
    var loading = true
    var id: ResourceSource { source }
}

private struct SearchFieldBoundsKey: PreferenceKey {
    static var defaultValue: CGRect { .zero }

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}
