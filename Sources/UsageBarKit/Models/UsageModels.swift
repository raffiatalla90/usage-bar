import Foundation

public enum TimeRange: String, CaseIterable, Identifiable, Sendable {
    case today, yesterday, last30
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .last30: return "30 Days"
        }
    }

    /// Window in unix seconds, local-midnight aligned (Kenari accepts explicit start/end).
    public func window(now: Date = Date(), calendar: Calendar = .current) -> (start: Int, end: Int) {
        let startOfToday = calendar.startOfDay(for: now)
        switch self {
        case .today:
            return (Int(startOfToday.timeIntervalSince1970), Int(now.timeIntervalSince1970))
        case .yesterday:
            let start = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
            return (Int(start.timeIntervalSince1970), Int(startOfToday.timeIntervalSince1970) - 1)
        case .last30:
            let start = calendar.date(byAdding: .day, value: -29, to: startOfToday) ?? startOfToday
            return (Int(start.timeIntervalSince1970), Int(now.timeIntervalSince1970))
        }
    }
    /// Day keys (yyyy-MM-dd, local) covered by this range. Used to trim server responses,
    /// which are inclusive on both ends and can spill a day at the boundary.
    public func dayKeys(now: Date = Date(), calendar: Calendar = .current) -> Set<String> {
        let startOfToday = calendar.startOfDay(for: now)
        switch self {
        case .today:
            return [DayKey.string(startOfToday)]
        case .yesterday:
            let y = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
            return [DayKey.string(y)]
        case .last30:
            return Set((0..<30).compactMap { i in
                calendar.date(byAdding: .day, value: -i, to: startOfToday).map(DayKey.string)
            })
        }
    }
}

public enum DayKey {
    public static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.calendar = Calendar.current
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    public static func string(_ d: Date) -> String { formatter.string(from: d) }
}

public struct ModelUsage: Identifiable, Hashable, Sendable {
    public var provider: String
    public var model: String
    public var requests: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int
    /// micro-Rupiah. nil = not reported by the source (local OpenCode has no price data).
    public var costMicroIDR: Int?

    public var id: String { "\(provider)/\(model)" }
    /// Models are recorded as `provider/model`; the provider is already shown on the card,
    /// so the legend only needs the model id to stay readable.
    public var displayName: String {
        guard let slash = model.firstIndex(of: "/") else { return model }
        return String(model[model.index(after: slash)...])
    }
    public var totalTokens: Int { inputTokens + outputTokens }

    public init(provider: String, model: String, requests: Int = 0,
                inputTokens: Int = 0, outputTokens: Int = 0,
                cacheReadTokens: Int = 0, cacheWriteTokens: Int = 0,
                costMicroIDR: Int? = nil) {
        self.provider = provider
        self.model = model
        self.requests = requests
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.costMicroIDR = costMicroIDR
    }
}

public struct DailyPoint: Identifiable, Hashable, Sendable {
    public var date: Date
    public var requests: Int
    public var costMicroIDR: Int
    public var tokens: Int
    public var id: Date { date }
    public init(date: Date, requests: Int = 0, costMicroIDR: Int = 0, tokens: Int = 0) {
        self.date = date; self.requests = requests; self.costMicroIDR = costMicroIDR; self.tokens = tokens
    }
}

public struct UsageTotals: Hashable, Sendable {
    public var requests: Int = 0
    public var inputTokens: Int = 0
    public var outputTokens: Int = 0
    public var cacheReadTokens: Int = 0
    public var cacheWriteTokens: Int = 0
    public var costMicroIDR: Int? = 0

    public var totalTokens: Int { inputTokens + outputTokens }
    public init() {}
}

public enum UsageSource: String, Sendable {
    case kenariRemote, opencodeLocal, routerLocal, claudeLocal
    public var label: String {
        switch self {
        case .kenariRemote: return "Kenari API"
        case .opencodeLocal: return "OpenCode local"
        case .routerLocal: return "9router local"
        case .claudeLocal: return "Claude Code local"
        }
    }
}

// MARK: - Quota cards

/// One quota line on a provider card: what it is, how much is left, when it refills.
public struct QuotaRow: Hashable, Sendable, Identifiable {
    public var title: String
    public var valueText: String
    public var detail: String
    /// 0...1 of the budget still available. Drives the bar length.
    public var remaining: Double
    public var id: String { title }

    public init(title: String, valueText: String, detail: String, remaining: Double) {
        self.title = title; self.valueText = valueText
        self.detail = detail; self.remaining = min(1, max(0, remaining))
    }
}

/// A provider block in the popover. `rows` may be empty when the source is unreachable —
/// `note` then carries the reason instead of the numbers.
public struct ProviderQuota: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var subtitle: String
    public var symbol: String
    public var rows: [QuotaRow]
    public var note: String?
    public var footnote: String?

    public init(id: String, name: String, subtitle: String, symbol: String,
                rows: [QuotaRow] = [], note: String? = nil, footnote: String? = nil) {
        self.id = id; self.name = name; self.subtitle = subtitle; self.symbol = symbol
        self.rows = rows; self.note = note; self.footnote = footnote
    }
}

/// "5 hari 11 jam", "28 hari 11 jam", "12 jam 38 menit" — Indonesian, coarse on purpose.
public enum Duration {
    public static func id(_ seconds: Int) -> String {
        guard seconds > 0 else { return "sebentar lagi" }
        let d = seconds / 86_400, h = (seconds % 86_400) / 3_600, m = (seconds % 3_600) / 60
        if d > 0 { return h > 0 ? "\(d) hari \(h) jam" : "\(d) hari" }
        if h > 0 { return m > 0 ? "\(h) jam \(m) menit" : "\(h) jam" }
        return "\(max(1, m)) menit"
    }
}

public struct UsageReport: Sendable {
    public var range: TimeRange
    public var totals: UsageTotals
    public var models: [ModelUsage]
    public var daily: [DailyPoint]
    public var source: UsageSource
    public var fetchedAt: Date

    public init(range: TimeRange, totals: UsageTotals, models: [ModelUsage],
                daily: [DailyPoint], source: UsageSource, fetchedAt: Date = Date()) {
        self.range = range; self.totals = totals; self.models = models
        self.daily = daily; self.source = source; self.fetchedAt = fetchedAt
    }
}

/// Optional account info. Both endpoints 403 on restricted keys — treated as "unavailable", not an error.
public struct AccountInfo: Hashable, Sendable {
    public var balanceMicroIDR: Int?
    public var reservedMicroIDR: Int?
    public var availableMicroIDR: Int?
    public var planName: String?
    public var quotaNote: String?

    /// Plan windows, straight from GET /v1/account/quota:
    /// `plan.windows.week = {budget_rp, remaining_rp, used_frac, resets_at}`.
    public var weeklyRemaining: Double?
    public var weeklyResetsAt: Date?
    public var monthlyRemaining: Double?
    public var monthlyResetsAt: Date?
    /// Web search allowance from the plan catalog (GET /api/plans → `web_search_daily`).
    public var webSearchLimit: Int?
    public var webSearchUsed: Int?
    /// What PAYG actually billed today (GET /v1/usage?range=today, `billing_kind: payg`).
    public var paygCostTodayMicroIDR: Int?

    public init(balanceMicroIDR: Int? = nil, reservedMicroIDR: Int? = nil,
                availableMicroIDR: Int? = nil, planName: String? = nil, quotaNote: String? = nil,
                weeklyRemaining: Double? = nil, weeklyResetsAt: Date? = nil,
                monthlyRemaining: Double? = nil, monthlyResetsAt: Date? = nil,
                webSearchLimit: Int? = nil, webSearchUsed: Int? = nil,
                paygCostTodayMicroIDR: Int? = nil) {
        self.balanceMicroIDR = balanceMicroIDR
        self.reservedMicroIDR = reservedMicroIDR
        self.availableMicroIDR = availableMicroIDR
        self.planName = planName
        self.quotaNote = quotaNote
        self.weeklyRemaining = weeklyRemaining
        self.weeklyResetsAt = weeklyResetsAt
        self.monthlyRemaining = monthlyRemaining
        self.monthlyResetsAt = monthlyResetsAt
        self.webSearchLimit = webSearchLimit
        self.webSearchUsed = webSearchUsed
        self.paygCostTodayMicroIDR = paygCostTodayMicroIDR
    }
}

public enum ProviderHealth: Equatable, Sendable {
    case unknown          // belum pernah dicek
    case live             // terhubung, angka segar
    case stale(String)    // terhubung tapi angka lama / cadangan
    case down(String)     // tidak bisa dibaca

    public var isDown: Bool { if case .down = self { return true }; return false }
    public var isLive: Bool { if case .live = self { return true }; return false }

    /// Short label for a badge; nil when there is nothing worth flagging.
    public var badge: String? {
        switch self {
        case .unknown: return nil
        case .live: return nil
        case .stale(let reason): return reason.isEmpty ? "data lama" : "data lama · \(reason)"
        case .down(let reason): return reason.isEmpty ? "tidak aktif" : reason
        }
    }
}

public enum ConnectionState: Equatable, Sendable {
    case unknown, ok, degraded(String), failed(String)
    public var isOK: Bool { if case .ok = self { return true }; return false }
    public var message: String {
        switch self {
        case .unknown: return "Checking…"
        case .ok: return "Connected"
        case .degraded(let m): return "Partial: \(m)"
        case .failed(let m): return "Offline: \(m)"
        }
    }
}

public enum Money {
    /// micro-Rupiah -> "Rp 12.345" / "Rp 0,5". Integer math: no float rounding surprises.
    public static func idr(micro: Int?) -> String {
        guard let micro else { return "—" }
        let sign = micro < 0 ? "-" : ""
        let absMicro = abs(micro)
        let whole = absMicro / 1_000_000
        var frac = (absMicro % 1_000_000) / 10_000        // 2 decimals, truncated
        if frac % 10 == 0 { frac /= 10 }                  // 0,50 -> 0,5
        var wholeText = String(whole)
        if whole >= 1_000 {
            var groups: [String] = []
            var n = whole
            while n > 0 { groups.insert(String(format: "%03d", n % 1_000), at: 0); n /= 1_000 }
            wholeText = groups.joined(separator: ".")
            if let dot = wholeText.firstIndex(of: ".") {          // "012.345" -> "12.345"
                wholeText = String(Int(wholeText[..<dot]) ?? 0) + wholeText[dot...]
            }
        }
        return "\(sign)Rp " + wholeText + (frac == 0 ? "" : ",\(frac)")
    }

    public static func tokens(_ n: Int) -> String {
        switch n {
        case ..<1_000: return "\(n)"
        case ..<1_000_000: return String(format: "%.1fK", Double(n) / 1_000)
        case ..<1_000_000_000: return String(format: "%.1fM", Double(n) / 1_000_000)
        default: return String(format: "%.2fB", Double(n) / 1_000_000_000)
        }
    }
}
