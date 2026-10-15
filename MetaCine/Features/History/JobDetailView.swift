import SwiftUI

struct JobDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    let jobID: String
    @State private var job: Job?
    @State private var loading = false
    @State private var error: String?
    @State private var busy = false
    @State private var cancelConfirmation = false
    @State private var notice: InlineNotice?
    @State private var entryFilter = ""

    private var entries: [JobEntry] {
        (job?.entries ?? []).filter {
            entryFilter.isEmpty || $0.source.localizedCaseInsensitiveContains(entryFilter) ||
                $0.message.localizedCaseInsensitiveContains(entryFilter)
        }
    }

    var body: some View {
        List {
            if let error { Section { ErrorBanner(message: error) { Task { await load() } } } }
            if let job {
                Section {
                    HStack {
                        Text(job.rule.name.isEmpty ? "资源任务" : job.rule.name).font(.headline)
                        Spacer()
                        StatusPill(title: JobStatus.title(job.status), color: job.isProblem ? .orange : CineTheme.accent)
                    }
                    LabeledContent("开始时间", value: ServerDate.display(job.createdAt))
                    LabeledContent("最后更新", value: ServerDate.display(job.updatedAt))
                    LabeledContent("任务类型", value: job.rule.mode)
                    LabeledContent("处理进度", value: "\(job.processed) / \(job.scanned)")
                    if job.isActive { ProgressView(value: job.progress) }
                    if !job.message.isEmpty { Text(job.message).foregroundStyle(.secondary).textSelection(.enabled) }
                    Text("ID · \(job.id)").font(.caption.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
                } header: { Text("任务概况") }
                if let warnings = job.warnings, !warnings.isEmpty {
                    Section("提醒") {
                        ForEach(Array(warnings.enumerated()), id: \.offset) { _, message in
                            Label(message, systemImage: "exclamationmark.circle").foregroundStyle(.orange).font(.footnote)
                        }
                    }
                }
                if job.isActive {
                    Section {
                        Button("停止任务", role: .destructive) { cancelConfirmation = true }.disabled(busy)
                    } footer: { Text("停止请求不会回滚已完成的文件操作。") }
                }
                Section {
                    TextField("筛选文件或处理消息", text: $entryFilter)
                    ForEach(entries) { entry in
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 9) {
                                Text("来源").font(.caption.bold())
                                Text(entry.source).font(.caption).textSelection(.enabled)
                                if !entry.destination.isEmpty {
                                    Text("目标").font(.caption.bold())
                                    Text(entry.destination).font(.caption).textSelection(.enabled)
                                }
                                if !entry.message.isEmpty {
                                    Text(entry.message).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                                if entry.size > 0 {
                                    Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }.padding(.vertical, 8)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text((entry.source as NSString).lastPathComponent).font(.subheadline).lineLimit(2)
                                Text(JobStatus.title(entry.status)).font(.caption)
                                    .foregroundStyle(entry.status == "error" ? .orange : CineTheme.accent)
                            }
                        }
                    }
                    if entries.isEmpty { Text("暂无文件条目").foregroundStyle(.secondary) }
                } header: { Text("文件明细 · \(job.entries?.count ?? 0)") }
            } else if loading {
                ProgressView("正在加载任务…").frame(maxWidth: .infinity)
            }
        }
        .listStyle(.insetGrouped).scrollContentBackground(.hidden).background(CineBackdrop())
        .navigationTitle("任务详情").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        .refreshable { await load() }
        .task { await load() }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(4)) } catch { return }
                if job?.isActive == true { await load(silent: true) }
            }
        }
        .confirmationDialog("停止当前任务？", isPresented: $cancelConfirmation, titleVisibility: .visible) {
            Button("停止任务", role: .destructive) { Task { await cancel() } }
        }
        .cineNotice($notice)
    }

    @MainActor private func load(silent: Bool = false) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            job = try await store.requireClient().get("api/jobs/\(jobID)")
            error = nil
        } catch {
            if !silent, !isCancellation(error) { self.error = error.localizedDescription }
        }
    }

    @MainActor private func cancel() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await store.requireClient().perform("POST", "api/jobs/\(jobID)/cancel", body: EmptyBody())
            notice = InlineNotice(title: "已请求停止", message: "服务器正在结束当前操作，任务状态会自动更新。")
            await load()
        } catch {
            if !isCancellation(error) { notice = InlineNotice(title: "停止失败", message: error.localizedDescription) }
        }
    }
}
