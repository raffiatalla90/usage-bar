import Foundation
import SQLite3

/// Reads assistant messages out of OpenCode's SQLite store.
///
/// Schema actually observed on this machine (verified, not assumed):
///   message(id TEXT PK, session_id TEXT, time_created INTEGER ms, time_updated INTEGER, data TEXT JSON)
///   data JSON for assistant turns: role, providerID, modelID, cost, tokens{input,output,reasoning,cache{read,write}}, error?
///
/// No cache file: the whole store is 8k rows and the query is indexed on time_created,
/// so rescanning the range window on each refresh costs ~50 ms. A cache that only
/// rescanned two days silently dropped everything older — that was a real bug.
public struct OpenCodeProvider: Sendable {
    public struct Config: Sendable {
        public var databaseURL: URL
        /// Provider IDs considered "Kenari". Model IDs prefixed `kenari/` always count,
        /// because OpenCode routes Kenari through the local 9router gateway
        /// (providerID `9router`, modelID `kenari/deepseek-v4-1-flash`).
        public var kenariProviderIDs: Set<String>
        public init(databaseURL: URL, kenariProviderIDs: Set<String> = ["kenari"]) {
            self.databaseURL = databaseURL
            self.kenariProviderIDs = kenariProviderIDs
        }
    }

    public init(config: Config) { self.config = config }
    public let config: Config

    public static var defaultConfig: Config {
        Config(databaseURL: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/opencode.db"))
    }

    // MARK: - Public API

    public func report(range: TimeRange, now: Date = Date()) throws -> UsageReport {
        guard FileManager.default.fileExists(atPath: config.databaseURL.path) else {
            throw ProviderError.unavailable("opencode.db not found at \(config.databaseURL.path)")
        }
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        let daysBack = range == .last30 ? 29 : (range == .yesterday ? 1 : 0)
        let windowStart = calendar.date(byAdding: .day, value: -daysBack, to: startOfToday) ?? startOfToday
        let fromMs = Int64(windowStart.timeIntervalSince1970 * 1000)

        let rows = try Self.queryMessages(dbPath: config.databaseURL.path, fromMs: fromMs)

        var perModel: [String: Bucket] = [:]
        var daily: [String: DailyAccum] = [:]
        for row in rows {
            guard let key = Self.kenariBucketKey(data: row.data, kenariProviderIDs: config.kenariProviderIDs),
                  let b = Self.bucket(from: row.data), b.requests > 0 else { continue }
            perModel[key, default: Bucket()].add(b)
            let day = Self.dayFormatter.string(from: Date(timeIntervalSince1970: Double(row.timeMs) / 1000))
            var acc = daily[day] ?? DailyAccum()
            acc.requests += b.requests
            acc.tokens += b.input + b.output
            daily[day] = acc
        }

        var totals = UsageTotals()
        totals.costMicroIDR = 0
        var models: [ModelUsage] = []
        for (key, b) in perModel {
            let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
            let provider = parts.count == 2 ? parts[0] : "kenari"
            let model = parts.count == 2 ? parts[1] : key
            models.append(ModelUsage(provider: provider, model: model, requests: b.requests,
                                     inputTokens: b.input, outputTokens: b.output,
                                     cacheReadTokens: b.cacheRead, cacheWriteTokens: b.cacheWrite,
                                     costMicroIDR: b.costMicroIDR))
            totals.requests += b.requests
            totals.inputTokens += b.input
            totals.outputTokens += b.output
            totals.cacheReadTokens += b.cacheRead
            totals.cacheWriteTokens += b.cacheWrite
        }
        models.sort { $0.totalTokens > $1.totalTokens }

        let anchor = range == .yesterday ? (calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday) : startOfToday
        let count = range == .last30 ? 30 : 1
        var points: [DailyPoint] = []
        for i in stride(from: count - 1, through: 0, by: -1) {
            guard let d = calendar.date(byAdding: .day, value: -i, to: anchor) else { continue }
            let acc = daily[Self.dayFormatter.string(from: d)] ?? DailyAccum()
            points.append(DailyPoint(date: d, requests: acc.requests, costMicroIDR: 0, tokens: acc.tokens))
        }

        return UsageReport(range: range, totals: totals, models: models, daily: points,
                           source: .opencodeLocal, fetchedAt: Date())
    }

    // MARK: - Buckets

    struct Bucket: Codable {
        var requests = 0
        var input = 0
        var output = 0
        var cacheRead = 0
        var cacheWrite = 0
        var costMicroIDR: Int?
        mutating func add(_ o: Bucket) {
            requests += o.requests; input += o.input; output += o.output
            cacheRead += o.cacheRead; cacheWrite += o.cacheWrite
            if let c = o.costMicroIDR { costMicroIDR = (costMicroIDR ?? 0) + c }
        }
    }

    struct DailyAccum { var requests = 0; var tokens = 0 }

    // MARK: - JSON row parsing

    /// Returns "provider/model" when the row belongs to Kenari, else nil.
    static func kenariBucketKey(data: Data, kenariProviderIDs: Set<String>) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard (obj["role"] as? String) == "assistant" else { return nil }
        let provider = (obj["providerID"] as? String) ?? ""
        let model = (obj["modelID"] as? String) ?? ""
        let isKenari = kenariProviderIDs.contains(provider) || model.hasPrefix("kenari/")
        guard isKenari, !model.isEmpty else { return nil }
        return "\(provider.isEmpty ? "kenari" : provider)/\(model)"
    }

    static func bucket(from data: Data) -> Bucket? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let tokens = obj["tokens"] as? [String: Any] ?? [:]
        var b = Bucket()
        b.input = intValue(tokens["input"])
        b.output = intValue(tokens["output"])
        if let cache = tokens["cache"] as? [String: Any] {
            b.cacheRead = intValue(cache["read"])
            b.cacheWrite = intValue(cache["write"])
        }
        // An errored turn reports no usage; skip it rather than counting a phantom request.
        if obj["error"] != nil, b.input == 0, b.output == 0 { return nil }
        // OpenCode records cost in USD and leaves it 0 when the provider reports nothing.
        // We do not convert: no FX rate is trustworthy offline, so local cost stays nil ("—").
        // ponytail: add USD→IDR only if OpenCode starts reporting non-zero cost for Kenari.
        b.costMicroIDR = nil
        b.requests = 1
        return b
    }

    static func intValue(_ any: Any?) -> Int {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let n = any as? NSNumber { return n.intValue }
        return 0
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.calendar = Calendar.current
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    // MARK: - SQLite

    struct Row { let timeMs: Int64; let data: Data }

    static func queryMessages(dbPath: String, fromMs: Int64, limit: Int = 200_000) throws -> [Row] {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(dbPath, &handle, flags, nil) == SQLITE_OK, let db = handle else {
            throw ProviderError.unavailable("cannot open opencode.db (read-only)")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2_000)

        var stmt: OpaquePointer?
        let sql = "SELECT time_created, data FROM message WHERE time_created >= ? ORDER BY time_created"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ProviderError.unavailable("opencode.db schema changed: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, fromMs)

        var rows: [Row] = []
        rows.reserveCapacity(4096)
        while sqlite3_step(stmt) == SQLITE_ROW {
            let ms = sqlite3_column_int64(stmt, 0)
            guard let cstr = sqlite3_column_text(stmt, 1) else { continue }
            let len = Int(sqlite3_column_bytes(stmt, 1))
            rows.append(Row(timeMs: ms, data: Data(bytes: cstr, count: len)))
            if rows.count >= limit { break }
        }
        return rows
    }
}

public enum ProviderError: LocalizedError {
    case unavailable(String)
    case http(Int, String)
    case badPayload(String)
    public var errorDescription: String? {
        switch self {
        case .unavailable(let m): return m
        case .http(let code, let m): return "HTTP \(code): \(m)"
        case .badPayload(let m): return "unexpected payload: \(m)"
        }
    }
}
