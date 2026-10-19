import SwiftUI

struct SubscriptionEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var draft: SubscriptionDraft
    @State private var saving = false
    @State private var error: String?
    @State private var loadingDefaults = false
    @State private var defaultsError: String?

    var body: some View {
        NavigationStack {
            Form {
                if let error { Section { ErrorBanner(message: error) } }
                Section("作品") {
                    TextField("作品名称（必填）", text: $draft.title)
                        .onChange(of: draft.title) { _, _ in draft.clearMediaIdentity() }
                    Picker("作品类型", selection: $draft.kind) {
                        ForEach(MediaKind.allCases) { Text($0.title).tag($0) }
                    }
                    .onChange(of: draft.kind) { _, kind in
                        draft.clearMediaIdentity()
                        if kind == .movie { draft.season = 0 }
                    }
                    numberField("年份（0 表示不限）", value: $draft.year)
                    if draft.kind == .tv { numberField("季数（0 表示全部季）", value: $draft.season) }
                }
                Section {
                    Picker("资源来源", selection: $draft.source) {
                        ForEach(ResourceSource.allCases) { Text($0.title).tag($0) }
                    }
                    .disabled(loadingDefaults)
                    .onChange(of: draft.source) { _, _ in
                        defaultsError = nil
                        if draft.id == nil { draft.maxPoints = nil }
                    }
                    if draft.source.usesUnlockPoints {
                        Toggle("允许 API 自动付费解锁", isOn: $draft.autoUnlock)
                        if loadingDefaults { ProgressView("正在读取 RE0 账号积分上限…") }
                        if let defaultsError {
                            ErrorBanner(message: defaultsError) { Task { await loadDefaults() } }
                        }
                        if draft.maxPoints != nil {
                            numberField("每个资源积分上限", value: Binding(
                                get: { draft.maxPoints ?? 0 },
                                set: { draft.maxPoints = $0 }
                            ))
                        }
                        Button(draft.source.usesRE0DefaultPoints ? "恢复 RE0 账号默认上限" : "恢复免费资源上限") { Task { await loadDefaults() } }
                            .disabled(loadingDefaults || saving)
                    }
                } header: { Text("搜索来源") } footer: {
                    Text("全部来源依次检查 Telegram、RE0、HDHaven 和 jying。全部来源和 RE0 新订阅读取 RE0 账号积分上限；HDHaven 独立订阅默认上限为 0，可手动调整。RE0 和 HDHaven 专属订阅需要准确的 TMDB ID。积分上限和付费许可适用于 RE0、HDHaven；上限为 0 或关闭自动付费解锁时，仅处理免费或已解锁资源。")
                }
                Section {
                    Picker("资源类型", selection: $draft.resourceType) {
                        ForEach(ResourceKind.allCases) { Text($0.title).tag($0) }
                    }
                    TextField("版本关键词，如 2160p WEB-DL", text: $draft.quality)
                        .autocorrectionDisabled()
                    numberField("检查间隔（分钟）", value: $draft.intervalMinutes)
                    Toggle("启用订阅", isOn: $draft.enabled)
                } header: { Text("订阅偏好") } footer: {
                    Text("间隔 30–10080 分钟。多个版本关键词需要同时匹配。订阅检查由服务器持续执行，无需保持 App 打开。")
                }
                Section {
                    TextField("原始名称（可选）", text: $draft.originalTitle)
                    numberField("TMDB ID（0 表示未指定）", value: $draft.tmdbID)
                } header: { Text("作品身份") } footer: {
                    Text("从榜单订阅会自动填入作品信息。豆瓣 ID 不能填入 TMDB ID。修改名称或类型会清除原有作品身份和海报。")
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(draft.id == nil ? "新增订阅" : "编辑订阅")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await save() } } label: {
                        if saving { ProgressView() } else { Text("保存").bold() }
                    }.disabled(saving || loadingDefaults || (draft.source.usesUnlockPoints && draft.maxPoints == nil)
                               || draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .interactiveDismissDisabled(saving)
            .disabled(saving)
            .task(id: draft.source) {
                if draft.source.usesUnlockPoints, draft.maxPoints == nil { await loadDefaults() }
            }
        }
    }

    @MainActor private func loadDefaults() async {
        guard !loadingDefaults else { return }
        guard draft.source.usesRE0DefaultPoints else {
            draft.maxPoints = 0
            defaultsError = nil
            return
        }
        loadingDefaults = true
        defaultsError = nil
        defer { loadingDefaults = false }
        do {
            draft.maxPoints = try await store.requireClient().defaultUnlockPoints()
        } catch {
            if !isCancellation(error) { defaultsError = "读取 RE0 账号积分上限失败：\(error.localizedDescription)" }
        }
    }

    private func numberField(_ title: String, value: Binding<Int>) -> some View {
        LabeledContent(title) {
            TextField("0", value: value, format: .number.grouping(.never))
                .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(minWidth: 60, maxWidth: 120)
        }
    }

    @MainActor private func save() async {
        guard !saving else { return }
        saving = true
        error = nil
        defer { saving = false }
        do {
            _ = try await store.requireClient().saveSubscription(draft)
            store.subscriptionsDidChange()
            dismiss()
        } catch {
            if !isCancellation(error) { self.error = error.localizedDescription }
        }
    }
}
