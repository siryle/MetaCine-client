import Foundation

struct JobMediaIdentity: Decodable {
    let title: String?
    let year: Int?
    let kind: String?
    let tmdbID: Int?
    let season: Int?
    let episode: Int?

    enum CodingKeys: String, CodingKey {
        case title, year, kind, season, episode
        case tmdbID = "tmdbId"
    }
}

extension Job {
    var canReviewMatches: Bool {
        status == "preview" || (rule.mode == "organize" && !(resourceKey ?? "").isEmpty &&
            ["partial", "failed", "cancelled", "interrupted"].contains(status))
    }

    func canCorrect(_ entry: JobEntry) -> Bool {
        canReviewMatches && entry.moved == false &&
            ["ready", "unmatched", "ambiguous", "error", "conflict", "no_subtitle"].contains(entry.status)
    }

    var executableEntries: [JobEntry] {
        guard status == "preview", rule.mode == "organize" else { return [] }
        return (entries ?? []).filter { $0.status == "ready" && $0.moved == false && $0.media != nil }
    }
}

struct JobCorrectionBody: Encodable {
    let kind: MediaKind
    let tmdbID: Int
    var season: Int? = nil
    var episode: Int? = nil

    func validated() throws -> Self {
        guard tmdbID > 0 else { throw APIError.validation("请选择正确的作品或填写有效的 TMDB ID。") }
        if kind == .tv {
            guard let season, (0...999).contains(season), let episode, (1...9999).contains(episode) else {
                throw APIError.validation("电视剧季数须为 0–999，集数须为 1–9999。第 0 季表示特别篇。")
            }
            return self
        }
        return Self(kind: kind, tmdbID: tmdbID)
    }
}

private struct JobExecutionBody: Encodable {
    let entries: [String]
}

extension APIClient {
    func correctJobEntry(_ entry: JobEntry, in job: Job, body: JobCorrectionBody) async throws -> Job {
        guard let current = job.entries?.first(where: { $0.id == entry.id }), job.canCorrect(current) else {
            throw APIError.validation("此任务或文件暂不可校正，请刷新任务状态后重试。")
        }
        let updated: Job = try await send(
            "PUT", "api/jobs/\(job.id)/entries/\(entry.id)/match", body: body.validated()
        )
        guard updated.id == job.id else { throw APIError.invalidResponse }
        return updated
    }

    func executeJobEntries(_ ids: [String], in job: Job) async throws -> Job {
        let ready = Set(job.executableEntries.map(\.id))
        let selected = Set(ids)
        guard !selected.isEmpty, selected.count == ids.count, selected.isSubset(of: ready) else {
            throw APIError.validation("请选择预览中尚未移动且可执行的文件，或刷新任务后重试。")
        }
        let updated: Job = try await send("POST", "api/jobs/\(job.id)/execute", body: JobExecutionBody(entries: ids))
        guard updated.id == job.id else { throw APIError.invalidResponse }
        return updated
    }
}
