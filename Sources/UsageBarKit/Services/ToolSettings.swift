import Foundation

/// One pickable compression level: `id` is what gets written into the tool, `label` is what
/// the popover shows. They differ because each tool names its levels differently for the
/// same idea — rtk's "default" is the light one, headroom's "agent-90" is the heavy one.
public struct ToolLevel: Identifiable, Sendable, Equatable {
    public let id: String
    public let label: String
    public init(_ id: String, _ label: String) { self.id = id; self.label = label }
}

public enum ToolSettingsError: LocalizedError {
    case proxy(String)
    public var errorDescription: String? {
        switch self {
        case .proxy(let message): return message
        }
    }
}

/// Read/write the level of the three context savers.
///
/// Two of them keep a config file, one keeps a loopback HTTP endpoint; there is no shared
/// API to abstract over, so each gets its own small reader/writer. Every writer touches only
/// the key it owns — the rest of the file is preserved byte for byte, because these files are
/// also edited by hand and by the tools themselves.
///
/// `home:` is injectable so the round-trip can be tested without touching the real config.
public enum ToolSettings {
    /// caveman's own VALID_MODES, minus the wenyan/one-shot variants that are a different job.
    public static let cavemanLevels = [
        ToolLevel("lite", "lite"), ToolLevel("full", "full"),
        ToolLevel("ultra", "ultra"), ToolLevel("off", "off"),
    ]
    /// rtk `[awareness] level` accepts exactly default|high|full.
    public static let rtkLevels = [
        ToolLevel("default", "lite"), ToolLevel("high", "sedang"), ToolLevel("full", "full"),
    ]
    /// headroom savings profiles, lightest first. `coding` is headroom's own default and the
    /// safe choice for agent work; `agent-90` pins a 0.10 keep-ratio.
    public static let headroomLevels = [
        ToolLevel("coding", "lite"), ToolLevel("balanced", "sedang"), ToolLevel("agent-90", "full"),
    ]

    // MARK: - caveman

    static func cavemanConfigURL(home: URL) -> URL {
        home.appendingPathComponent(".config/caveman/config.json")
    }

    /// The legacy mirror the hooks fall back to when a session has no state of its own.
    static func cavemanFlagURL(home: URL) -> URL {
        home.appendingPathComponent(".claude/.caveman-active")
    }

    public static func cavemanLevel(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        if let data = try? Data(contentsOf: cavemanConfigURL(home: home)),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let mode = obj["defaultMode"] as? String, !mode.isEmpty {
            return mode.lowercased()
        }
        if let raw = try? String(contentsOf: cavemanFlagURL(home: home), encoding: .utf8) {
            let mode = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return mode.isEmpty ? nil : mode
        }
        return nil
    }

    public static func setCavemanLevel(_ level: String,
                                       home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let url = cavemanConfigURL(home: home)
        var obj: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            obj = existing
        }
        obj["defaultMode"] = level
        try write(try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]), to: url)

        // Mirror the flag exactly the way caveman's own writer does: 'off' is expressed by
        // deleting the file, never by writing the literal — an older hook reading "off" from
        // this path would announce "CAVEMAN MODE ACTIVE (off)".
        let flag = cavemanFlagURL(home: home)
        if level == "off" {
            try? FileManager.default.removeItem(at: flag)
        } else {
            try write(Data((level + "\n").utf8), to: flag)
        }
    }

    // MARK: - rtk

    static func rtkConfigURL(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/rtk/config.toml")
    }

    public static func rtkLevel(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        guard let text = try? String(contentsOf: rtkConfigURL(home: home), encoding: .utf8) else { return nil }
        return rtkLevel(inTOML: text)
    }

    /// `level` lives in its own `[awareness]` table; a `level` key under any other table is a
    /// different setting, so the scan stops at the next table header.
    static func rtkLevel(inTOML text: String) -> String? {
        var inSection = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inSection = (line == "[awareness]"); continue }
            guard inSection, line.hasPrefix("level") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            return parts[1].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }

    public static func setRtkLevel(_ level: String,
                                   home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let url = rtkConfigURL(home: home)
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try write(Data(rtkSetting(level, inTOML: text).utf8), to: url)
        refreshRtkInstructions(home: home)
    }

    /// `[awareness] level` is baked into `~/.claude/RTK.md` by `rtk init -g`; the hook never
    /// reads the config at runtime. Regenerating is the documented way and is idempotent, but
    /// it is skipped when RTK.md does not exist — then rtk is not wired up yet and the config
    /// alone is all that is needed.
    static func refreshRtkInstructions(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let md = home.appendingPathComponent(".claude/RTK.md")
        guard FileManager.default.fileExists(atPath: md.path) else { return }
        let candidates = ["/opt/homebrew/bin/rtk", "/usr/local/bin/rtk"]
        guard let rtk = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: rtk)
        p.arguments = ["init", "-g"]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home.path
        p.environment = env
        guard (try? p.run()) != nil else { return }
        p.waitUntilExit()
    }

    /// Replace the value in place, or append the table when the file has none yet.
    static func rtkSetting(_ level: String, inTOML text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var inSection = false
        var found = false
        for i in lines.indices {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inSection = (line == "[awareness]"); continue }
            if inSection, line.hasPrefix("level") {
                lines[i] = "level = \"\(level)\""
                found = true
                break
            }
        }
        if !found {
            if let last = lines.last, !last.isEmpty { lines.append("") }
            lines.append("[awareness]")
            lines.append("level = \"\(level)\"")
        }
        var out = lines.joined(separator: "\n")
        if !out.hasSuffix("\n") { out += "\n" }
        return out
    }

    // MARK: - headroom

    /// Stored value only — nil means "nothing saved", which the proxy reads as its default.
    /// Reads the on-disk settings file so the popover can show the stored profile without
    /// waiting on the proxy; `headroomLevel(port:)` refines it to the effective value.
    public static func headroomStoredLevel(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        let url = home.appendingPathComponent(".headroom/settings.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stored = obj["savings_profile"] as? String, !stored.isEmpty
        else { return nil }
        return stored
    }

    /// When nothing is stored the effective default is fetched from the schema so the popover
    /// highlights what is actually running instead of showing nothing.
    public static func headroomLevel(port: Int = Headroom.defaultPort,
                                     timeout: TimeInterval = 2) async -> String? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/settings") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalCacheData
        if let (data, _) = try? await URLSession.shared.data(for: req),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let stored = obj["savings_profile"] as? String {
            return stored
        }
        return await headroomDefault(port: port, timeout: timeout)
    }

    private static func headroomDefault(port: Int, timeout: TimeInterval) async -> String? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/settings/schema") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return headroomProfile(fromSchema: data)
    }

    /// The schema reports the profile actually in force under `value` (the stored override
    /// under `stored`); `default` is only the fallback when neither is present.
    static func headroomProfile(fromSchema data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fields = obj["fields"] as? [[String: Any]],
              let field = fields.first(where: { $0["key"] as? String == "savings_profile" })
        else { return nil }
        return field["value"] as? String ?? field["stored"] as? String ?? field["default"] as? String
    }

    /// Saves only; headroom applies settings at startup, so the caller reports "restart proxy".
    /// `/settings/apply` is deliberately not called: it restarts the proxy process, which here
    /// is a foreground process somebody else owns.
    @discardableResult
    public static func setHeadroomLevel(_ level: String,
                                        port: Int = Headroom.defaultPort,
                                        timeout: TimeInterval = 4) async throws -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/settings") else {
            throw ToolSettingsError.proxy("alamat proxy tidak valid")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["values": ["savings_profile": level]])
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ToolSettingsError.proxy("proxy menolak (\(code)) \(body.prefix(120))")
        }
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (obj?["needs_restart"] as? Bool) ?? true
    }

    // MARK: - io

    /// Headroom applies settings only at startup. When it runs as a LaunchAgent (the usual
    /// install) it can be restarted in place; otherwise the caller has to say "restart it".
    /// Returns false when no such agent is loaded, so the UI can fall back to a message.
    public static func restartHeadroom(port: Int = Headroom.defaultPort,
                                       timeout: TimeInterval = 6) async -> Bool {
        let label = "ai.headroom.proxy"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["kickstart", "-k", "gui/\(getuid())/\(label)"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return false }

        // Poll until it answers again, so the next read shows the new profile.
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if await headroomLevel(port: port, timeout: 1) != nil { return true }
        }
        return false
    }

    private static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
