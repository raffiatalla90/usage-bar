import XCTest
@testable import UsageBarKit

/// Rows must survive midnight: the feed is a rolling window, never a per-day reset.
final class ActivityFeedRetentionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("activity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// One session log with an edit from yesterday and one from today.
    private func writeSession(daysAgo: [Int]) throws {
        let dir = root.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var lines: [String] = []
        for (i, d) in daysAgo.enumerated() {
            let ts = iso.string(from: Calendar.current.date(byAdding: .day, value: -d, to: Date())!)
            let obj: [String: Any] = [
                "timestamp": ts,
                "cwd": "/tmp",
                "message": ["content": [[
                    "type": "tool_use",
                    "id": "toolu_\(i)",
                    "name": "Edit",
                    "input": ["file_path": "/tmp/proj/file\(i).swift"]
                ]]],
            ]
            lines.append(String(data: try JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!)
        }
        try lines.joined(separator: "\n").write(to: dir.appendingPathComponent("s.jsonl"),
                                                atomically: true, encoding: .utf8)
    }

    func testYesterdaySurvivesIntoToday() throws {
        try writeSession(daysAgo: [0, 1, 3])
        let got = ActivityFeed.claude(since: Date().addingTimeInterval(-14 * 86400),
                                      limit: 200, root: root.path)
        XCTAssertEqual(got.count, 3, "every row inside the window stays listed")
        let days = Set(got.map { Calendar.current.startOfDay(for: $0.date) })
        XCTAssertEqual(days.count, 3, "rows from three different days, none pruned at midnight")
    }

    func testNarrowWindowStillFilters() throws {
        try writeSession(daysAgo: [0, 3])
        let got = ActivityFeed.claude(since: Date().addingTimeInterval(-86400),
                                      limit: 200, root: root.path)
        XCTAssertEqual(got.count, 1, "a one-day window keeps only the recent row")
    }

    func testCacheReturnsSameRowsAndTracksWrites() throws {
        try writeSession(daysAgo: [1])
        let cache = ActivityFeed.ActivityCache()
        let since = Date().addingTimeInterval(-14 * 86400)
        let first = ActivityFeed.claude(since: since, limit: 200, root: root.path, cache: cache)
        let second = ActivityFeed.claude(since: since, limit: 200, root: root.path, cache: cache)
        XCTAssertEqual(first.map(\.id), second.map(\.id), "cached scan is stable")

        // Appending to the session must invalidate that file's entry, not the whole cache.
        try writeSession(daysAgo: [0, 1])
        let third = ActivityFeed.claude(since: since, limit: 200, root: root.path, cache: cache)
        XCTAssertEqual(third.count, 2, "new row picked up after the file changed")
    }
}
