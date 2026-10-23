import XCTest
@testable import UsageBarKit

final class IdleTyperTests: XCTestCase {
    private let words = ["idle", "siap"]

    func testTypesForwardThenHoldsThenDeletes() {
        // "idle": 4 type frames, 10 hold frames, 4 delete frames, 2 idle frames.
        XCTAssertEqual(IdleTyper.state(words: words, frame: 0).text, "")
        XCTAssertEqual(IdleTyper.state(words: words, frame: 1).text, "i")
        XCTAssertEqual(IdleTyper.state(words: words, frame: 3).text, "idl")
        XCTAssertEqual(IdleTyper.state(words: words, frame: 4).text, "idle")
        XCTAssertEqual(IdleTyper.state(words: words, frame: 13).text, "idle")
        XCTAssertEqual(IdleTyper.state(words: words, frame: 15).text, "idl")
    }

    func testTypingFlagIsSolidOnlyWhileHolding() {
        XCTAssertTrue(IdleTyper.state(words: words, frame: 2).typing)
        XCTAssertFalse(IdleTyper.state(words: words, frame: 8).typing)
        XCTAssertTrue(IdleTyper.state(words: words, frame: 16).typing)
    }

    func testSecondWordStartsAfterFirstCycle() {
        // First cycle = 4*2 + 10 + 2 = 20 frames.
        XCTAssertEqual(IdleTyper.state(words: words, frame: 20).text, "")
        XCTAssertEqual(IdleTyper.state(words: words, frame: 22).text, "si")
    }

    func testEmptyListNeverCrashes() {
        XCTAssertEqual(IdleTyper.state(words: [], frame: 99).text, "")
    }

    func testFramePastSequenceWrapsToFirstWord() {
        // Beyond every cycle: hold the first word rather than blank the strip.
        XCTAssertEqual(IdleTyper.state(words: words, frame: 500).text, "idle")
    }
}
