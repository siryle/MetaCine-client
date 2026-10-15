import SwiftUI

struct ServersView: View {
    @Environment(AppStore.self) private var store
    @State private var editor: ServerProfile?
    @State private var deleting: ServerProfile?
    @State private var notice: InlineNotice?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionEyebrow(text: "METACINE / CONNECTIONS")
                        Text("你的影库，随身连接。").font(.system(.title2, design: .serif).bold())
                        Text("连接自托管 MetaCine 服务，管理每一份期待。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.vertical, 10).listRowBackground(Color.clear)
                }
                if store.servers.isEmpty {
                    Section {
                        ContentUnavailableView {
                            Label("添加第一台服务器", systemImage: "externaldrive.badge.plus")
                        } description: {
                            Text("填写 MetaCine 服务地址，以及登录账号或访问令牌。")
                        } actions: {
                            Button("添加服务器", action: add).buttonStyle(.borderedProminent)
                        }
                    }
                } else {
                    Section("我的服务器") {
                        ForEach(store.servers) { profile in
                            serverRow(profile)
                                .swipeActions(edge: .trailing) {
                                    Button("删除", role: .destructive) { deleting = profile }
                                    Button("编辑") { editor = profile }.tint(CineTheme.accent)
                                }
                        }
                        Button(action: add) { Label("添加服务器", systemImage: "plus.circle") }
                    }
                }
                if let active = store.activeServer {
                    Section("当前连接") {
                        LabeledContent("服务器", value: active.name)
                        LabeledContent("状态", value: store.connectionLabel)
                        if case .failed(let message) = store.connection {
                            ErrorBanner(message: message)
                        }
                        if let session = store.serverSession {
                            LabeledContent("服务端版本", value: session.version)
                            LabeledContent("媒体目录", value: session.mediaRoot)
                            LabeledContent("TMDB", value: session.tmdbConfigured ? "已配置" : "未配置")
                            NavigationLink {
                                ServerSettingsView()
                            } label: { Label("服务端设置", systemImage: "slider.horizontal.3") }
                        }
                        Button("重新连接", systemImage: "arrow.clockwise") { store.reconnect() }
                            .disabled(store.connection == .connecting)
                        Button("编辑连接", systemImage: "pencil") { editor = active }
                        if store.isConnected {
                            Button("断开连接", systemImage: "network.slash", role: .destructive) { store.disconnect() }
                        }
                    }
                }
                Section {
                    LabeledContent("客户端版本", value: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0")")
                    Text("账号密码和令牌保存在设备钥匙串。服务器地址和名称仅保存在本机。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("后台订阅、转存和整理由服务器执行。未签名 IPA 需要签名后安装。")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: { Text("关于 MetaCine") }
            }
            .listStyle(.insetGrouped).scrollContentBackground(.hidden).background(CineBackdrop())
            .navigationTitle("服务器")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(action: add) { Image(systemName: "plus") } } }
            .sheet(item: $editor) { profile in ServerEditor(profile: profile, isNew: !store.servers.contains { $0.id == profile.id }) }
            .confirmationDialog("删除服务器配置？", isPresented: Binding(
                get: { deleting != nil }, set: { if !$0 { deleting = nil } }
            ), titleVisibility: .visible, presenting: deleting) { profile in
                Button("删除服务器", role: .destructive) {
                    do { try store.delete(profile) }
                    catch { notice = InlineNotice(title: "删除失败", message: error.localizedDescription) }
                }
            } message: { profile in Text("移除“\(profile.name)”的本机连接及钥匙串凭据，不会修改服务器数据。") }
            .cineNotice($notice)
        }
    }

    private func add() {
        editor = ServerProfile(name: "", address: "")
    }

    private func serverRow(_ profile: ServerProfile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.fill").font(.title2)
                .foregroundStyle(CineTheme.accent).frame(width: 34)
            VStack(alignment: .leading, spacing: 5) {
                Text(profile.name).font(.headline)
                Text(profile.address).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if store.activeID == profile.id {
                    Text(store.connectionLabel).font(.caption2).foregroundStyle(store.isConnected ? CineTheme.accent : .secondary)
                }
            }
            Spacer(minLength: 4)
            Menu {
                Button("连接", systemImage: "network") { store.activate(profile) }
                Button("编辑", systemImage: "pencil") { editor = profile }
                Button("删除", systemImage: "trash", role: .destructive) { deleting = profile }
            } label: {
                Image(systemName: store.activeID == profile.id && store.isConnected ? "checkmark.circle.fill" : "ellipsis.circle")
                    .font(.title3).padding(.vertical, 10)
            }.accessibilityLabel("管理服务器 \(profile.name)")
        }.padding(.vertical, 6)
    }
}
