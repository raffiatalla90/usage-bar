import XCTest
import SQLite3
@testable import UsageBarKit

/// The rtk page silently read zeros for hours because two separate things were wrong:
/// a WAL database that a read-only open cannot `prepare`, and an ISO bound ending in `Z`
/// that sorts after the stored `...T09:22:34.212337+00:00` rows. Both are pinned here.
final class LocalToolsTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rtk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeDB(_ rows: [(String, Int, Double)], project: String = "") throws -> URL {
        let url = dir.appendingPathComponent("history.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, """
            CREATE TABLE commands (id INTEGER PRIMARY KEY, timestamp TEXT NOT NULL,
              original_cmd TEXT NOT NULL, rtk_cmd TEXT NOT NULL,
              input_tokens INTEGER NOT NULL, output_tokens INTEGER NOT NULL,
              saved_tokens INTEGER NOT NULL, savings_pct REAL NOT NULL,
              exec_time_ms INTEGER DEFAULT 0, project_path TEXT DEFAULT '');
            """, nil, nil, nil), SQLITE_OK)
        for (ts, saved, pct) in rows {
            XCTAssertEqual(sqlite3_exec(db, """
                INSERT INTO commands (timestamp, original_cmd, rtk_cmd, input_tokens,
                  output_tokens, saved_tokens, savings_pct, project_path)
                VALUES ('\(ts)', 'ls', 'ls', 10, 10, \(saved), \(pct), '\(project)');
                """, nil, nil, nil), SQLITE_OK)
        }
        return url
    }

    private func stamp(hoursAgo: Double) -> String {
        let d = Date().addingTimeInterval(-hoursAgo * 3600)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'+00:00'"
        return f.string(from: d)
    }

    func testReadsWALDatabaseAndCountsToday() throws {
        let url = try makeDB([
            (stamp(hoursAgo: 1), 500, 25),
            (stamp(hoursAgo: 2), 300, 15),
            (stamp(hoursAgo: 24 * 10), 1000, 40),
        ])
        let s = LocalTools.rtk(dbPath: url)
        XCTAssertNil(s.error)
        XCTAssertTrue(s.dbFound)
        XCTAssertEqual(s.commandsToday, 2)
        XCTAssertEqual(s.savedToday, 800)
        XCTAssertEqual(s.commands30d, 3)
        XCTAssertEqual(s.saved30d, 1800)
        XCTAssertNotNil(s.lastRun)
        XCTAssertTrue(s.isRunning)
    }

    /// A row written a fraction of a second past midnight must still count as today.
    func testMidnightBoundaryKeepsFractionalRows() throws {
        let start = Calendar.current.startOfDay(for: Date())
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'+00:00'"
        let justAfter = f.string(from: start.addingTimeInterval(0.4))
        let url = try makeDB([(justAfter, 42, 10)])
        XCTAssertEqual(LocalTools.rtk(dbPath: url).savedToday, 42)
    }

    func testMissingDBReportsError() {
        let s = LocalTools.rtk(dbPath: dir.appendingPathComponent("nope.db"))
        XCTAssertFalse(s.dbFound)
        XCTAssertNotNil(s.error)
        XCTAssertFalse(s.isRunning)
    }

    /// The Tool page answers "which project am I in": rows must come out newest-first, and
    /// the newest one is what `activeProject` reports.
    func testProjectsAreGroupedAndOrderedByRecency() throws {
        let url = dir.appendingPathComponent("history.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, """
            CREATE TABLE commands (id INTEGER PRIMARY KEY, timestamp TEXT NOT NULL,
              original_cmd TEXT NOT NULL, rtk_cmd TEXT NOT NULL,
              input_tokens INTEGER NOT NULL, output_tokens INTEGER NOT NULL,
              saved_tokens INTEGER NOT NULL, savings_pct REAL NOT NULL,
              exec_time_ms INTEGER DEFAULT 0, project_path TEXT DEFAULT '');
            """, nil, nil, nil), SQLITE_OK)
        func insert(_ ts: String, _ saved: Int, _ path: String) {
            XCTAssertEqual(sqlite3_exec(db, """
                INSERT INTO commands (timestamp, original_cmd, rtk_cmd, input_tokens,
                  output_tokens, saved_tokens, savings_pct, project_path)
                VALUES ('\(ts)', 'ls', 'ls', 10, 10, \(saved), 10, '\(path)');
                """, nil, nil, nil), SQLITE_OK)
        }
        insert(stamp(hoursAgo: 3), 100, "/Users/x/alpha")
        insert(stamp(hoursAgo: 2), 200, "/Users/x/beta")
        insert(stamp(hoursAgo: 1), 300, "/Users/x/alpha")
        sqlite3_close(db)

        let s = LocalTools.rtk(dbPath: url)
        XCTAssertEqual(s.projects.map(\.name), ["alpha", "beta"])
        XCTAssertEqual(s.projects.first?.commands, 2)
        XCTAssertEqual(s.projects.first?.savedTokens, 400)
        XCTAssertEqual(s.activeProject?.name, "alpha")
        // Home prefix collapses to `~` only when the path is really under home; a foreign
        // path is left alone.
        XCTAssertEqual(s.activeProject?.displayPath, "/Users/x/alpha")
    }
}
