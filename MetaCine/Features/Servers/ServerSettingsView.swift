import SwiftUI

struct RemoteSettings: Decodable {
    let language: String
    let downloadArt: Bool
    let requestTimeout: Int
    let apiKeySet: Bool
    let readTokenSet: Bool
    let proxyEnabled: Bool
    let proxySet: Bool
    let proxyURL: String

    enum CodingKeys: String, CodingKey {
        case language, downloadArt, requestTimeout, apiKeySet, readTokenSet, proxyEnabled, proxySet
        case proxyURL = "proxyUrl"
    }
}

private struct SettingsPatch: Encodable {
    var language: String
    var downloadArt: Bool
    var requestTimeout: Int
    var apiKey: String
    var readToken: String
    var proxyEnabled: Bool
    var proxyURL: String
}

struct ServerSettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var loaded = false
    @State private var loading = false
    @State private var saving = false
    @State private var error: String?
    @State private var notice: InlineNotice?
    @State private var language = "zh-CN"
    @State private var downloadArt = true
    @State private var timeout = 30
    @State private var apiKey = ""
    @State private var readToken = ""
    @State private var apiKeySet = false
    @State private var readTokenSet = false
    @State private var proxyEnabled = false
    @State private var proxyURL = ""
    @State private var proxySet = false

    var body: some View {
        Form {
            if let error { Section { ErrorBanner(message: error) { Task { await load() } } } }
            if loading { ProgressView("读取服务器设置…") }
            if loaded {
                Section("媒体数据") {
                    SecureField(apiKeySet ? "TMDB API Key（已配置，留空保留）" : "TMDB API Key", text: $apiKey)
                    SecureField(readTokenSet ? "TMDB Read Token（已配置，留空保留）" : "TMDB Read Token", text: $readToken)
                    Picker("元数据语言", selection: $language) {
                        Text("简体中文").tag("zh-CN")
                        Text("繁體中文").tag("zh-TW")
                        Text("English").tag("en-US")
                        if !["zh-CN", "zh-TW", "en-US"].contains(language) { Text(language).tag(language) }
                    }
                    Toggle("下载海报和图片", isOn: $downloadArt)
                    Stepper("请求超时：\(timeout) 秒", value: $timeout, in: 5...120, step: 5)
                }
                Section {
                    Toggle("启用代理", isOn: $proxyEnabled)
                    TextField(proxySet ? "已配置，留空保留现有地址" : "http://host:port", text: $proxyURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("服务器出站代理") } footer: {
                    Text("代理由 MetaCine 服务端使用。留空会保留现有地址及代理认证信息。")
                }
                Section {
                    Button { Task { await save() } } label: {
                        HStack {
                            Text("保存到服务器")
                            Spacer()
                            if saving { ProgressView() }
                        }
                    }.disabled(saving)
                } footer: {
                    Text("此处修改服务器的媒体数据与代理设置。资源频道、115 和 Emby 等高级设置可在服务端 Web 界面管理。")
                }
            }
        }
        .disabled(saving)
        .navigationTitle("服务端设置").navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .cineNotice($notice)
    }

    @MainActor private func load() async {
        guard !loading else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let result: RemoteSettings = try await store.requireClient().get("api/settings")
            language = result.language
            downloadArt = result.downloadArt
            timeout = result.requestTimeout
            apiKeySet = result.apiKeySet
            readTokenSet = result.readTokenSet
            proxyEnabled = result.proxyEnabled
            proxySet = result.proxySet
            loaded = true
        } catch { if !isCancellation(error) { self.error = error.localizedDescription } }
    }

    @MainActor private func save() async {
        guard !saving else { return }
        saving = true
        error = nil
        defer { saving = false }
        do {
            let result: RemoteSettings = try await store.requireClient().send(
                "PATCH", "api/settings",
                body: SettingsPatch(
                    language: language, downloadArt: downloadArt, requestTimeout: timeout,
                    apiKey: apiKey, readToken: readToken, proxyEnabled: proxyEnabled, proxyURL: proxyURL
                )
            )
            apiKey = ""
            readToken = ""
            proxyURL = ""
            apiKeySet = result.apiKeySet
            readTokenSet = result.readTokenSet
            proxySet = result.proxySet
            notice = InlineNotice(title: "设置已保存", message: "后续服务端请求和任务将使用新的设置。")
        } catch { if !isCancellation(error) { self.error = error.localizedDescription } }
    }
}
