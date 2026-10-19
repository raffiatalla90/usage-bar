import XCTest
@testable import UsageBarKit

/// The strip's live dot must reflect "agent is working", not "agent wrote a file".
final class ActivityTouchTests: XCTestCase {
    func testLastTouchIsRecentWhileAgentIsRunning() throws {
        // This machine has live Claude Code / OpenCode logs; on a clean machine the call is
        // simply nil and the assertion below is skipped.
        guard let touch = ActivityFeed.lastTouch() else {
            throw XCTSkip("no agent logs on this machine")
        }
        XCTAssertLessThan(touch, Date().addingTimeInterval(5), "mtime never in the future")
        XCTAssertGreaterThan(touch, Date().addingTimeInterval(-6 * 3600))
    }

    func testWindowFiltersOldTouches() {
        // A 1-second window cannot contain a log write older than a second.
        let tiny = ActivityFeed.lastTouch(within: 0.0001)
        if let tiny { XCTAssertGreaterThan(tiny, Date().addingTimeInterval(-1)) }
    }
}
