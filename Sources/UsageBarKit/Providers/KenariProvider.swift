import Foundation

/// Remote provider: the official Kenari usage endpoints.
/// Verified against https://kenari.id/docs/usage on 2026-10-18:
///   GET /v1/usage?start=&end=      -> { object:"usage.summary", data:[{model,billing_kind,requests,prompt_tokens,completion_tokens,cached_prompt_tokens,cache_write_prompt_tokens,cost_micro_idr,catalog_micro_idr}], total:{...} }
///   GET /v1/usage/daily?start=&end= -> { object:"usage.daily", data:[{date,requests,cost_micro_idr}] }
///   GET /v1/account/balance         -> 403 restricted_key_not_allowed for restricted keys
///   GET /v1/account/quota           -> 403 restricted_key_not_allowed for restricted keys
/// All money values are micro-Rupiah (Rp 1 = 1_000_000).
public struct KenariProvider: Sendable {
    public struct Config: Sendable {
        public var baseURL: URL
        public var apiKey: String
        /// Key used for `/account/quota` and `/account/balance`. Those endpoints reject
        /// restricted tool keys (`restricted_key_not_allowed`); the `kenari login` key works.
        public var accountKey: String?
        public var timeout: TimeInterval
        public init(baseURL: URL = URL(string: "https://kenari.id/v1")!, apiKey: String,
                    accountKey: String? = nil, timeout: TimeInterval = 20) {
            self.baseURL = baseURL; self.apiKey = apiKey
            self.accountKey = accountKey ?? apiKey
            self.timeout = timeout
        }
    }

    public init(config: Config) { self.config = config }
    public let config: Config

    public struct Result: Sendable {
        public var report: UsageReport
        public var account: AccountInfo
        public init(report: UsageReport, account: AccountInfo) {
            self.report = report; self.account = account
        }
    }

    public func fetch(range: TimeRange, now: Date = Date()) async throws -> Result {
        let (start, end) = range.window(now: now)
        async let summary = getJSON(path: "/usage", query: [.init(name: "start", value: "\(start)"), .init(name: "end", value: "\(end)")])
        async let daily = getJSON(path: "/usage/daily", query: [.init(name: "start", value: "\(start)"), .init(name: "end", value: "\(end)")])

        let summaryJSON = try await summary
        let dailyJSON = try await daily

        var models: [ModelUsage] = []
        var totals = UsageTotals()
        totals.costMicroIDR = 0
        var paygMicro = 0

        for row in (summaryJSON["data"] as? [[String: Any]]) ?? [] {
            let model = (row["model"] as? String) ?? "unknown"
            let requests = intValue(row["requests"])
            let inTok = intValue(row["prompt_tokens"])
            let outTok = intValue(row["completion_tokens"])
            let cacheRead = intValue(row["cached_prompt_tokens"])
            let cacheWrite = intValue(row["cache_write_prompt_tokens"])
            let cost = intValue(row["cost_micro_idr"])
            if (row["billing_kind"] as? String) == "payg" { paygMicro += cost }
            models.append(ModelUsage(provider: "kenari", model: model, requests: requests,
                                     inputTokens: inTok, outputTokens: outTok,
                                     cacheReadTokens: cacheRead, cacheWriteTokens: cacheWrite,
                                     costMicroIDR: cost))
        }
        models.sort { $0.totalTokens > $1.totalTokens }

        if let total = summaryJSON["total"] as? [String: Any] {
            totals.requests = intValue(total["requests"])
            totals.inputTokens = intValue(total["prompt_tokens"])
            totals.outputTokens = intValue(total["completion_tokens"])
            totals.cacheReadTokens = intValue(total["cached_prompt_tokens"])
            totals.cacheWriteTokens = intValue(total["cache_write_prompt_tokens"])
            totals.costMicroIDR = intValue(total["cost_micro_idr"])
        } else {
            totals.requests = models.reduce(0) { $0 + $1.requests }
            totals.inputTokens = models.reduce(0) { $0 + $1.inputTokens }
            totals.outputTokens = models.reduce(0) { $0 + $1.outputTokens }
            totals.cacheReadTokens = models.reduce(0) { $0 + $1.cacheReadTokens }
            totals.cacheWriteTokens = models.reduce(0) { $0 + $1.cacheWriteTokens }
            totals.costMicroIDR = models.reduce(0) { $0 + ($1.costMicroIDR ?? 0) }
        }

        let dayFmt = DayKey.formatter
        let allowed = range.dayKeys(now: now)
        var points: [DailyPoint] = []
        for row in (dailyJSON["data"] as? [[String: Any]]) ?? [] {
            guard let ds = row["date"] as? String, let d = dayFmt.date(from: ds) else { continue }
            guard allowed.contains(ds) else { continue }   // server is inclusive on both ends
            points.append(DailyPoint(date: d, requests: intValue(row["requests"]),
                                     costMicroIDR: intValue(row["cost_micro_idr"]), tokens: 0))
        }
        points.sort { $0.date < $1.date }
        // zero-fill so the chart always shows the whole window
        let byDay = Dictionary(uniqueKeysWithValues: points.map { (DayKey.string($0.date), $0) })
        let startOfToday = Calendar.current.startOfDay(for: now)
        let days = range == .last30 ? 30 : 1
        let anchor = range == .yesterday
            ? (Calendar.current.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday)
            : startOfToday
        points = stride(from: days - 1, through: 0, by: -1).compactMap { i in
            guard let d = Calendar.current.date(byAdding: .day, value: -i, to: anchor) else { return nil }
            return byDay[DayKey.string(d)] ?? DailyPoint(date: d)
        }

        let report = UsageReport(range: range, totals: totals, models: models, daily: points,
                                 source: .kenariRemote, fetchedAt: Date())

        // Account info is optional: restricted keys legitimately get 403 here.
        var account = AccountInfo()
        if let balance = try? await getJSON(path: "/account/balance", query: [], useAccountKey: true) {
            account.balanceMicroIDR = intValue(balance["balance_micro_idr"])
            account.reservedMicroIDR = intValue(balance["reserved_micro_idr"])
            account.availableMicroIDR = intValue(balance["available_micro_idr"])
        }
        if let quota = try? await getJSON(path: "/account/quota", query: [], useAccountKey: true),
           let plan = quota["plan"] as? [String: Any] {
            account.planName = plan["name"] as? String
            let windows = plan["windows"] as? [String: Any] ?? [:]
            func window(_ key: String) -> (Double, Date)? {
                guard let w = windows[key] as? [String: Any] else { return nil }
                let used = (w["used_frac"] as? NSNumber)?.doubleValue ?? 0
                let resets = (w["resets_at"] as? String).flatMap(Self.isoParser.date(from:))
                return (min(1, max(0, 1 - used)), resets ?? Date())
            }
            if let w = window("week") { account.weeklyRemaining = w.0; account.weeklyResetsAt = w.1 }
            if let w = window("month") { account.monthlyRemaining = w.0; account.monthlyResetsAt = w.1 }
        }

        // Web search: the plan catalog publishes the daily allowance; the usage summary counts
        // what was spent today under the synthetic `web_search` model. `/api/plans` lives on the
        // site root, not under /v1, and needs no auth.
        account.webSearchUsed = models.first { $0.model == "web_search" }?.requests
        if let plans = try? await Self.plansCatalog(), let name = account.planName,
           let plan = plans.first(where: { ($0["name"] as? String) == name }) {
            account.webSearchLimit = intValue(plan["web_search_daily"])
        }
        if range == .today { account.paygCostTodayMicroIDR = paygMicro }

        return Result(report: report, account: account)
    }

    /// Public plan catalog: https://kenari.id/api/plans -> [{name, web_search_daily, budget_week_micro_idr, …}]
    static func plansCatalog() async throws -> [[String: Any]] {
        guard let url = URL(string: "https://kenari.id/api/plans") else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: req)
        guard ((response as? HTTPURLResponse)?.statusCode ?? 0) == 200,
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr
    }

    static let isoParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    struct QueryItem { let name: String; let value: String }

    func getJSON(path: String, query: [QueryItem], useAccountKey: Bool = false) async throws -> [String: Any] {
        guard let obj = try await getAny(path: path, query: query, useAccountKey: useAccountKey) as? [String: Any] else {
            throw ProviderError.badPayload("not a JSON object")
        }
        return obj
    }

    /// Some endpoints (`/plans`) return a bare array.
    func getJSONArray(path: String, query: [QueryItem]) async throws -> [[String: Any]] {
        guard let arr = try await getAny(path: path, query: query) as? [[String: Any]] else {
            throw ProviderError.badPayload("not a JSON array")
        }
        return arr
    }

    func getAny(path: String, query: [QueryItem], useAccountKey: Bool = false) async throws -> Any {
        var comps = URLComponents(url: config.baseURL.appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path),
                                  resolvingAgainstBaseURL: false)
        if !query.isEmpty {
            comps?.queryItems = query.map { URLQueryItem(name: $0.name, value: $0.value) }
        }
        guard let url = comps?.url else { throw ProviderError.unavailable("bad URL for \(path)") }

        var req = URLRequest(url: url)
        req.timeoutInterval = config.timeout
        let key = useAccountKey ? (config.accountKey ?? config.apiKey) : config.apiKey
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let body = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            throw ProviderError.http(code, String(body))
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) else {
            throw ProviderError.badPayload("not JSON")
        }
        if let dict = obj as? [String: Any], let err = dict["error"] as? [String: Any] {
            throw ProviderError.badPayload((err["message"] as? String) ?? "error object")
        }
        return obj
    }

    func intValue(_ any: Any?) -> Int {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let n = any as? NSNumber { return n.intValue }
        return 0
    }
}
