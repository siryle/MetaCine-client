import SwiftUI

struct MediaCatalogView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    let sections: [MediaCatalogSection]
    let tab: AppStore.Tab
    let refreshID: UUID
    var horizontal = false
    @State private var statuses: [String: MediaLibraryStatus] = [:]
    @State private var statusIdentities: [String: AvailabilityRequest.AvailabilityItem] = [:]
    @State private var statusRevision: UUID?
    @State private var statusError: String?
    @State private var statusRequestID = UUID()
    @State private var subscribing: Set<String> = []
    @State private var notice: InlineNotice?

    private var items: [MediaItem] {
        var seen: Set<String> = []
        return sections.flatMap(\.items).filter { seen.insert($0.stableID).inserted }
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 24) {
            if let statusError {
                ErrorBanner(message: statusError) { Task { await loadStatuses() } }
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
        .task(id: StatusKey(
            revision: refreshID, subscriptions: store.subscriptionsRevision,
            items: items.map(\.stableID), active: store.selectedTab == tab && scenePhase == .active
        )) {
            guard store.selectedTab == tab, scenePhase == .active else { return }
            while !Task.isCancelled {
                await loadStatuses()
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            }
        }
        .cineNotice($notice)
    }

    private struct StatusKey: Equatable {
        let revision: UUID
        let subscriptions: UUID
        let items: [String]
        let active: Bool
    }

    private func posterCard(_ item: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            NavigationLink {
                MediaDetailView(item: item)
            } label: {
                PosterView(path: item.artwork, fallback: item).aspectRatio(2 / 3, contentMode: .fit)
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
            .overlay(alignment: .topTrailing) {
                subscriptionControl(item).padding(8)
            }
            .clipShape(RoundedRectangle(cornerRadius: 15))
            NavigationLink {
                MediaDetailView(item: item)
            } label: {
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

    @ViewBuilder
    private func subscriptionControl(_ item: MediaItem) -> some View {
        if let status = statuses[item.stableID] {
            let busy = subscribing.contains(item.stableID)
            if status.canSubscribe {
                Button { Task { await subscribe(item) } } label: {
                    subscriptionBadge(busy ? "订阅中" : status.title, loading: busy)
                }
                .buttonStyle(.plain)
                .disabled(busy)
                .accessibilityLabel("订阅\(item.title)")
                .accessibilityHint("使用默认偏好一键订阅")
            } else {
                subscriptionBadge(status.title).allowsHitTesting(false)
            }
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
    private func subscribe(_ item: MediaItem) async {
        guard statuses[item.stableID]?.canSubscribe == true, subscribing.insert(item.stableID).inserted else { return }
        let context = store.contextID
        defer { subscribing.remove(item.stableID) }
        do {
            let api = try store.requireClient()
            var draft = item.subscription()
            if let identity = statusIdentities[item.stableID] {
                draft.title = identity.title
                draft.originalTitle = identity.originalTitle
                draft.tmdbID = identity.tmdbID
                draft.year = identity.year
            }
            _ = try await api.saveSubscription(draft)
            guard store.contextID == context else { return }
            statusRequestID = UUID()
            statuses[item.stableID] = MediaLibraryStatus(inLibrary: false, subscribed: true)
            store.subscriptionsDidChange()
        } catch {
            if !isCancellation(error), store.contextID == context {
                notice = InlineNotice(title: "订阅失败", message: error.localizedDescription)
                await loadStatuses()
            }
        }
    }

    @MainActor
    private func loadStatuses() async {
        let identity = UUID()
        statusRequestID = identity
        if statusRevision != refreshID {
            statusRevision = refreshID
            statuses = [:]
            statusIdentities = [:]
        }
        let currentItems = items
        guard !currentItems.isEmpty else { return }
        statusError = nil
        do {
            let api = try store.requireClient()
            let ready = currentItems.filter {
                statusIdentities[$0.stableID] != nil || $0.source?.hasPrefix("douban") != true
            }
            for start in stride(from: 0, to: ready.count, by: 50) {
                let chunk = Array(ready[start..<min(start + 50, ready.count)])
                let hints = chunk.map { statusIdentities[$0.stableID] ?? AvailabilityRequest.AvailabilityItem($0) }
                do {
                    let values = try await api.libraryStatuses(for: hints)
                    try Task.checkCancellation()
                    guard statusRequestID == identity else { return }
                    for (item, value) in zip(chunk, values) { statuses[item.stableID] = value }
                } catch {
                    if isCancellation(error) { return }
                    guard statusRequestID == identity else { return }
                    for item in chunk { statuses[item.stableID] = nil }
                    statusError = "库存与订阅状态暂不可用，可重试或稍后自动更新。"
                }
            }
            let pending = currentItems.filter {
                $0.source?.hasPrefix("douban") == true && statusIdentities[$0.stableID] == nil
            }
            await withTaskGroup(of: (String, Result<(AvailabilityRequest.AvailabilityItem, MediaLibraryStatus), Error>).self) { group in
                var next = 0
                func enqueue(_ item: MediaItem) {
                    group.addTask {
                        do {
                            let hint = try await api.libraryIdentity(for: item)
                            let values = try await api.libraryStatuses(for: [hint])
                            return (item.stableID, .success((hint, values[0])))
                        } catch { return (item.stableID, .failure(error)) }
                    }
                }
                // Resolve and update Douban entries individually, with at most three in flight.
                for item in pending.prefix(3) {
                    enqueue(item)
                    next += 1
                }
                for await (key, result) in group {
                    guard !Task.isCancelled, statusRequestID == identity else {
                        group.cancelAll()
                        return
                    }
                    switch result {
                    case .success(let (hint, value)):
                        statusIdentities[key] = hint
                        statuses[key] = value
                    case .failure(let error):
                        if !isCancellation(error) {
                            statuses[key] = nil
                            statusError = "库存与订阅状态暂不可用，可重试或稍后自动更新。"
                        }
                    }
                    if next < pending.count {
                        enqueue(pending[next])
                        next += 1
                    }
                }
            }
        } catch {
            if !isCancellation(error), statusRequestID == identity {
                statuses = [:]
                statusError = "库存与订阅状态暂不可用：\(error.localizedDescription)"
            }
        }
    }
}
