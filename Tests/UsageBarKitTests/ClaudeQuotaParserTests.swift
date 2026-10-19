import XCTest
@testable import UsageBarKit

final class ClaudeQuotaParserTests: XCTestCase {
    func testParsesUtilizationAsRemaining() {
        let payload: [String: Any] = [
            "five_hour": ["utilization": 0.28, "resets_at": "2026-10-18T09:00:00.000Z"],
            "seven_day": ["utilization": 0.62, "resets_at": "2026-10-23T15:30:00+00:00"],
        ]
        let w = ClaudeQuotaProvider.parse(payload)
        XCTAssertEqual(w.count, 2)
        XCTAssertEqual(w[0].label, "Sesi 5 jam")
        XCTAssertEqual(w[0].remaining, 0.72, accuracy: 0.001)
        XCTAssertEqual(w[1].label, "Mingguan")
        XCTAssertEqual(w[1].remaining, 0.38, accuracy: 0.001)
        XCTAssertNotNil(w[0].resetsAt)
    }

    func testParsesPercentScaleAndExplicitRemaining() {
        let payload: [String: Any] = [
            "five_hour": ["percent": 15],
            "seven_day": ["remaining": 91, "resets_in_seconds": 3600],
        ]
        let w = ClaudeQuotaProvider.parse(payload)
        XCTAssertEqual(w[0].remaining, 0.85, accuracy: 0.001)
        XCTAssertEqual(w[1].remaining, 0.91, accuracy: 0.001)
        XCTAssertNotNil(w[1].resetsAt)
    }

    func testWeeklyPerModelOrderAndAliases() {
        let payload: [String: Any] = [
            "usage": [
                "seven_day_opus": ["utilization": 0.1],
                "seven_day": ["utilization": 0.2],
                "five_hour": ["utilization": 0.3],
                "seven_day_oauth_apps": ["utilization": 0.9],
            ]
        ]
        let w = ClaudeQuotaProvider.parse(payload)
        XCTAssertEqual(w.map(\.label), ["Sesi 5 jam", "Mingguan", "Mingguan Opus"])
    }

    func testIgnoresUnknownBuckets() {
        XCTAssertTrue(ClaudeQuotaProvider.parse(["foo": ["utilization": 1]]).isEmpty)
        XCTAssertTrue(ClaudeQuotaProvider.parse("not a dict").isEmpty)
    }
}
