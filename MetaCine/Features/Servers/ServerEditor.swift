import SwiftUI

struct ServerEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var profile: ServerProfile
    let isNew: Bool
    @State private var credential = ServerCredential()
    @State private var testing = false
    @State private var tested = false
    @State private var error: String?
    @State private var testDescription: String?
    @State private var loaded = false

    private var fingerprint: String {
        "\(profile.address)|\(profile.authMethod)|\(credential.username)|\(credential.password)|\(credential.token)"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称，如 家庭影库", text: $profile.name)
                    TextField("http://192.168.1.10:8080", text: $profile.address)
                        .keyboardType(.URL).textContentType(.URL).textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: { Text("服务器") } footer: {
                    Text("填写 MetaCine 服务地址，支持端口和反向代理子路径。这里不是 Gitea 源码仓库地址。")
                }
                Section {
                    Picker("登录方式", selection: $profile.authMethod) {
                        ForEach(ServerProfile.AuthMethod.allCases) { Text($0.title).tag($0) }
                    }
                    if profile.authMethod == .password {
                        TextField("用户名", text: $credential.username)
                            .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("密码", text: $credential.password).textContentType(.password)
                    } else {
                        SecureField("METACINE_AUTH_TOKEN", text: $credential.token)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                } header: { Text("身份验证") } footer: {
                    Text("用户名和密码对应服务端 METACINE_USERNAME / METACINE_PASSWORD。令牌方式需要服务端配置 METACINE_AUTH_TOKEN。")
                }
                Section {
                    Button { Task { await test() } } label: {
                        HStack {
                            Label(testing ? "正在测试…" : "测试连接", systemImage: "network")
                            Spacer()
                            if testing { ProgressView() }
                            else if tested { Image(systemName: "checkmark.circle.fill").foregroundStyle(CineTheme.accent) }
                        }
                    }.disabled(testing || profile.address.isEmpty)
                    if let testDescription { Text(testDescription).font(.footnote).foregroundStyle(CineTheme.accent) }
                    if let error { ErrorBanner(message: error) }
                } footer: {
                    Text("首次访问局域网时，请允许本地网络权限。HTTP 适用于受信任的局域网，外网连接建议使用 HTTPS。")
                }
            }
            .navigationTitle(isNew ? "添加服务器" : "编辑服务器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(testing) }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.bold().disabled(testing || !loaded) }
            }
            .interactiveDismissDisabled(testing)
            .task {
                guard !loaded else { return }
                do { credential = try CredentialStore.read(profile.id); loaded = true }
                catch { self.error = error.localizedDescription }
            }
            .onChange(of: fingerprint) { _, _ in tested = false; testDescription = nil }
        }
    }

    private func validatedProfile() throws -> ServerProfile {
        var value = profile
        value.address = try ServerProfile.normalizedURL(profile.address).absoluteString
        if profile.authMethod == .password {
            guard !credential.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !credential.password.isEmpty else {
                throw APIError.validation("请输入用户名和密码。")
            }
        } else if credential.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw APIError.validation("请输入访问令牌。")
        }
        return value
    }

    private func save() {
        do {
            let value = try validatedProfile()
            var saved = credential
            if profile.authMethod == .password { saved.token = "" }
            else { saved.username = ""; saved.password = "" }
            try store.save(value, credential: saved)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    @MainActor private func test() async {
        testing = true
        error = nil
        tested = false
        testDescription = nil
        let original = fingerprint
        defer { testing = false }
        do {
            let api = try APIClient(profile: validatedProfile(), credential: credential)
            defer { api.invalidate() }
            let result = try await api.connect()
            guard original == fingerprint else { return }
            tested = true
            testDescription = "连接成功 · \(result.name) \(result.version)"
        } catch {
            if !isCancellation(error), original == fingerprint { self.error = error.localizedDescription }
        }
    }
}
