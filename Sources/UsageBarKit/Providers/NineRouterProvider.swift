import Foundation
import SQLite3

/// Local source for "OpenCode usage that was billed by Kenari".
///
/// OpenCode reaches Kenari through the local 9router gateway (`http://127.0.0.1:20128/v1`),
/// so in `opencode.db` the provider is `9router` and the model is an opaque combo name
/// (`gratisan`). The upstream provider is only recorded by 9router itself, in
/// `~/.9router/db/data.sqlite`:
///   usageHistory(id, timestamp TEXT ISO8601, provider, model, connectionId, apiKey, endpoint,
///                promptTokens, completionTokens, cost, status, tokens JSON, meta JSON)
///   providerNodes(id, type, name, data JSON)   data.baseUrl tells us which node is Kenari
///
/// Cost is deliberately nil: 9router stores its own USD estimate against a pricing catalog,
/// which is not what Kenari bills. The Kenari API stays the money authority.
public struct NineRouterProvider: Sendable {
    public struct Config: Sendable {
        public var databaseURL: URL
        /// Substring matched against the provider node's baseUrl to identify Kenari.
        public var kenariHost: String
        public init(databaseURL: URL, kenariHost: String = "kenari.id") {
            self.databaseURL = databaseURL
            self.kenariHost = kenariHost
        }
    }

    public init(config: Config) { self.config = config }
    public let config: Config

    public static var defaultConfig: Config {
        Config(databaseURL: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".9router/db/data.sqlite"))
    }

    public func report(range: TimeRange, now: Date = Date()) throws -> UsageReport {
        guard FileManager.default.fileExists(atPath: config.databaseURL.path) else {
            throw ProviderError.unavailable("9router db not found at \(config.databaseURL.path)")
        }
        let (start, end) = range.window(now: now)
        // timestamp is stored as ISO8601 UTC with milliseconds: 2026-10-18T03:47:51.174Z.
        // `window` returns whole seconds, so nudge the upper bound to the end of that second —
        // otherwise rows written in the current second (the common case for "today") drop out.
        let startISO = Self.isoFormatter.string(from: Date(timeIntervalSince1970: Double(start)))
        let endISO = Self.isoFormatter.string(from: Date(timeIntervalSince1970: Double(end) + 0.999))
        let rows = try Self.queryUsage(dbPath: config.databaseURL.path, fromISO: startISO, toISO: endISO, kenariHost: config.kenariHost)
        guard !rows.isEmpty || Self.kenariNodeExists(dbPath: config.databaseURL.path, host: config.kenariHost) else {
            throw ProviderError.unavailable("no Kenari provider node in 9router")
        }

        var perModel: [String: Bucket] = [:]
        var daily: [String: DailyAccum] = [:]
        for r in rows {
            var b = perModel["9router/\(r.model)"] ?? Bucket()
            b.requests += 1
            b.input += r.prompt
            b.output += r.completion
            perModel["9router/\(r.model)"] = b
            let day = Self.dayFormatter.string(from: r.timestamp)
            var acc = daily[day] ?? DailyAccum()
            acc.requests += 1
            acc.tokens += r.prompt + r.completion
            daily[day] = acc
        }

        var totals = UsageTotals()
        totals.costMicroIDR = nil
        var models: [ModelUsage] = []
        for (key, b) in perModel {
            let model = String(key.dropFirst("9router/".count))
            models.append(ModelUsage(provider: "9router", model: model, requests: b.requests,
                                     inputTokens: b.input, outputTokens: b.output,
                                     costMicroIDR: nil))
            totals.requests += b.requests
            totals.inputTokens += b.input
            totals.outputTokens += b.output
        }
        models.sort { $0.totalTokens > $1.totalTokens }

        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: now)
        let anchor = range == .yesterday ? (cal.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday) : startOfToday
        let count = range == .last30 ? 30 : 1
        var points: [DailyPoint] = []
        for i in stride(from: count - 1, through: 0, by: -1) {
            guard let d = cal.date(byAdding: .day, value: -i, to: anchor) else { continue }
            let acc = daily[Self.dayFormatter.string(from: d)] ?? DailyAccum()
            points.append(DailyPoint(date: d, requests: acc.requests, costMicroIDR: 0, tokens: acc.tokens))
        }

        return UsageReport(range: range, totals: totals, models: models, daily: points,
                           source: .routerLocal, fetchedAt: Date())
    }

    // MARK: - Helpers

    struct Bucket { var requests = 0; var input = 0; var output = 0 }
    struct DailyAccum { var requests = 0; var tokens = 0 }
    struct UsageRow { let timestamp: Date; let model: String; let prompt: Int; let completion: Int }

    static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.calendar = Calendar.current
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Provider node ids in 9router whose baseUrl points at Kenari.
    static func kenariNodeIDs(db: OpaquePointer, host: String) -> [String] {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT id, data FROM providerNodes", -1, &stmt, nil) == SQLITE_OK else { return [] }
        var ids: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idC = sqlite3_column_text(stmt, 0), let dataC = sqlite3_column_text(stmt, 1) else { continue }
            let id = String(cString: idC)
            let data = String(cString: dataC)
            if data.contains(host) { ids.append(id) }
        }
        return ids
    }

    static func kenariNodeExists(dbPath: String, host: String) -> Bool {
        openReadOnly(dbPath).map { kenariNodeIDs(db: $0, host: host).isEmpty == false } ?? false
    }

    static func openReadOnly(_ path: String) -> OpaquePointer? {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(handle); return nil
        }
        sqlite3_busy_timeout(handle, 2_000)
        return handle
    }

    static func queryUsage(dbPath: String, fromISO: String, toISO: String, kenariHost: String) throws -> [UsageRow] {
        guard let db = openReadOnly(dbPath) else {
            throw ProviderError.unavailable("cannot open 9router db (read-only)")
        }
        defer { sqlite3_close(db) }

        let ids = kenariNodeIDs(db: db, host: kenariHost)
        guard !ids.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let sql = """
            SELECT timestamp, model, promptTokens, completionTokens
            FROM usageHistory
            WHERE timestamp >= ? AND timestamp <= ? AND provider IN (\(placeholders))
            ORDER BY timestamp
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ProviderError.unavailable("9router schema changed: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, fromISO, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, toISO, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        for (i, id) in ids.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 3), id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }

        var rows: [UsageRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let tsC = sqlite3_column_text(stmt, 0), let modelC = sqlite3_column_text(stmt, 1) else { continue }
            let ts = String(cString: tsC)
            guard let date = isoFormatter.date(from: ts) else { continue }
            rows.append(UsageRow(timestamp: date,
                                 model: String(cString: modelC),
                                 prompt: Int(sqlite3_column_int64(stmt, 2)),
                                 completion: Int(sqlite3_column_int64(stmt, 3))))
        }
        return rows
    }
}
