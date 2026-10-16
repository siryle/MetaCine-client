import SwiftUI

enum CineTheme {
    static let accent = Color("AccentColor")
    static let background = Color("Canvas")
    static let ink = Color.primary
}

struct CineBackdrop: View {
    var body: some View {
        LinearGradient(
            colors: [CineTheme.background, CineTheme.accent.opacity(0.05), CineTheme.background],
            startPoint: .topLeading, endPoint: .bottomTrailing
        ).ignoresSafeArea()
    }
}

struct SectionEyebrow: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11, weight: .bold, design: .monospaced))
            .tracking(2).foregroundStyle(CineTheme.accent)
    }
}

struct ServerIndicator: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        Button {
            store.selectedTab = .servers
        } label: {
            HStack(spacing: 5) {
                Circle().fill(store.isConnected ? CineTheme.accent : Color.orange).frame(width: 6, height: 6)
                Text(store.activeServer?.name ?? "添加服务器").font(.caption).lineLimit(1)
            }
        }
        .accessibilityLabel("\(store.activeServer?.name ?? "服务器")，\(store.connectionLabel)")
    }
}

struct ConnectionGate<Content: View>: View {
    @Environment(AppStore.self) private var store
    @ViewBuilder var content: () -> Content
    var body: some View {
        if store.isConnected {
            content()
        } else if store.connection == .connecting {
            VStack(spacing: 16) {
                ProgressView()
                Text("正在连接 \(store.activeServer?.name ?? "MetaCine")…")
                    .font(.subheadline).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("连接你的影库", systemImage: "externaldrive.badge.wifi")
            } description: {
                if case .failed(let message) = store.connection {
                    Text(message)
                } else {
                    Text("添加 MetaCine 服务器，开始发现作品、搜索资源和管理订阅。")
                }
            } actions: {
                Button("管理服务器") { store.selectedTab = .servers }.buttonStyle(.borderedProminent)
                if store.activeServer != nil {
                    Button("重新连接") { store.reconnect() }
                }
            }
        }
    }
}

struct ErrorBanner: View {
    let message: String
    var retry: (() -> Void)?
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
            Text(message).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
            if let retry { Button("重试", action: retry).font(.footnote.bold()) }
        }
        .padding(14)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }
}

struct StatusPill: View {
    let title: String
    var color: Color = CineTheme.accent
    var body: some View {
        Text(title).font(.caption2.weight(.semibold))
            .foregroundStyle(color).padding(.horizontal, 9).padding(.vertical, 5)
            .background(color.opacity(0.10), in: Capsule())
    }
}

struct PosterView: View {
    @Environment(AppStore.self) private var store
    let path: String?
    var fallback: MediaItem?
    @State private var image: UIImage?
    @State private var loading = false
    @State private var failed = false
    @State private var attempt = 0
    @State private var requestID = UUID()

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(
                    colors: [CineTheme.accent.opacity(0.20), Color.secondary.opacity(0.08)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                } else if loading {
                    ProgressView().tint(CineTheme.accent)
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "film").font(.title2)
                        if failed {
                            Button("重试") { attempt += 1 }.font(.caption)
                        }
                    }.foregroundStyle(CineTheme.accent.opacity(0.65))
                }
            }
        }
        .clipped()
        .task(id: "\(store.client?.id.uuidString ?? ""):\(path ?? ""):\(fallback?.stableID ?? ""):\(attempt)") {
            let identity = UUID()
            requestID = identity
            loading = false
            failed = false
            guard let client = store.client, path?.isEmpty == false || fallback != nil else {
                image = nil
                return
            }
            image = client.cachedPoster(path: path, fallback: fallback)
            if image != nil { return }
            loading = true
            defer { if requestID == identity { loading = false } }
            do {
                let loaded = try await client.poster(path: path, fallback: fallback)
                try Task.checkCancellation()
                guard requestID == identity else { return }
                image = loaded
                failed = loaded == nil
            } catch {
                if !isCancellation(error), requestID == identity { failed = true }
            }
        }
        .accessibilityLabel("作品海报")
    }
}

struct InlineNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

extension View {
    func cineNotice(_ notice: Binding<InlineNotice?>) -> some View {
        alert(item: notice) { value in
            Alert(title: Text(value.title), message: Text(value.message), dismissButton: .default(Text("知道了")))
        }
    }
}

func isCancellation(_ error: Error) -> Bool {
    error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled
}
