import Foundation
import Security

/// Claude subscription limits (5-hour session window + 7-day window).
///
/// Source: `GET https://api.anthropic.com/api/oauth/usage`, authenticated with the OAuth
/// access token Claude Code stores for this machine. The endpoint is the one `claude /usage`
/// renders; it needs the `anthropic-beta: oauth-2025-04-20` header.
///
/// Credential lookup order: macOS Keychain item `Claude Code-credentials` first, then
/// `~/.claude/.credentials.json`. On macOS the Keychain is authoritative — the JSON file is a
/// legacy copy that stops being written once the CLI switches to Keychain, so reading it alone
/// yields a token that expired days ago.
public struct ClaudeQuotaProvider {
    /// Anthropic rate-limits this endpoint hard, so a 60-second poll burns the budget and the
    /// card blanks. Quota only moves as usage accrues: refresh at most every 5 minutes, and
    /// after a 429 wait 10 minutes before trying again. State lives in UserDefaults so a
    /// restart does not immediately re-hammer the endpoint.
    static let minInterval: TimeInterval = 300
    static let backoffAfter429: TimeInterval = 600
    private static let lastFetchKey = "usagebar.claudeQuota.lastFetch"
    private static let blockedKey = "usagebar.claudeQuota.blockedUntil"

    public struct Config: Sendable {
        public var credentialsURL: URL
        public var usageURL: URL
        public init(credentialsURL: URL, usageURL: URL) {
            self.credentialsURL = credentialsURL
            self.usageURL = usageURL
        }
    }

    public static let defaultConfig = Config(
        credentialsURL: URL(fileURLWithPath: NSHomeDirectory() + "/.claude/.credentials.json"),
        usageURL: URL(string: "https://api.anthropic.com/api/oauth/usage")!)

    private let config: Config
    private let session: URLSession

    public init(config: Config = defaultConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func fetch() async -> ClaudeQuota {
        guard let token = Self.accessToken(credentialsURL: config.credentialsURL) else {
            return ClaudeQuota(windows: Self.localCache(),
                               error: "Token Claude Code tidak ada — jalankan `claude` lalu /login")
        }
        let defaults = UserDefaults.standard
        // Rate-limit gate: serve the last good numbers instead of hammering the endpoint.
        if let blocked = defaults.object(forKey: Self.blockedKey) as? Date, blocked > Date() {
            let mins = max(1, Int(blocked.timeIntervalSinceNow / 60))
            return ClaudeQuota(windows: Self.bestCached(),
                               error: "Batas permintaan Anthropic — coba lagi \(mins) menit")
        }
        if let last = defaults.object(forKey: Self.lastFetchKey) as? Date,
           Date().timeIntervalSince(last) < Self.minInterval,
           !Self.cachedWindows().isEmpty {
            return ClaudeQuota(windows: Self.cachedWindows())
        }

        // 429 is a transient rate limit on Anthropic's side, not a credential problem: back
        // off and retry so a poll that lands during a burst does not blank the card.
        var lastError: ClaudeQuota?
        for delay in [0.0, 3.0, 8.0] {
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            var req = URLRequest(url: config.usageURL, timeoutInterval: 15)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            req.setValue("claude-cli/2.1.299", forHTTPHeaderField: "User-Agent")
            do {
                let (data, resp) = try await session.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 429 {
                    lastError = ClaudeQuota(windows: Self.bestCached(),
                                            error: "Batas permintaan Anthropic — coba lagi 10 menit")
                    continue
                }
                guard code == 200 else {
                    if code == 401 {
                        return ClaudeQuota(windows: Self.localCache(),
                                           error: "Login Claude Code kedaluwarsa — jalankan `claude` lalu /login")
                    }
                    return ClaudeQuota(windows: Self.bestCached(), error: "Claude quota HTTP \(code)")
                }
                let obj = try JSONSerialization.jsonObject(with: data)
                let windows = Self.parse(obj)
                if windows.isEmpty {
                    return ClaudeQuota(windows: Self.localCache(), error: "Kuota Claude tidak terbaca dari respons")
                }
                Self.storeCache(windows)
                defaults.set(Date(), forKey: Self.lastFetchKey)
                return ClaudeQuota(windows: windows)
            } catch {
                return ClaudeQuota(windows: Self.bestCached(), error: "Claude quota: \(error.localizedDescription)")
            }
        }
        defaults.set(Date().addingTimeInterval(Self.backoffAfter429), forKey: Self.blockedKey)
        return lastError ?? ClaudeQuota(windows: Self.bestCached(), error: "Claude quota tidak tersedia")
    }

    // MARK: - Last-known windows

    /// Quota numbers Claude Code itself cached in `~/.claude.json`. The CLI writes this on every
    /// successful usage call, so it stays fresh even when our own request is rate-limited —
    /// this is what keeps the card populated instead of showing two dashes.
    static func localCache(configPath: String = NSHomeDirectory() + "/.claude.json") -> [ClaudeQuota.Window] {
        guard let data = FileManager.default.contents(atPath: configPath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cache = obj["cachedUsageUtilization"] as? [String: Any],
              let usage = (cache["utilization"] as? [String: Any]) ?? (cache["usage"] as? [String: Any])
        else { return [] }
        return parse(usage)
    }

    /// Freshly fetched windows if we have them, else the CLI's cache.
    static func bestCached() -> [ClaudeQuota.Window] {
        let mine = cachedWindows()
        return mine.isEmpty ? localCache() : mine
    }

    /// Numbers from the last successful fetch, so a rate-limited poll still shows the real
    /// quota (a few minutes stale) instead of two dashes.
    static func cachedWindows() -> [ClaudeQuota.Window] {
        guard let raw = UserDefaults.standard.array(forKey: "usagebar.claudeQuota.windows") as? [[String: Any]] else { return [] }
        return raw.compactMap { d in
            guard let label = d["label"] as? String, let rem = d["remaining"] as? Double else { return nil }
            return ClaudeQuota.Window(label: label, remaining: rem,
                                      resetsAt: (d["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) })
        }
    }

    static func storeCache(_ windows: [ClaudeQuota.Window]) {
        let raw: [[String: Any]] = windows.map { w in
            var d: [String: Any] = ["label": w.label, "remaining": w.remaining]
            if let r = w.resetsAt { d["resetsAt"] = r.timeIntervalSince1970 }
            return d
        }
        UserDefaults.standard.set(raw, forKey: "usagebar.claudeQuota.windows")
    }

    // MARK: - Credentials

    public static func accessToken(credentialsURL: URL) -> String? {
        if let t = keychainToken(), !t.isEmpty { return t }
        guard let data = try? Data(contentsOf: credentialsURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let oauth = (obj["claudeAiOauth"] as? [String: Any]) ?? obj
        guard let t = oauth["accessToken"] as? String, !t.isEmpty else { return nil }
        return t
    }

    /// Reads the Keychain item Claude Code writes on macOS. Returns nil on any failure so the
    /// caller can fall back to the JSON file; never prompts (the CLI created the item, so this
    /// process is allowed to read it without an unlock).
    static func keychainToken(service: String = "Claude Code-credentials",
                              account: String = NSUserName()) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let oauth = (obj["claudeAiOauth"] as? [String: Any]) ?? obj
        return oauth["accessToken"] as? String
    }

    // MARK: - Parsing (pure, unit tested)

    /// Turns the usage payload into displayable windows, most specific first.
    public static func parse(_ obj: Any) -> [ClaudeQuota.Window] {
        guard let root = obj as? [String: Any] else { return [] }
        // Some deployments nest the payload.
        let dict = (root["usage"] as? [String: Any]) ?? root

        var windows: [ClaudeQuota.Window] = []
        for (key, value) in dict {
            guard let body = value as? [String: Any] else { continue }
            guard let label = label(forKey: key) else { continue }
            guard let remaining = remainingFraction(body) else { continue }
            windows.append(ClaudeQuota.Window(label: label, remaining: remaining,
                                              resetsAt: resetsAt(body)))
        }
        // Session window first, then weekly, then per-model weekly.
        let order = ["Sesi 5 jam", "Mingguan", "Mingguan Opus", "Mingguan Sonnet"]
        return windows.sorted {
            (order.firstIndex(of: $0.label) ?? 99) < (order.firstIndex(of: $1.label) ?? 99)
        }
    }

    private static func label(forKey key: String) -> String? {
        let k = key.lowercased()
        if k.contains("five_hour") || k.contains("fivehour") || k.contains("5h") || k.contains("session") {
            return "Sesi 5 jam"
        }
        if k.contains("seven_day") || k.contains("sevenday") || k.contains("7d") || k.contains("week") {
            if k.contains("opus") { return "Mingguan Opus" }
            if k.contains("sonnet") { return "Mingguan Sonnet" }
            if k.contains("oauth") { return nil }   // separate bucket for 3rd-party apps
            return "Mingguan"
        }
        return nil
    }

    /// Returns the *remaining* fraction (0...1). Accepts `utilization` (used), or explicit
    /// `remaining`/`left` values, on either a 0...1 or 0...100 scale.
    private static func remainingFraction(_ body: [String: Any]) -> Double? {
        func num(_ keys: [String]) -> Double? {
            for k in keys {
                if let v = body[k] as? Double { return v }
                if let v = body[k] as? Int { return Double(v) }
                if let s = body[k] as? String, let v = Double(s) { return v }
            }
            return nil
        }
        func normalize(_ v: Double) -> Double { v > 1 ? v / 100 : v }

        if let r = num(["remaining", "remaining_percent", "remaining_fraction", "left", "available"]) {
            return min(1, max(0, normalize(r)))
        }
        if let used = num(["utilization", "used", "used_percent", "percent_used", "percent"]) {
            return min(1, max(0, 1 - normalize(used)))
        }
        return nil
    }

    private static func resetsAt(_ body: [String: Any]) -> Date? {
        for k in ["resets_at", "resetsAt", "reset_at", "resetAt"] {
            if let s = body[k] as? String, let d = ISO8601DateFormatter.frac.date(from: s)
                ?? ISO8601DateFormatter.plain.date(from: s) { return d }
            if let t = body[k] as? Double, t > 1_000_000_000 { return Date(timeIntervalSince1970: t) }
            if let t = body[k] as? Int, t > 1_000_000_000 { return Date(timeIntervalSince1970: Double(t)) }
        }
        for k in ["resets_in_seconds", "resetsInSeconds", "ttl_seconds"] {
            if let s = body[k] as? Double { return Date().addingTimeInterval(s) }
            if let s = body[k] as? Int { return Date().addingTimeInterval(Double(s)) }
        }
        return nil
    }
}

public struct ClaudeQuota: Hashable, Sendable {
    public struct Window: Hashable, Sendable {
        public var label: String
        public var remaining: Double
        public var resetsAt: Date?
        public init(label: String, remaining: Double, resetsAt: Date? = nil) {
            self.label = label
            self.remaining = remaining
            self.resetsAt = resetsAt
        }
    }
    public var windows: [Window] = []
    public var error: String?
    public init(windows: [Window] = [], error: String? = nil) {
        self.windows = windows
        self.error = error
    }
}

extension ISO8601DateFormatter {
    static let frac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
