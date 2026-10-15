import SwiftUI

struct ResourceSearchView: View {
    @Environment(AppStore.self) private var store
    @State private var query = ""
    @State private var submittedQuery = ""
    @State private var searchID = UUID()
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
                                .submitLabel(.search).onSubmit(submit)
                                .autocorrectionDisabled()
                            if !query.isEmpty {
                                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                                    .foregroundStyle(.secondary).accessibilityLabel("清空关键词")
                            }
                            Button("搜索", action: submit).fontWeight(.semibold).disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        .padding(14).background(.background, in: RoundedRectangle(cornerRadius: 16))
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
                    }.padding(20)
                }
                .refreshable { if searched { await search() } }
                .task(id: searchID) { if !submittedQuery.isEmpty { await search() } }
                .onAppear { consumeQuery() }
                .onChange(of: store.searchQuery) { _, _ in consumeQuery() }
            }
            .background(CineBackdrop())
            .navigationTitle("资源搜索")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { ServerIndicator() } }
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

    private func resourceCard(_ result: ResourceResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: result.type == "share" ? "externaldrive.fill" : "arrow.down.circle.fill")
                    .font(.title2).foregroundStyle(CineTheme.accent).padding(.top, 3)
                VStack(alignment: .leading, spacing: 6) {
                    Text(result.title).font(.headline).textSelection(.enabled)
                    HStack {
                        StatusPill(title: result.resourceKind.title)
                        if let season = result.season, season > 0 {
                            Text("第 \(season) 季" + ((result.episode ?? 0) > 0 ? " · 第 \(result.episode!) 集" : ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !result.specifications.isEmpty {
                Text(result.specifications).font(.caption).foregroundStyle(.secondary)
            }
            if expanded.contains(result.id) {
                Text(result.rawText ?? result.shareURL).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled).padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }
            HStack(spacing: 18) {
                Button {
                    if expanded.contains(result.id) { expanded.remove(result.id) }
                    else { expanded.insert(result.id) }
                } label: { Label("原文", systemImage: "text.alignleft") }
                ShareLink(item: result.shareURL) { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("分享资源链接")
                Button {
                    UIPasteboard.general.string = result.shareURL
                    notice = InlineNotice(title: "链接已复制", message: "已保留完整链接及提取码。")
                } label: { Image(systemName: "doc.on.doc") }.accessibilityLabel("复制资源链接")
                Spacer(minLength: 0)
                Button { draft = result.subscription() } label: { Label("追更", systemImage: "bookmark") }
            }.font(.caption)
            Button { transfer = result } label: {
                HStack {
                    if transferring.contains(result.id) { ProgressView() }
                    Label("转存 / 离线下载", systemImage: "arrow.down.to.line")
                }.frame(maxWidth: .infinity)
            }.buttonStyle(.bordered).disabled(transferring.contains(result.id))
        }
        .padding(16).background(.background, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.secondary.opacity(0.09)))
    }

    private func consumeQuery() {
        guard !store.searchQuery.isEmpty else { return }
        query = store.searchQuery
        store.searchQuery = ""
        submit()
    }

    private func submit() {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        submittedQuery = value
        searchID = UUID()
    }

    @MainActor private func search() async {
        let identity = searchID
        loading = true
        searched = true
        error = nil
        results = []
        warnings = []
        expanded = []
        defer { if searchID == identity { loading = false } }
        do {
            let response: SearchResponse = try await store.requireClient().send(
                "POST", "api/resources/search", body: QueryBody(query: submittedQuery)
            )
            try Task.checkCancellation()
            guard searchID == identity else { return }
            var seen: Set<String> = []
            results = (response.results ?? []).filter { seen.insert($0.id).inserted }
            warnings = Array(Set(response.warnings ?? [])).sorted()
        } catch {
            if !isCancellation(error), searchID == identity { self.error = error.localizedDescription }
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
