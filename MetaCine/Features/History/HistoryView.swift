import SwiftUI

struct HistoryView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var jobs: [Job] = []
    @State private var filter = "all"
    @State private var query = ""
    @State private var error: String?
    @State private var loading = false
    @State private var deleting: Job?
    @State private var notice: InlineNotice?
    @State private var busy = false

    private var visible: [Job] {
        jobs.filter { job in
            let matches = query.isEmpty || job.rule.name.localizedCaseInsensitiveContains(query) ||
                job.id.localizedCaseInsensitiveContains(query) || job.message.localizedCaseInsensitiveContains(query)
            let status: Bool
            switch filter {
            case "active": status = job.isActive
            case "completed": status = job.status == "completed"
            case "problem": status = job.isProblem
            default: status = true
            }
            return matches && status
        }
    }

    var body: some View {
        NavigationStack {
            ConnectionGate {
                List {
                    Section {
                        HStack {
                            SectionEyebrow(text: "ACTIVITY / HISTORY")
                            Spacer()
                            Text("\(jobs.count) 个任务").font(.caption).foregroundStyle(.secondary)
                        }.listRowBackground(Color.clear)
                        Picker("任务状态", selection: $filter) {
                            Text("全部").tag("all")
                            Text("运行中").tag("active")
                            Text("已完成").tag("completed")
                            Text("异常").tag("problem")
                        }.pickerStyle(.segmented).listRowBackground(Color.clear)
                    }
                    if let error {
                        Section { ErrorBanner(message: error) { Task { await load() } } }
                    }
                    if loading && jobs.isEmpty {
                        ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
                    } else if visible.isEmpty {
                        ContentUnavailableView(
                            "暂无任务记录", systemImage: "clock.arrow.circlepath",
                            description: Text("订阅检查、资源转存和整理任务会出现在这里。")
                        ).listRowBackground(Color.clear)
                    } else {
                        ForEach(visible) { job in
                            NavigationLink { JobDetailView(jobID: job.id) } label: {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack(alignment: .top) {
                                        Text(job.rule.name.isEmpty ? "资源任务" : job.rule.name).font(.headline)
                                        Spacer(minLength: 5)
                                        StatusPill(title: JobStatus.title(job.status), color: statusColor(job))
                                    }
                                    Text(ServerDate.display(job.createdAt)).font(.caption).foregroundStyle(.secondary)
                                    if !job.message.isEmpty {
                                        Text(job.message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                    if job.canReviewMatches {
                                        Label("可在文件明细中校正匹配", systemImage: "pencil.circle")
                                            .font(.caption).foregroundStyle(CineTheme.accent)
                                    }
                                    HStack {
                                        Text("已处理 \(job.processed) / \(job.scanned)")
                                        Spacer()
                                        Text(job.rule.mode).font(.caption2.monospaced())
                                    }.font(.caption).foregroundStyle(.secondary)
                                    if job.isActive { ProgressView(value: job.progress) }
                                }.padding(.vertical, 7)
                            }
                            .swipeActions {
                                if !job.isActive {
                                    Button("删除", role: .destructive) { deleting = job }.disabled(busy)
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped).scrollContentBackground(.hidden)
                .searchable(text: $query, prompt: "搜索任务名称或消息")
                .refreshable { await load() }
                .task { await load() }
                .task(id: scenePhase) {
                    guard scenePhase == .active else { return }
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(10)) } catch { return }
                        await load(silent: true)
                    }
                }
            }
            .background(CineBackdrop())
            .navigationTitle("任务历史")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { ServerIndicator() } }
            .confirmationDialog("删除任务记录？", isPresented: Binding(
                get: { deleting != nil }, set: { if !$0 { deleting = nil } }
            ), titleVisibility: .visible, presenting: deleting) { job in
                Button("删除记录", role: .destructive) { Task { await delete(job) } }
            } message: { _ in Text("仅移除任务记录，不影响已整理的媒体文件。") }
            .cineNotice($notice)
        }
    }

    private func statusColor(_ job: Job) -> Color {
        job.isProblem ? .orange : (job.isActive ? .blue : CineTheme.accent)
    }

    @MainActor private func load(silent: Bool = false) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let response: [Job]? = try await store.requireClient().get("api/jobs")
            try Task.checkCancellation()
            jobs = ServerDate.newestFirst(response ?? [], by: \.createdAt)
            error = nil
        } catch {
            if !silent, !isCancellation(error) { self.error = error.localizedDescription }
        }
    }

    @MainActor private func delete(_ job: Job) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let response: JobDeletionResponse = try await store.requireClient().send(
                "POST", "api/jobs/delete", body: DeleteJobsBody(ids: [job.id])
            )
            if let message = response.failures?.values.first ?? response.storageError {
                notice = InlineNotice(title: "删除记录未完全成功", message: message)
            } else if !response.skipped.isEmpty {
                notice = InlineNotice(title: "任务暂不可删除", message: "服务器保留了正在运行或已发生变化的任务，请刷新后重试。")
            }
            await load()
        } catch {
            if !isCancellation(error) { notice = InlineNotice(title: "删除失败", message: error.localizedDescription) }
        }
    }
}
