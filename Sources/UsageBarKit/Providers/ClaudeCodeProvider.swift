import Foundation

/// Local source for Claude Code usage.
///
/// Claude Code appends one JSON object per line to
/// `~/.claude/projects/<project-slug>/<session-id>.jsonl`. Assistant turns carry
/// `message.usage`:
///   { input_tokens, output_tokens,
///     cache_creation_input_tokens, cache_read_input_tokens,
///     cache_creation: { ephemeral_1h_input_tokens, ephemeral_5m_input_tokens },
///     server_tool_use: { web_search_requests, web_fetch_requests } }
/// and `message.model`. Turns are keyed by `message.id`, which repeats when a message is
/// replayed, so duplicates are dropped.
///
/// Cost is deliberately nil: the only cost figure Claude Code writes is
/// `{"type":"cost-state","totalCostUSD":…}` — a per-session running total with no per-day
/// breakdown, so it cannot be attributed to the selected range.
///
/// There is no public endpoint for the subscription's rate-limit windows; the OAuth token
/// in `~/.claude/.credentials.json` expires and cannot be refreshed from here. The provider
/// therefore reports local usage only.
public struct ClaudeCodeProvider: Sendable {
    public struct Config: Sendable {
        public var projectsURL: URL
        public var cacheURL: URL
        public init(projectsURL: URL, cacheURL: URL) {
            self.projectsURL = projectsURL
            self.cacheURL = cacheURL
        }
    }

    public init(config: Config) { self.config = config }
    public let config: Config

    public static var defaultConfig: Config {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return Config(
            projectsURL: home.appendingPathComponent(".claude/projects"),
            cacheURL: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("com.usagebar.app/claude-usage-cache.json")
        )
    }

    public func report(range: TimeRange, now: Date = Date()) throws -> UsageReport {
        let fm = FileManager.default
        guard fm.fileExists(atPath: config.projectsURL.path) else {
            throw ProviderError.unavailable("no ~/.claude/projects")
        }
        let files = try Self.jsonlFiles(under: config.projectsURL)
        guard !files.isEmpty else { throw ProviderError.unavailable("no Claude Code transcripts") }

        var cache = FileCache.load(from: config.cacheURL)
        var perDay: [String: [String: Bucket]] = [:]
        var cacheDirty = false

        for url in files {
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let key = url.path
            let day: [String: [String: Bucket]]
            if let hit = cache.files[key], hit.size == size, abs(hit.mtime - mtime) < 0.5 {
                day = hit.days
            } else {
                day = Self.aggregate(url: url)
                cache.files[key] = FileCache.Entry(mtime: mtime, size: size, days: day)
                cacheDirty = true
            }
            for (d, models) in day {
                for (m, b) in models {
                    var bucket = perDay[d]?[m] ?? Bucket()
                    bucket += b
                    perDay[d, default: [:]][m] = bucket
                }
            }
        }
        if cacheDirty { cache.save(to: config.cacheURL) }

        let allowed = range.dayKeys(now: now)
        var models: [String: Bucket] = [:]
        var daily: [String: Bucket] = [:]
        for (d, byModel) in perDay where allowed.contains(d) {
            for (m, b) in byModel {
                models[m, default: Bucket()] += b
                daily[d, default: Bucket()] += b
            }
        }

        var totals = UsageTotals()
        totals.costMicroIDR = nil
        var modelRows: [ModelUsage] = []
        for (m, b) in models {
            modelRows.append(ModelUsage(provider: "claude", model: m, requests: b.requests,
                                        inputTokens: b.input, outputTokens: b.output,
                                        cacheReadTokens: b.cacheRead,
                                        cacheWriteTokens: b.cacheWrite,
                                        costMicroIDR: nil))
            totals.requests += b.requests
            totals.inputTokens += b.input
            totals.outputTokens += b.output
            totals.cacheReadTokens += b.cacheRead
            totals.cacheWriteTokens += b.cacheWrite
        }
        modelRows.sort { $0.totalTokens > $1.totalTokens }

        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: now)
        let anchor = range == .yesterday
            ? (cal.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday)
            : startOfToday
        let count = range == .last30 ? 30 : 1
        var points: [DailyPoint] = []
        for i in stride(from: count - 1, through: 0, by: -1) {
            guard let d = cal.date(byAdding: .day, value: -i, to: anchor) else { continue }
            let b = daily[DayKey.string(d)] ?? Bucket()
            points.append(DailyPoint(date: d, requests: b.requests, costMicroIDR: 0,
                                     tokens: b.input + b.output))
        }

        return UsageReport(range: range, totals: totals, models: modelRows, daily: points,
                           source: .claudeLocal, fetchedAt: Date())
    }

    // MARK: - Parsing

    struct Bucket: Codable, Hashable {
        var requests = 0
        var input = 0
        var output = 0
        var cacheRead = 0
        var cacheWrite = 0
        var searches = 0

        static func += (lhs: inout Bucket, rhs: Bucket) {
            lhs.requests += rhs.requests; lhs.input += rhs.input; lhs.output += rhs.output
            lhs.cacheRead += rhs.cacheRead; lhs.cacheWrite += rhs.cacheWrite
            lhs.searches += rhs.searches
        }
    }

    /// One pass over one transcript. Tolerant: a malformed line is skipped, not fatal.
    static func aggregate(url: URL) -> [String: [String: Bucket]] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [:] }
        defer { try? handle.close() }
        guard let data = try? handle.readToEnd() else { return [:] }

        var out: [String: [String: Bucket]] = [:]
        var seen = Set<String>()
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard line.count > 20,
                  let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  (obj["type"] as? String) == "assistant",
                  let msg = obj["message"] as? [String: Any],
                  let usage = msg["usage"] as? [String: Any] else { continue }
            if let id = msg["id"] as? String {
                if !seen.insert(id).inserted { continue }
            }
            let model = (msg["model"] as? String) ?? "unknown"
            guard model != "<synthetic>" else { continue }
            guard let ts = obj["timestamp"] as? String, ts.count >= 10 else { continue }
            let day = String(ts.prefix(10))       // ISO8601 UTC; day boundary is close enough for a chart

            var b = out[day]?[model] ?? Bucket()
            b.requests += 1
            b.input += int(usage["input_tokens"])
            b.output += int(usage["output_tokens"])
            b.cacheRead += int(usage["cache_read_input_tokens"])
            b.cacheWrite += int(usage["cache_creation_input_tokens"])
            if let tool = usage["server_tool_use"] as? [String: Any] {
                b.searches += int(tool["web_search_requests"])
            }
            out[day, default: [:]][model] = b
        }
        return out
    }

    static func int(_ any: Any?) -> Int {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let n = any as? NSNumber { return n.intValue }
        return 0
    }

    static func jsonlFiles(under root: URL) throws -> [URL] {
        var out: [URL] = []
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for dir in dirs {
            let inner = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            out.append(contentsOf: inner.filter { $0.pathExtension == "jsonl" })
        }
        return out
    }
}

/// Per-file aggregate cache. Re-parsing 190 MB of transcripts every refresh is wasteful;
/// a file is only re-read when its size or mtime moved.
struct FileCache: Codable {
    struct Entry: Codable { var mtime: Double; var size: Int; var days: [String: [String: ClaudeCodeProvider.Bucket]] }
    var version = 1
    var files: [String: Entry] = [:]

    static func load(from url: URL) -> FileCache {
        guard let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(FileCache.self, from: data),
              cache.version == 1 else { return FileCache() }
        return cache
    }

    func save(to url: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
