import SwiftUI

@main
struct MetaCineApp: App {
    @State private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .tint(CineTheme.accent)
                .task { store.start() }
        }
    }
}
