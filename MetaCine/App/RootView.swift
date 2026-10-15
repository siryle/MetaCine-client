import SwiftUI

struct RootView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        TabView(selection: $store.selectedTab) {
            DiscoverView()
                .tabItem { Label("发现", systemImage: "square.grid.2x2") }
                .tag(AppStore.Tab.discover)
            ResourceSearchView()
                .tabItem { Label("搜索", systemImage: "magnifyingglass") }
                .tag(AppStore.Tab.search)
            SubscriptionsView()
                .tabItem { Label("订阅", systemImage: "bookmark") }
                .tag(AppStore.Tab.subscriptions)
            HistoryView()
                .tabItem { Label("历史", systemImage: "clock.arrow.circlepath") }
                .tag(AppStore.Tab.history)
            ServersView()
                .tabItem { Label("服务器", systemImage: "externaldrive.connected.to.line.below") }
                .tag(AppStore.Tab.servers)
        }
        // Each connection owns its navigation, modal state, requests and image cache.
        .id(store.contextID)
    }
}
