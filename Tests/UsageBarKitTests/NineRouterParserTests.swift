import XCTest
import SQLite3
@testable import UsageBarKit

final class NineRouterParserTests: XCTestCase {

    // Throwaway copy of the real 9router schema, so the test never touches live data.
    private func makeDB(kenariRows: [(String, String, Int, Int)],
                        otherRows: [(String, String, Int, Int)] = []) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("router-\(UUID().uuidString).sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }

        let ddl = """
            CREATE TABLE providerNodes (id TEXT, type TEXT, name TEXT, data TEXT);
            CREATE TABLE usageHistory (id INTEGER PRIMARY KEY AUTOINCREMENT, timestamp TEXT NOT NULL,
                provider TEXT, model TEXT, connectionId TEXT, apiKey TEXT, endpoint TEXT,
                promptTokens INTEGER DEFAULT 0, completionTokens INTEGER DEFAULT 0,
                cost REAL DEFAULT 0, status TEXT, tokens TEXT, meta TEXT);
            """
        XCTAssertEqual(sqlite3_exec(db, ddl, nil, nil, nil), SQLITE_OK)

        let nodes = """
            INSERT INTO providerNodes VALUES ('node-kenari','openai-compatible','Kenari.id',
                '{"prefix":"kenari","baseUrl":"https://kenari.id/v1"}');
            INSERT INTO providerNodes VALUES ('node-other','openai-compatible','Other',
                '{"baseUrl":"https://api.other.ai/v1"}');
            """
        XCTAssertEqual(sqlite3_exec(db, nodes, nil, nil, nil), SQLITE_OK)

        func insert(_ rows: [(String, String, Int, Int)], provider: String) {
            for (ts, model, prompt, completion) in rows {
                let sql = """
                    INSERT INTO usageHistory (timestamp, provider, model, promptTokens, completionTokens)
                    VALUES ('\(ts)','\(provider)','\(model)',\(prompt),\(completion));
                    """
                XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
            }
        }
        insert(kenariRows, provider: "node-kenari")
        insert(otherRows, provider: "node-other")
        return url
    }

    private func iso(_ date: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    func testOnlyKenariNodeRowsCounted() throws {
        let url = try makeDB(kenariRows: [(iso(), "m1", 100, 10)],
                             otherRows: [(iso(), "m2", 999, 99)])
        defer { try? FileManager.default.removeItem(at: url) }

        let report = try NineRouterProvider(config: .init(databaseURL: url)).report(range: .today)
        XCTAssertEqual(report.totals.requests, 1, "non-Kenari node traffic must be excluded")
        XCTAssertEqual(report.totals.inputTokens, 100)
        XCTAssertEqual(report.totals.outputTokens, 10)
        XCTAssertEqual(report.models.first?.model, "m1")
        XCTAssertEqual(report.source, .routerLocal)
    }

    func testYesterdayExcludesToday() throws {
        let yesterday = iso(Date().addingTimeInterval(-86_400))
        let url = try makeDB(kenariRows: [(yesterday, "old", 10, 1), (iso(), "new", 20, 2)])
        defer { try? FileManager.default.removeItem(at: url) }

        let report = try NineRouterProvider(config: .init(databaseURL: url)).report(range: .yesterday)
        XCTAssertEqual(report.totals.requests, 1, "yesterday must not include today's rows")
        XCTAssertEqual(report.models.first?.model, "old")
    }

    func testMissingDBReportsUnavailable() {
        let provider = NineRouterProvider(config: .init(databaseURL: URL(fileURLWithPath: "/nonexistent/x.sqlite")))
        XCTAssertThrowsError(try provider.report(range: .today))
    }
}
