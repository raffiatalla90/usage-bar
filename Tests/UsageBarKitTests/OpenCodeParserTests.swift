import XCTest
@testable import UsageBarKit

final class OpenCodeParserTests: XCTestCase {

    // Fixtures mirror the real `message.data` JSON shape observed in
    // ~/.local/share/opencode/opencode.db (2026-10-18).

    private func assistant(_ provider: String, _ model: String,
                           input: Int, output: Int,
                           cacheRead: Int = 0, cacheWrite: Int = 0,
                           cost: Double = 0, error: Bool = false) -> Data {
        var obj: [String: Any] = [
            "role": "assistant",
            "providerID": provider,
            "modelID": model,
            "cost": cost,
            "tokens": [
                "input": input, "output": output, "reasoning": 0,
                "cache": ["read": cacheRead, "write": cacheWrite],
            ],
        ]
        if error { obj["error"] = ["name": "APIError", "data": ["message": "401"]] }
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    func testKenariModelPrefixIsAccepted() {
        let data = assistant("kenari", "glm-5-2", input: 100, output: 20)
        XCTAssertEqual(OpenCodeProvider.kenariBucketKey(data: data, kenariProviderIDs: ["kenari"]), "kenari/glm-5-2")
    }

    /// The real setup: Kenari is reached through the local 9router gateway, so providerID is
    /// `9router` while the model is still `kenari/<model>`. That must count as Kenari.
    func testKenariModelPrefixInModelIDWinsEvenWithOtherProvider() {
        let data = assistant("9router", "kenari/deepseek-v4-1-flash", input: 10, output: 1)
        XCTAssertEqual(OpenCodeProvider.kenariBucketKey(data: data, kenariProviderIDs: ["kenari"]),
                       "9router/kenari/deepseek-v4-1-flash")
    }

    func testNonKenariProviderIsSkipped() {
        let data = assistant("9router", "gratisan", input: 10, output: 1)
        XCTAssertNil(OpenCodeProvider.kenariBucketKey(data: data, kenariProviderIDs: ["kenari"]))
    }

    func testUserRoleIsSkipped() {
        let data = try! JSONSerialization.data(withJSONObject: ["role": "user", "modelID": "kenari/x"])
        XCTAssertNil(OpenCodeProvider.kenariBucketKey(data: data, kenariProviderIDs: ["kenari"]))
    }

    func testTokenCounts() {
        let data = assistant("kenari", "glm-5-2", input: 1234, output: 567, cacheRead: 89, cacheWrite: 7)
        let b = OpenCodeProvider.bucket(from: data)
        XCTAssertEqual(b?.input, 1234)
        XCTAssertEqual(b?.output, 567)
        XCTAssertEqual(b?.cacheRead, 89)
        XCTAssertEqual(b?.cacheWrite, 7)
        XCTAssertEqual(b?.requests, 1)
    }

    func testErroredTurnWithNoTokensIsNotCounted() {
        let data = assistant("kenari", "glm-5-2", input: 0, output: 0, error: true)
        XCTAssertNil(OpenCodeProvider.bucket(from: data))
    }

    func testLocalCostIsNilNotFakeZero() {
        let data = assistant("kenari", "glm-5-2", input: 10, output: 2, cost: 0.001)
        XCTAssertNil(OpenCodeProvider.bucket(from: data)?.costMicroIDR)
    }

    // MARK: - Tolerating junk

    func testMalformedRowDoesNotCrash() {
        let junk = Data("{not json".utf8)
        XCTAssertNil(OpenCodeProvider.kenariBucketKey(data: junk, kenariProviderIDs: ["kenari"]))
        XCTAssertNil(OpenCodeProvider.bucket(from: junk))
    }

    func testMissingTokensObjectDefaultsToZero() {
        let data = try! JSONSerialization.data(withJSONObject: ["role": "assistant", "providerID": "kenari", "modelID": "m"])
        let b = OpenCodeProvider.bucket(from: data)
        XCTAssertEqual(b?.input, 0)
        XCTAssertEqual(b?.requests, 1)
    }

    // MARK: - Money formatting

    func testMoneyFormatting() {
        XCTAssertEqual(Money.idr(micro: 12_345_000), "Rp 12,34")   // truncated, not rounded
        XCTAssertEqual(Money.idr(micro: 12_345_000_000), "Rp 12.345")
        XCTAssertEqual(Money.idr(micro: 1_234_567_000_000), "Rp 1.234.567")
        XCTAssertEqual(Money.idr(micro: 500_000), "Rp 0,5")
        XCTAssertEqual(Money.idr(micro: nil), "—")
        XCTAssertEqual(Money.tokens(999), "999")
        XCTAssertEqual(Money.tokens(1_500), "1.5K")
        XCTAssertEqual(Money.tokens(126_400_000), "126.4M")
    }

    func testRangeWindowIsMidnightAligned() {
        let cal = Calendar.current
        let (start, end) = TimeRange.today.window(now: Date(), calendar: cal)
        XCTAssertGreaterThan(end, start)
        XCTAssertEqual(Date(timeIntervalSince1970: Double(start)), cal.startOfDay(for: Date()))
    }

    // MARK: - Real database (skipped when absent)

    /// Proves the SQLite reader + aggregation work on the actual store, not just fixtures.
    func testRealDatabaseParsesKenariTraffic() throws {
        let db = OpenCodeProvider.defaultConfig.databaseURL
        try XCTSkipUnless(FileManager.default.fileExists(atPath: db.path), "opencode.db not on this machine")

        let cfg = OpenCodeProvider.Config(databaseURL: db, kenariProviderIDs: ["kenari"])
        let report = try OpenCodeProvider(config: cfg).report(range: .last30)
        XCTAssertGreaterThan(report.totals.requests, 0, "expected Kenari-routed traffic in the last 30 days")
        XCTAssertGreaterThan(report.totals.inputTokens, 0)
        XCTAssertFalse(report.models.isEmpty)
        XCTAssertEqual(report.daily.count, 30)
        XCTAssertTrue(report.models.contains { $0.model.hasPrefix("kenari/") },
                      "expected Kenari-routed models (providerID 9router + modelID kenari/*)")
        print("real db: \(report.totals.requests) req, \(report.totals.totalTokens) tok, \(report.models.count) models")
    }

    /// Regression: the old cache only rescanned two days, so a 30-day window lost older traffic.
    func testRealDatabaseLast30CoversOlderDays() throws {
        let db = OpenCodeProvider.defaultConfig.databaseURL
        try XCTSkipUnless(FileManager.default.fileExists(atPath: db.path), "opencode.db not on this machine")
        let report = try OpenCodeProvider(config: .init(databaseURL: db)).report(range: .last30)
        let activeDays = report.daily.filter { $0.requests > 0 }.count
        XCTAssertGreaterThan(activeDays, 1, "traffic should span more than today/yesterday")
    }
}
