import SwiftUI

struct SubscriptionEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var draft: SubscriptionDraft
    @State private var saving = false
    @State private var error: String?

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
                    }.disabled(saving || draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .interactiveDismissDisabled(saving)
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
            let value = try draft.validated()
            let path = "api/resources/subscriptions" + (value.id.map { "/\($0)" } ?? "")
            let _: ResourceSubscription = try await store.requireClient().send(
                value.id == nil ? "POST" : "PUT", path, body: value
            )
            store.subscriptionsDidChange()
            dismiss()
        } catch {
            if !isCancellation(error) { self.error = error.localizedDescription }
        }
    }
}
