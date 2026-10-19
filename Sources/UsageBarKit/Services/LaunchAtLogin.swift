import Foundation

/// Auto-start at login via a per-user LaunchAgent (no helper, no privileges needed).
public enum LaunchAtLogin {
    public static var label: String { "com.usagebar.app" }

    public static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    public static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    public static func setEnabled(_ enabled: Bool, appPath: URL? = nil) throws {
        if enabled {
            let exe = appPath ?? Bundle.main.bundleURL
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": ["/usr/bin/open", "-a", exe.path],
                "RunAtLoad": true,
                "KeepAlive": false,
                "ProcessType": "Interactive",
            ]
            let dir = plistURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
            bootstrap()
        } else {
            bootout()
            try? FileManager.default.removeItem(at: plistURL)
        }
    }

    static func domain() -> String { "gui/\(getuid())" }

    static func bootstrap() {
        _ = run("/bin/launchctl", ["bootout", "\(domain())/\(label)"])
        _ = run("/bin/launchctl", ["bootstrap", domain(), plistURL.path])
    }

    static func bootout() {
        _ = run("/bin/launchctl", ["bootout", "\(domain())/\(label)"])
    }

    @discardableResult
    static func run(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
