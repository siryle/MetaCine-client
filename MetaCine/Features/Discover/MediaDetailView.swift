import SwiftUI

struct MediaDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let item: MediaItem
    @State private var resolved: MediaItem?
    @State private var detail: MediaDetail?
    @State private var loading = false
    @State private var error: String?
    @State private var draft: SubscriptionDraft?
    @State private var showingResources = false

    private var currentItem: MediaItem { resolved ?? item }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .top, spacing: 18) {
                        PosterView(path: detail?.poster ?? currentItem.artwork)
                            .frame(width: 116, height: 174).clipShape(RoundedRectangle(cornerRadius: 14))
                        VStack(alignment: .leading, spacing: 10) {
                            SectionEyebrow(text: item.sourceTitle)
                            Text(currentItem.title).font(.system(.title2, design: .serif).bold())
                            Text(currentItem.subtitle).font(.subheadline).foregroundStyle(.secondary)
                            if let rating = detail?.rating ?? currentItem.rating, rating > 0 {
                                Label(String(format: "%.1f", rating), systemImage: "star.fill")
                                    .foregroundStyle(.orange).font(.headline)
                            }
                            Text((detail?.genres ?? currentItem.genres ?? []).joined(separator: " / "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if loading { ProgressView("正在读取作品资料…") }
                    if let error { ErrorBanner(message: error) { Task { await load() } } }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("剧情简介").font(.headline)
                        Text(nonempty(detail?.overview) ?? nonempty(currentItem.overview) ?? "暂无剧情简介")
                            .font(.body).foregroundStyle(.secondary).lineSpacing(6).textSelection(.enabled)
                    }
                    let directors = detail?.directors ?? currentItem.directors ?? []
                    if !directors.isEmpty {
                        LabeledContent("导演", value: directors.joined(separator: " / ")).font(.subheadline)
                    }
                    let actors = detail?.actorNames ?? currentItem.cast?.map(\.name) ?? []
                    if !actors.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("主演").font(.headline)
                            Text(actors.prefix(15).joined(separator: " / ")).foregroundStyle(.secondary)
                        }.font(.subheadline)
                    }
                }.padding(22)
            }
            .background(CineBackdrop())
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    Button {
                        showingResources = true
                    } label: {
                        Label("搜索资源", systemImage: "magnifyingglass").frame(maxWidth: .infinity)
                    }.buttonStyle(.bordered)
                    Button { draft = subscriptionDraft() } label: {
                        Label("订阅作品", systemImage: "bookmark.fill").frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).disabled(loading)
                }.padding().background(.regularMaterial)
            }
            .navigationTitle("作品详情").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
            .task { await load() }
            .sheet(item: $draft) { value in SubscriptionEditor(draft: value) }
            .sheet(isPresented: $showingResources) { ResourceSearchView(initialQuery: currentItem.title) }
        }
    }

    private func subscriptionDraft() -> SubscriptionDraft {
        var value = currentItem.subscription()
        value.year = detail?.year ?? value.year
        value.originalTitle = detail?.originalTitle ?? value.originalTitle
        value.poster = detail?.poster ?? value.poster
        return value
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    @MainActor private func load() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            let api = try store.requireClient()
            if item.tmdbID > 0 {
                detail = try await api.get("api/resources/rankings/tmdb/\(item.kind)/\(item.tmdbID)")
            } else {
                if item.source?.hasPrefix("douban") == true {
                    guard let id = item.doubanID, id.allSatisfy(\.isNumber), !id.isEmpty else {
                        throw APIError.validation("豆瓣条目缺少有效 ID。")
                    }
                    detail = try await api.get(
                        "api/resources/rankings/douban/\(id)",
                        query: [URLQueryItem(name: "kind", value: item.kind)]
                    )
                }
                let result = try await api.resolveCatalog(item, detail: detail)
                try Task.checkCancellation()
                if result.matched, let media = result.media, media.tmdbID > 0 {
                    resolved = media
                    detail = nil
                }
            }
        } catch {
            if !isCancellation(error) {
                self.error = error.localizedDescription + "；仍可按榜单信息订阅或搜索资源。"
            }
        }
    }
}
