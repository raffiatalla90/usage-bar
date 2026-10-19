import Foundation
import SQLite3

/// Status of the two context-savers that run alongside the coding agents.
///
/// Both keep their own on-disk record, so nothing here needs a network call:
///   rtk     → `~/Library/Application Support/rtk/history.db`, table `commands`
///             (timestamp ISO8601 UTC, input_tokens, output_tokens, saved_tokens, savings_pct)
///   caveman → `~/.claude/.caveman-active` + `.caveman-mode-log.jsonl`
///             and the same pair under `~/.config/opencode/`
public struct RTKProject: Sendable, Equatable, Identifiable {
    public var path: String
    public var commands: Int
    public var savedTokens: Int
    public var lastRun: Date?
    public var id: String { path }

    public init(path: String, commands: Int = 0, savedTokens: Int = 0, lastRun: Date? = nil) {
        self.path = path; self.commands = commands; self.savedTokens = savedTokens; self.lastRun = lastRun
    }

    /// Last path component: `/Users/x/UsageBar/Sources` reads as `Sources`, which is what a
    /// human calls the place they are working in.
    public var name: String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        let base = (trimmed as NSString).lastPathComponent
        return base.isEmpty ? trimmed : base
    }

    /// Full path with the home prefix collapsed to `~`. The bare folder name is ambiguous
    /// once subdirectories show up (`controllers`, `docs`), so rows use this and truncate in
    /// the middle.
    public var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }
}

public struct RTKStats: Sendable, Equatable {
    public var installed = false
    public var dbFound = false
    public var commandsToday = 0
    public var savedToday = 0
    public var savingsPctToday = 0.0
    public var commands30d = 0
    public var saved30d = 0
    public var lastRun: Date?
    /// Today's commands per working directory, most recent first.
    public var projects: [RTKProject] = []
    public var error: String?

    public init() {}
    public static let empty = RTKStats()

    /// The directory rtk logged most recently — the closest thing to "what am I working on".
    public var activeProject: RTKProject? { projects.first }

    /// "Jalan" only when rtk actually logged something in the last day.
    public var isRunning: Bool {
        guard let lastRun else { return false }
        return Date().timeIntervalSince(lastRun) < 24 * 3600
    }
}

public struct CavemanAgent: Sendable, Equatable, Identifiable {
    public var name: String
    public var active: Bool
    public var mode: String?
    public var lastToggled: Date?
    public var sessions: Int
    public var id: String { name }

    public init(name: String, active: Bool = false, mode: String? = nil,
                lastToggled: Date? = nil, sessions: Int = 0) {
        self.name = name; self.active = active; self.mode = mode
        self.lastToggled = lastToggled; self.sessions = sessions
    }

    public var isRunning: Bool {
        guard active, let lastToggled else { return active }
        return Date().timeIntervalSince(lastToggled) < 7 * 24 * 3600
    }
}

public struct CavemanStatus: Sendable, Equatable {
    public var agents: [CavemanAgent] = []
    public init() {}
    public static let empty = CavemanStatus()
    public var running: Bool { agents.contains { $0.isRunning } }
}

public enum LocalTools {
    // MARK: - rtk

    public static func rtk(dbPath: URL? = nil) -> RTKStats {
        var out = RTKStats()
        let home = FileManager.default.homeDirectoryForCurrentUser
        out.installed = ["/opt/homebrew/bin/rtk", "/usr/local/bin/rtk",
                         home.appendingPathComponent(".local/bin/rtk").path]
            .contains { FileManager.default.isExecutableFile(atPath: $0) }

        let db = dbPath ?? home.appendingPathComponent("Library/Application Support/rtk/history.db")
        guard FileManager.default.fileExists(atPath: db.path) else {
            out.error = "history.db belum ada"
            return out
        }
        out.dbFound = true

        let cal = Calendar.current
        let today = iso(cal.startOfDay(for: Date()))
        let month = iso(cal.date(byAdding: .day, value: -29, to: cal.startOfDay(for: Date())) ?? Date())
        let dbPathString = db.path

        guard let rows = try? query(dbPathString, sql: """
            SELECT
              (SELECT count(*) FROM commands WHERE timestamp >= ?1) AS c1,
              (SELECT coalesce(sum(saved_tokens),0) FROM commands WHERE timestamp >= ?1) AS c2,
              (SELECT coalesce(avg(savings_pct),0) FROM commands WHERE timestamp >= ?1) AS c3,
              (SELECT count(*) FROM commands WHERE timestamp >= ?2) AS c4,
              (SELECT coalesce(sum(saved_tokens),0) FROM commands WHERE timestamp >= ?2) AS c5,
              (SELECT max(timestamp) FROM commands) AS c6
            """, binds: [today, month]),
              let row = rows.first else {
            out.error = "gagal baca history.db"
            return out
        }
        out.commandsToday = int(row["c1"])
        out.savedToday = int(row["c2"])
        out.savingsPctToday = dbl(row["c3"])
        out.commands30d = int(row["c4"])
        out.saved30d = int(row["c5"])
        out.lastRun = (row["c6"] as? String).flatMap { parseISO($0) }

        // Which project is being worked on: rtk records the cwd of every command, so the
        // group with the newest timestamp is the active one. Ordered by recency, not by
        // volume — the loudest directory of the day is usually not where you are now.
        if let rows = try? query(dbPathString, sql: """
            SELECT project_path AS p,
                   count(*) AS n,
                   coalesce(sum(saved_tokens),0) AS s,
                   max(timestamp) AS t
            FROM commands
            WHERE timestamp >= ?1 AND project_path IS NOT NULL AND project_path <> ''
            GROUP BY project_path
            ORDER BY t DESC
            LIMIT 6
            """, binds: [today]) {
            out.projects = rows.compactMap { r in
                guard let p = r["p"] as? String, !p.isEmpty else { return nil }
                return RTKProject(path: p,
                                  commands: int(r["n"]),
                                  savedTokens: int(r["s"]),
                                  lastRun: (r["t"] as? String).flatMap { parseISO($0) })
            }
        }
        return out
    }

    // MARK: - caveman

    public static func caveman() -> CavemanStatus {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var out = CavemanStatus()
        out.agents = [
            cavemanAgent(name: "Claude Code", dir: home.appendingPathComponent(".claude")),
            cavemanAgent(name: "OpenCode", dir: home.appendingPathComponent(".config/opencode")),
        ]
        return out
    }

    private static func cavemanAgent(name: String, dir: URL) -> CavemanAgent {
        let fm = FileManager.default
        var a = CavemanAgent(name: name)
        let activeURL = dir.appendingPathComponent(".caveman-active")
        if let raw = try? String(contentsOf: activeURL, encoding: .utf8) {
            let mode = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            a.active = !mode.isEmpty && mode != "off"
            a.mode = a.active ? mode : nil
        }
        let logURL = dir.appendingPathComponent(".caveman-mode-log.jsonl")
        if let log = try? String(contentsOf: logURL, encoding: .utf8) {
            let lines = log.split(separator: "\n").suffix(1)
            if let last = lines.first,
               let obj = try? JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any] {
                if let ms = obj["ts"] as? NSNumber {
                    a.lastToggled = Date(timeIntervalSince1970: ms.doubleValue / 1000)
                }
                if a.mode == nil, let m = obj["mode"] as? String, m != "off" { a.mode = m }
            }
        }
        let sessionsDir = dir.appendingPathComponent(".caveman-sessions")
        a.sessions = (try? fm.contentsOfDirectory(atPath: sessionsDir.path))?.count ?? 0
        return a
    }

    // MARK: - sqlite plumbing

    /// Read-only, never opened for write: this is somebody else's database.
    ///
    /// rtk keeps it in WAL mode. A plain read-only open then needs to create `-shm`, which
    /// SQLite refuses (prepare → "unable to open database file", verified), and copying just
    /// the `.db` inherits the same WAL header. So the retry is `immutable=1`: no locks, no
    /// sidecar files. The trade-off is that a commit landing mid-read is not waited for —
    /// acceptable for a stats page, and the numbers are cumulative anyway.
    private static func query(_ path: String, sql: String, binds: [String]) throws -> [[String: Any]] {
        if let rows = try? run(path: path, sql: sql, binds: binds, uri: false) { return rows }
        let enc = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return try run(path: "file:\(enc)?immutable=1", sql: sql, binds: binds, uri: true)
    }

    private static func run(path: String, sql: String, binds: [String], uri: Bool) throws -> [[String: Any]] {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | (uri ? SQLITE_OPEN_URI : 0)
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            if db != nil { sqlite3_close(db) }
            throw ProviderError.unavailable("sqlite open failed")
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ProviderError.unavailable("sqlite prepare failed")
        }
        defer { sqlite3_finalize(stmt) }
        for (i, value) in binds.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), (value as NSString).utf8String, -1, nil)
        }

        var out: [[String: Any]] = []
        var col = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: Any] = [:]
            for i in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_TEXT: row[name] = sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? ""
                case SQLITE_NULL: row[name] = NSNull()
                default: row[name] = sqlite3_column_double(stmt, i)
                }
            }
            out.append(row)
            col += 1
            if col > 10_000 { break }
        }
        return out
    }

    private static func int(_ any: Any?) -> Int {
        if let d = any as? Double { return Int(d) }
        if let n = any as? NSNumber { return n.intValue }
        return 0
    }

    private static func dbl(_ any: Any?) -> Double {
        if let d = any as? Double { return d }
        if let n = any as? NSNumber { return n.doubleValue }
        return 0
    }

    /// rtk writes `2026-10-18T09:22:34.212337+00:00`; comparisons are lexical, so the bound
    /// must be a prefix of that shape. No `Z` suffix: `'Z'` sorts after `'.'`, so a
    /// `...00Z` bound would drop rows written a fraction of a second past the hour.
    private static func iso(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.string(from: date)
    }

    private static func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
