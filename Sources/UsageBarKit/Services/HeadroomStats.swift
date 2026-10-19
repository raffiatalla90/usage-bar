import Foundation

/// Headroom is a local proxy in front of the LLM calls: it strips tokens before they are
/// sent, so "saved" is real money not spent. It has no cloud API — everything lives in
/// `~/.headroom` and on `127.0.0.1:8787/stats`.
///
/// Two sources, on purpose:
///   - `/stats` is live and authoritative, but only answers while the proxy is up.
///   - `proxy_savings.json` is written continuously and survives a dead proxy, so the card
///     keeps showing the last known numbers with a "proxy mati" badge instead of zeros.
///
/// Both carry the same blocks (`lifetime`, `display_session`), so one parser reads both.
public struct HeadroomProject: Sendable, Equatable, Identifiable {
    public var name: String
    public var requests: Int
    public var tokensSaved: Int
    public var savedUSD: Double
    public var savingsPct: Double
    public var lastActivity: Date?
    public var id: String { name }

    public init(name: String, requests: Int = 0, tokensSaved: Int = 0,
                savedUSD: Double = 0, savingsPct: Double = 0, lastActivity: Date? = nil) {
        self.name = name; self.requests = requests; self.tokensSaved = tokensSaved
        self.savedUSD = savedUSD; self.savingsPct = savingsPct; self.lastActivity = lastActivity
    }
}

public struct HeadroomStats: Sendable, Equatable {
    public var reachable = false
    public var mode: String?
    public var port = 8787
    /// Per-project totals, newest activity first. Only `/stats` reports these.
    public var projects: [HeadroomProject] = []

    // lifetime
    public var requests = 0
    public var requestsCompressed = 0
    public var avgCompressionPct = 0.0
    public var tokensRemoved = 0          // compression layer only
    public var toolTokensSaved = 0        // MCP tool-schema trimming
    public var tokensSavedAll = 0         // both layers
    public var tokensBefore = 0
    public var savedUSD = 0.0
    public var savingsPct = 0.0
    public var withoutUSD = 0.0
    public var withUSD = 0.0
    public var co2Grams = 0.0

    // current session (rolls over after 60 min idle)
    public var sessionRequests = 0
    public var sessionTokensSaved = 0
    public var sessionUSD = 0.0
    public var sessionPct = 0.0
    public var sessionStarted: Date?
    public var lastActivity: Date?

    public var error: String?

    public init() {}
    public static let empty = HeadroomStats()

    /// Live if the proxy answered, or if it wrote something in the last hour.
    public var isRunning: Bool {
        if reachable { return true }
        guard let lastActivity else { return false }
        return Date().timeIntervalSince(lastActivity) < 3600
    }
}

public enum Headroom {
    public static let defaultPort = 8787

    private static var dir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".headroom")
    }

    // MARK: live

    /// `/stats` is a large document; only the handful of fields the card needs are read.
    public static func fetch(port: Int = defaultPort, timeout: TimeInterval = 2) async -> HeadroomStats {
        var out = HeadroomStats()
        out.port = port
        guard let url = URL(string: "http://127.0.0.1:\(port)/stats") else { return out }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                out.error = "stats tidak terbaca"
                return cached(port: port, into: out)
            }
            out.reachable = true
            parse(obj, into: &out)
            return out
        } catch {
            out.error = "proxy tidak menjawab"
            return cached(port: port, into: out)
        }
    }

    /// File-only, synchronous. Cheap enough to call on every refresh tick.
    public static func cached(port: Int = defaultPort, into base: HeadroomStats? = nil) -> HeadroomStats {
        var out = base ?? HeadroomStats()
        out.port = port
        let url = dir.appendingPathComponent("proxy_savings.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if out.error == nil { out.error = "belum ada catatan headroom" }
            return out
        }
        parse(obj, into: &out)
        return out
    }

    // MARK: parsing

    /// Testable entry point: one JSON document in, one `HeadroomStats` out.
    public static func parse(data: Data) -> HeadroomStats? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var out = HeadroomStats()
        out.reachable = true
        parse(obj, into: &out)
        return out
    }

    /// Accepts both shapes: the file puts `lifetime` at the top level, `/stats` nests it
    /// under `persistent_savings`. Compression/cost totals only exist in `/stats`.
    private static func parse(_ obj: [String: Any], into out: inout HeadroomStats) {
        let persistent = obj["persistent_savings"] as? [String: Any] ?? obj
        let life = persistent["lifetime"] as? [String: Any] ?? [:]
        let session = persistent["display_session"] as? [String: Any] ?? [:]
        let summary = obj["summary"] as? [String: Any] ?? [:]

        out.mode = summary["mode"] as? String

        // lifetime
        out.requests = int(life["requests"])
        out.tokensRemoved = int(life["tokens_saved"])
        out.toolTokensSaved = int(life["tool_tokens_saved"])
        out.tokensSavedAll = out.tokensRemoved + out.toolTokensSaved
        out.savedUSD = dbl(life["compression_savings_usd"]) + dbl(life["tool_schema_savings_usd"])
        out.tokensBefore = int(life["total_input_tokens"])
        out.withoutUSD = dbl(life["total_input_cost_usd"]) + out.savedUSD
        out.withUSD = dbl(life["total_input_cost_usd"])

        // /stats adds the measured compression ratio and the provider's own cost view.
        if let comp = summary["compression"] as? [String: Any] {
            out.requestsCompressed = int(comp["requests_compressed"])
            out.avgCompressionPct = dbl(comp["avg_compression_pct"])
            let all = int(comp["total_tokens_saved_all_layers"])
            if all > 0 { out.tokensSavedAll = all }
            out.tokensRemoved = int(comp["total_tokens_removed"])
            out.toolTokensSaved = int(comp["tool_schema_tokens_saved"])
            out.tokensBefore = int(comp["total_tokens_before"])
        }
        if let cost = summary["cost"] as? [String: Any] {
            out.withoutUSD = dbl(cost["without_headroom_usd"])
            out.withUSD = dbl(cost["with_headroom_usd"])
            out.savedUSD = dbl(cost["total_saved_usd"])
            out.savingsPct = dbl(cost["savings_pct"])
        }
        if out.savingsPct == 0, out.withoutUSD > 0 {
            out.savingsPct = out.savedUSD / out.withoutUSD * 100
        }
        out.co2Grams = dbl((persistent["co2"] as? [String: Any])?["co2_saved_g"])

        // session
        out.sessionRequests = int(session["requests"])
        out.sessionTokensSaved = int(session["tokens_saved"]) + int(session["tool_tokens_saved"])
        out.sessionUSD = dbl(session["compression_savings_usd"]) + dbl(session["tool_schema_savings_usd"])
        out.sessionPct = dbl(session["savings_percent"])
        out.sessionStarted = parseISO(session["started_at"] as? String)
        out.lastActivity = parseISO(session["last_activity_at"] as? String)

        // Per-project block: only `/stats` carries it, keyed by project name rather than
        // path, so the name is used as-is. Sorted newest-activity-first because the card
        // answers "what am I working on now", not "what did I do most of".
        if let byProject = persistent["projects"] as? [String: [String: Any]] {
            out.projects = byProject.compactMap { name, p in
                let reqs = int(p["requests"])
                guard reqs > 0 else { return nil }
                return HeadroomProject(
                    name: name,
                    requests: reqs,
                    tokensSaved: int(p["tokens_saved"]),
                    savedUSD: dbl(p["compression_savings_usd"]),
                    savingsPct: dbl(p["savings_percent"]),
                    lastActivity: parseISO(p["last_activity_at"] as? String))
            }
            .sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
        }
    }

    private static func int(_ any: Any?) -> Int {
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) ?? 0 }
        return 0
    }

    private static func dbl(_ any: Any?) -> Double {
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) ?? 0 }
        return 0
    }

    private static func parseISO(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
