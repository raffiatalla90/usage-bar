import Foundation
import SQLite3

/// One file change made by a coding agent.
///
/// Both agents already record every tool call on disk, so nothing here talks to a network:
/// OpenCode writes to `~/.local/share/opencode/opencode.db` (`part` table, JSON `data` column)
/// and Claude Code appends `tool_use` blocks to `~/.claude/projects/<slug>/<session>.jsonl`.
public struct CodeActivity: Identifiable, Hashable, Sendable {
    public enum Agent: String, Sendable {
        case opencode = "OpenCode"
        case claude = "Claude Code"
    }

    public var id: String
    public var agent: Agent
    public var path: String
    public var tool: String
    public var date: Date
    /// How many times this file was touched in the window; the feed collapses repeats into
    /// one row so a burst of edits does not bury everything else.
    public var hits: Int

    public init(id: String, agent: Agent, path: String, tool: String, date: Date, hits: Int = 1) {
        self.id = id
        self.agent = agent
        self.path = path
        self.tool = tool
        self.date = date
        self.hits = hits
    }

    public var fileName: String { (path as NSString).lastPathComponent }

    /// Project the file belongs to — the directory just above the framework root, so grouped
    /// rows read `laravel_belanja` rather than the leaf folder `Checkout`.
    public var projectName: String {
        let comps = path.split(separator: "/").map(String.init)
        let markers: Set<String> = ["app", "tests", "src", "resources", "routes", "config",
                                    "database", "packages", "lib", "Sources", "public"]
        if let i = comps.firstIndex(where: { markers.contains($0) }), i > 0 {
            return comps[i - 1]
        }
        return comps.count >= 2 ? comps[comps.count - 2] : ""
    }

    /// Path inside the project, e.g. `app/Support/Checkout` — the group header already names
    /// the project, so repeating it in every row wastes the little width the panel has.
    public var subpath: String {
        let dir = (path as NSString).deletingLastPathComponent
        let proj = projectName
        guard !proj.isEmpty, let r = dir.range(of: proj) else { return folder }
        let rest = String(dir[r.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return rest.isEmpty ? proj : rest
    }

    /// Folder of the file relative to home, e.g. `belanja/laravel_belanja/app/Support/Checkout`.
    /// The view truncates from the head, so the deepest (most informative) folders always stay visible.
    public var folder: String {
        let dir = (path as NSString).deletingLastPathComponent
        let home = NSHomeDirectory() + "/"
        return dir.hasPrefix(home) ? String(dir.dropFirst(home.count)) : dir
    }
}

public enum ActivityFeed {
    public static let openCodeDB = NSHomeDirectory() + "/.local/share/opencode/opencode.db"
    public static let claudeProjects = NSHomeDirectory() + "/.claude/projects"

    /// Merged, newest-first view of file changes from both agents.
    public static func recent(since: Date, limit: Int = 200,
                              cache: ActivityCache? = nil) -> [CodeActivity] {
        var all = openCode(since: since, limit: limit) + claude(since: since, limit: limit, cache: cache)
        all = all.filter { plausible($0.path) }
        all.sort { $0.date > $1.date }
        return Array(all.prefix(limit))
    }

    /// Shell-log parsing is best-effort, so a redirect target can come out as a fragment of
    /// code (`<link`, `{`, `"`). Drop those: a real edit names an absolute path with no shell
    /// metacharacters, and either still exists or at least looks like a file.
    static func plausible(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        if path.rangeOfCharacter(from: CharacterSet(charactersIn: "<>{}|\"`\\ \t\n")) != nil { return false }
        let last = (path as NSString).lastPathComponent
        guard !last.isEmpty, last != ".", last != ".." else { return false }
        return FileManager.default.fileExists(atPath: path) || last.contains(".")
    }

    /// Parsed-session cache. A 30-day window spans ~90 jsonl files (~50 MB); re-parsing them
    /// on every 2 s tick would burn CPU for data that only grows at the tail. Sessions are
    /// immutable once written, so the file mtime is a safe cache key.
    public final class ActivityCache: @unchecked Sendable {
        private var entries: [String: (mtime: Date, items: [CodeActivity])] = [:]
        public init() {}

        func items(for path: String, mtime: Date, parse: () -> [CodeActivity]) -> [CodeActivity] {
            if let e = entries[path], e.mtime == mtime { return e.items }
            let items = parse()
            entries[path] = (mtime, items)
            return items
        }

        /// Forget sessions that fell out of the window so the cache cannot grow forever.
        func retain(only paths: Set<String>) {
            guard entries.count > paths.count else { return }
            entries = entries.filter { paths.contains($0.key) }
        }
    }

    // MARK: - OpenCode (SQLite)

    public static func openCode(since: Date, limit: Int = 40, dbPath: String = openCodeDB) -> [CodeActivity] {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db = handle else { return [] }
        defer { sqlite3_close(db) }

        // `edit`/`write` carry one filePath; `patch` carries a files[] array — handled by the
        // second query so one call site stays readable.
        let sql = """
        SELECT id, time_created, json_extract(data,'$.tool'),
               coalesce(json_extract(data,'$.state.input.filePath'),
                        json_extract(data,'$.state.input.file_path'))
        FROM part
        WHERE json_extract(data,'$.type') = 'tool'
          AND json_extract(data,'$.tool') IN ('edit','write','multiedit')
          AND time_created > ?
        ORDER BY time_created DESC LIMIT ?
        """
        var out: [CodeActivity] = []
        var stmt: OpaquePointer?
        let cutoff = Int64(since.timeIntervalSince1970 * 1000)
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, cutoff)
            sqlite3_bind_int(stmt, 2, Int32(limit))
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let idC = sqlite3_column_text(stmt, 0),
                      let toolC = sqlite3_column_text(stmt, 3 - 1),
                      let pathC = sqlite3_column_text(stmt, 3) else { continue }
                let ms = sqlite3_column_int64(stmt, 1)
                let path = String(cString: pathC)
                guard !path.isEmpty else { continue }
                out.append(CodeActivity(id: "oc-" + String(cString: idC),
                                        agent: .opencode,
                                        path: path,
                                        tool: String(cString: toolC),
                                        date: Date(timeIntervalSince1970: Double(ms) / 1000)))
            }
        }
        sqlite3_finalize(stmt)
        return out
    }

    // MARK: - Claude Code (jsonl)

    public static func claude(since: Date, limit: Int = 200, root: String = claudeProjects,
                              cache: ActivityCache? = nil) -> [CodeActivity] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        // Only sessions touched inside the window — the full corpus is ~200 MB.
        var files: [(URL, Date)] = []
        for d in dirs {
            let dirURL = URL(fileURLWithPath: root).appendingPathComponent(d)
            guard let names = try? fm.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for url in names where url.pathExtension == "jsonl" {
                let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if m >= since { files.append((url, m)) }
            }
        }
        cache?.retain(only: Set(files.map(\.0.path)))
        var out: [CodeActivity] = []
        var seen = Set<String>()
        for (url, mtime) in files.sorted(by: { $0.1 > $1.1 }) {
            guard out.count < limit else { break }
            // Whole file, not the tail: a wide window needs the session's early entries too.
            // The cache makes the full read a once-per-write cost.
            let parsed: [CodeActivity] = cache?.items(for: url.path, mtime: mtime) {
                scanClaudeFile(url, mtime: mtime, since: .distantPast)
            } ?? scanClaudeFile(url, mtime: mtime, since: since)
            for item in parsed where item.date >= since {
                guard seen.insert(item.id).inserted else { continue }
                out.append(item)
            }
        }
        out.sort { $0.date > $1.date }
        return Array(out.prefix(limit))
    }

    /// Every tool_use file write inside one session log. Parsed once per file write and cached.
    static func scanClaudeFile(_ url: URL, mtime: Date, since: Date) -> [CodeActivity] {
        guard let text = whole(url) ?? tail(of: url, bytes: 512 * 1024) else { return [] }
        var out: [CodeActivity] = []
        var seen = Set<String>()
        for line in text.split(separator: "\n") {
            guard line.contains("\"tool_use\""),
                  let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let msg = obj["message"] as? [String: Any],
                  let blocks = msg["content"] as? [[String: Any]] else { continue }
            // `api-request-blob` records replay the same tool_use without a timestamp;
            // fall back to the session file's mtime and let the id dedupe below drop
            // the replay when the real `assistant` record is also present.
            let ts = parseDate(obj["timestamp"] as? String) ?? mtime
            guard ts >= since else { continue }
            for b in blocks where (b["type"] as? String) == "tool_use" {
                let name = (b["name"] as? String) ?? ""
                let input = b["input"] as? [String: Any]
                // Claude Code often edits through Bash (`cat > f`, `sed -i`, `tee`) instead
                // of the Edit tool, so a tool-name filter alone misses whole sessions.
                let path: String?
                let tool: String
                if ["Edit", "Write", "MultiEdit", "NotebookEdit"].contains(name) {
                    path = (input?["file_path"] as? String) ?? (input?["notebook_path"] as? String)
                    tool = name
                } else if name == "Bash", let cmd = input?["command"] as? String,
                          let p = shellWriteTarget(cmd, cwd: obj["cwd"] as? String) {
                    path = p
                    tool = "bash"
                } else { continue }
                guard let path, !path.isEmpty else { continue }
                let id = (b["id"] as? String) ?? "\(url.lastPathComponent)-\(path)-\(ts.timeIntervalSince1970)"
                guard seen.insert(id).inserted else { continue }
                out.append(CodeActivity(id: "cc-" + id, agent: .claude, path: path, tool: tool, date: ts))
            }
        }
        return out
    }

    // MARK: - Helpers

    /// Pull the write destination out of a shell command: `cat > f`, `>> f`, `tee f`,
    /// `sed -i ... f`, `mv/cp ... f`. Reads (`cat f`, `grep`) return nil so the feed stays
    /// about changes, not lookups. Best-effort by design — a false negative just hides a row.
    static func shellWriteTarget(_ cmd: String, cwd: String? = nil) -> String? {
        let single = cmd.replacingOccurrences(of: "\\\n", with: " ")
        for rawLine in single.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#") else { continue }
            func clean(_ s: String) -> String {
                var t = s.trimmingCharacters(in: .whitespaces)
                for q in ["\"", "'"] where t.hasPrefix(q) {
                    if let end = t.dropFirst().firstIndex(of: Character(q)) {
                        t = String(t[t.index(after: t.startIndex)...end])
                    }
                }
                t = t.split(separator: " ").first.map(String.init) ?? t
                if t.hasPrefix("$PWD/") { t = String(t.dropFirst(5)) }
                return t
            }
            func absolute(_ p: String) -> String {
                // `/dev/null` and `2>&1` are redirect targets, not files anyone edited; a `$VAR`
                // path cannot be resolved from the log, so it would only show junk.
                if p.isEmpty || p.hasPrefix("&") || p.hasPrefix("$") || p.hasPrefix("/dev/") || p.hasPrefix("/proc/") { return "" }
                if p.contains("/scratchpad/") { return "" }
                if p.hasPrefix("/") { return p }
                if p.hasPrefix("~/") { return NSHomeDirectory() + String(p.dropFirst(1)) }
                guard let cwd, !cwd.isEmpty else { return "" }
                return (cwd as NSString).appendingPathComponent(p)
            }
            // sed -i [SUFFIX] -e '...' FILE
            if line.contains("sed -i") || line.contains("sed -i''") {
                let parts = line.split(separator: " ").map(String.init)
                if let idx = parts.firstIndex(where: { $0.hasPrefix("-i") }),
                   let file = parts.dropFirst(idx + 1).last(where: { !$0.hasPrefix("-") && !$0.hasPrefix("'") && !$0.hasPrefix("\"") }) {
                    let p = absolute(clean(file))
                    if !p.isEmpty { return p }
                }
            }
            // tee [-a] FILE
            if let r = line.range(of: "tee ") {
                let rest = String(line[r.upperBound...])
                let p = absolute(clean(rest))
                if !p.isEmpty { return p }
            }
            // cat/printf/echo ... > FILE  (also >>)
            if line.contains(">") {
                let afterArrow = line.split(separator: ">").last.map(String.init) ?? ""
                let p = absolute(clean(afterArrow))
                if !p.isEmpty, !p.hasPrefix("&") { return p }
            }
            // mv/cp SRC DEST — the last argument is what changed on disk.
            for verb in ["mv ", "cp "] where line.hasPrefix(verb) || line.contains("&& \(verb)") {
                if let last = line.split(separator: " ").last.map(String.init) {
                    let p = absolute(clean(last))
                    if !p.isEmpty { return p }
                }
            }
        }
        return nil
    }

    private static func whole(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func tail(of url: URL, bytes: Int) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? h.seek(toOffset: start)
        guard let data = try? h.readToEnd(), var s = String(data: data, encoding: .utf8) else { return nil }
        // Drop the partial first line when we cut mid-file.
        if start > 0, let nl = s.firstIndex(of: "\n") { s = String(s[s.index(after: nl)...]) }
        return s
    }

    private static func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? {
            f.formatOptions = [.withInternetDateTime]
            return f.date(from: s)
        }()
    }
}
