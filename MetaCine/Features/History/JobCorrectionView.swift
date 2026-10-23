import SwiftUI

struct JobCorrectionView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let job: Job
    let entry: JobEntry
    let onSave: (Job) -> Void
    @State private var kind: MediaKind
    @State private var query: String
    @State private var year: Int
    @State private var tmdbID: Int
    @State private var season: Int
    @State private var episode: Int
    @State private var candidates: [MediaItem]
    @State private var searching = false
    @State private var searched = false
    @State private var saving = false
    @State private var error: String?
    @State private var searchID = UUID()

    init(job: Job, entry: JobEntry, onSave: @escaping (Job) -> Void) {
        self.job = job
        self.entry = entry
        self.onSave = onSave
        _kind = State(initialValue: MediaKind(rawValue: entry.media?.kind ?? entry.identity?.kind ?? job.rule.kind ?? "") ?? .movie)
        let title = [entry.identity?.title, entry.media?.title]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        _query = State(initialValue: title ?? (entry.source as NSString).lastPathComponent)
        _year = State(initialValue: entry.identity?.year ?? entry.media?.year ?? 0)
        _tmdbID = State(initialValue: entry.media?.tmdbID ?? entry.identity?.tmdbID ?? 0)
        _season = State(initialValue: max(0, entry.identity?.season ?? 1))
        _episode = State(initialValue: max(1, entry.identity?.episode ?? 1))
        _candidates = State(initialValue: entry.candidates ?? [])
    }

    var body: some View {
        Form {
            if let error { Section { ErrorBanner(message: error) } }
            Section("源文件") { Text(entry.source).font(.footnote).textSelection(.enabled) }
            Section {
                Picker("作品类型", selection: $kind) {
                    ForEach(MediaKind.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: kind) { _, _ in resetSearch() }
                TextField("作品名称", text: $query).autocorrectionDisabled()
                    .onSubmit { Task { await search() } }
                    .onChange(of: query) { _, _ in resetSearch() }
                numberField("年份（0 表示不限）", value: $year)
                    .onChange(of: year) { _, _ in resetSearch() }
                Button { Task { await search() } } label: {
                    HStack {
                        Text("搜索 TMDB")
                        Spacer()
                        if searching { ProgressView() }
                    }
                }.disabled(searching || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: { Text("查找正确作品") }
            if !candidates.isEmpty || searched {
                Section("选择搜索结果") {
                    ForEach(candidates.filter { $0.kind == kind.rawValue }, id: \.stableID) { media in
                        Button { tmdbID = media.tmdbID } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(media.title).foregroundStyle(.primary)
                                    Text("\(media.subtitle) · TMDB \(media.tmdbID)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if tmdbID == media.tmdbID { Image(systemName: "checkmark.circle.fill") }
                            }
                        }.disabled(media.tmdbID <= 0)
                    }
                    if searched, candidates.isEmpty { Text("暂无匹配作品，可更换片名或直接填写 TMDB ID。").foregroundStyle(.secondary) }
                }
            }
            Section {
                numberField("TMDB ID", value: $tmdbID)
                if kind == .tv {
                    numberField("季数（0 表示特别篇）", value: $season)
                    numberField("集数", value: $episode)
                }
            } header: { Text("校正身份") } footer: {
                Text("保存后由服务端核对作品、季集及目标路径冲突，只生成预览，不自动移动文件。返回任务详情核对目标路径，再选择文件并确认执行。")
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("校正匹配").navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(saving)
        .interactiveDismissDisabled(saving)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button { Task { await save() } } label: {
                    if saving { ProgressView() } else { Text("保存").bold() }
                }.disabled(saving || tmdbID <= 0)
            }
        }
        .disabled(saving)
        .onDisappear { resetSearch() }
    }

    private func numberField(_ title: String, value: Binding<Int>) -> some View {
        LabeledContent(title) {
            TextField("0", value: value, format: .number.grouping(.never))
                .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(minWidth: 60, maxWidth: 120)
        }
    }

    private func resetSearch() {
        tmdbID = 0
        searchID = UUID()
        searching = false
        searched = false
        candidates = []
    }

    @MainActor private func search() async {
        guard !searching else { return }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.utf8.count <= 200, year == 0 || (1900...2100).contains(year) else {
            error = "请输入 1–200 字节的片名，年份须为 1900–2100 或 0。"
            return
        }
        let identity = UUID()
        searchID = identity
        searching = true
        error = nil
        defer { if searchID == identity { searching = false } }
        do {
            let values: [MediaItem]? = try await store.requireClient().get("api/tmdb/search", query: [
                URLQueryItem(name: "query", value: query), URLQueryItem(name: "kind", value: kind.rawValue),
                URLQueryItem(name: "year", value: year > 0 ? String(year) : "")
            ])
            try Task.checkCancellation()
            guard searchID == identity else { return }
            var seen: Set<String> = []
            candidates = (values ?? []).filter { $0.kind == kind.rawValue && $0.tmdbID > 0 && seen.insert($0.stableID).inserted }
            searched = true
        } catch {
            if searchID == identity, !isCancellation(error) { self.error = error.localizedDescription }
        }
    }

    @MainActor private func save() async {
        guard !saving else { return }
        saving = true
        error = nil
        defer { saving = false }
        do {
            let updated = try await store.requireClient().correctJobEntry(entry, in: job, body: JobCorrectionBody(
                kind: kind, tmdbID: tmdbID, season: season, episode: episode
            ))
            onSave(updated)
            dismiss()
        } catch {
            if !isCancellation(error) { self.error = error.localizedDescription }
        }
    }
}
