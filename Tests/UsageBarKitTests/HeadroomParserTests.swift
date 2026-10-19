import XCTest
@testable import UsageBarKit

/// headroom ships two shapes for the same numbers: `proxy_savings.json` puts `lifetime` at
/// the top level, `/stats` nests it under `persistent_savings` and adds measured cost. Both
/// must land on the same fields — the card would otherwise show zeros whenever the proxy is
/// down (file path) or exaggerate (live path only reading one layer).
final class HeadroomParserTests: XCTestCase {

    private func data(_ json: String) -> Data { Data(json.utf8) }

    func testFileShape() throws {
        let json = """
        {
          "schema_version": 6,
          "lifetime": {
            "requests": 21717,
            "tokens_saved": 124406997,
            "compression_savings_usd": 445.742463,
            "tool_tokens_saved": 111272038,
            "tool_schema_savings_usd": 69.256526,
            "total_input_tokens": 2966930102,
            "total_input_cost_usd": 7557.175131
          },
          "display_session": {
            "requests": 872,
            "tokens_saved": 1934894,
            "compression_savings_usd": 16.835153,
            "tool_tokens_saved": 6116808,
            "tool_schema_savings_usd": 10.999227,
            "savings_percent": 4.09,
            "started_at": "2026-10-18T07:44:53Z",
            "last_activity_at": "2026-10-18T09:43:59Z"
          },
          "co2": {"co2_saved_g": 9958.37888}
        }
        """
        let h = try XCTUnwrap(Headroom.parse(data: data(json)))
        XCTAssertEqual(h.requests, 21717)
        XCTAssertEqual(h.tokensRemoved, 124406997)
        XCTAssertEqual(h.toolTokensSaved, 111272038)
        XCTAssertEqual(h.tokensSavedAll, 124406997 + 111272038)
        XCTAssertEqual(h.savedUSD, 445.742463 + 69.256526, accuracy: 0.0001)
        XCTAssertEqual(h.sessionTokensSaved, 1934894 + 6116808)
        XCTAssertEqual(h.sessionRequests, 872)
        XCTAssertEqual(h.sessionPct, 4.09, accuracy: 0.001)
        XCTAssertNotNil(h.lastActivity)
        // The file carries no cost view, so the ratio falls back to saved/(cost+saved).
        XCTAssertGreaterThan(h.savingsPct, 0)
        // `isRunning` falls back to "wrote something recently" when /stats is unreachable;
        // the fixture's timestamp is in the past, so this only asserts it does not crash.
        XCTAssertNotNil(h.lastActivity)
    }

    func testStatsShape() throws {
        let json = """
        {
          "summary": {
            "mode": "cache",
            "api_requests": 20360,
            "compression": {
              "requests_compressed": 6631,
              "avg_compression_pct": 6.3,
              "total_tokens_removed": 116452927,
              "tool_schema_tokens_saved": 109940143,
              "total_tokens_saved_all_layers": 226393070,
              "total_tokens_before": 3093864264
            },
            "cost": {
              "without_headroom_usd": 635.57,
              "with_headroom_usd": 534.72,
              "total_saved_usd": 100.85,
              "savings_pct": 15.9
            }
          },
          "persistent_savings": {
            "lifetime": {"requests": 21717, "tokens_saved": 124406997, "tool_tokens_saved": 111272038},
            "display_session": {"requests": 899, "tokens_saved": 2007633,
                                "tool_tokens_saved": 6116808, "savings_percent": 4.09}
          }
        }
        """
        let h = try XCTUnwrap(Headroom.parse(data: data(json)))
        XCTAssertEqual(h.mode, "cache")
        XCTAssertTrue(h.reachable)
        XCTAssertTrue(h.isRunning)
        XCTAssertEqual(h.requestsCompressed, 6631)
        XCTAssertEqual(h.avgCompressionPct, 6.3, accuracy: 0.001)
        // The all-layers figure from /stats wins: it is the measured total.
        XCTAssertEqual(h.tokensSavedAll, 226393070)
        XCTAssertEqual(h.savedUSD, 100.85, accuracy: 0.001)
        XCTAssertEqual(h.savingsPct, 15.9, accuracy: 0.001)
        XCTAssertEqual(h.sessionTokensSaved, 2007633 + 6116808)
    }

    func testGarbageDoesNotCrash() {
        XCTAssertNil(Headroom.parse(data: data("not json")))
        let empty = Headroom.parse(data: data("{}"))
        XCTAssertEqual(empty?.requests, 0)
        XCTAssertEqual(empty?.savingsPct, 0)
    }
}
