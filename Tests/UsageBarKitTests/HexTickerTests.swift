import XCTest
@testable import UsageBarKit

final class HexTickerTests: XCTestCase {
    func testLineIsDeterministicAndHex() {
        let a = HexTicker.line(frame: 42, count: 7)
        let b = HexTicker.line(frame: 42, count: 7)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 7)
        XCTAssertTrue(a.allSatisfy { "0123456789abcdef".contains($0) })
    }

    func testWindowSlidesOneGlyphPerFrame() {
        let f0 = HexTicker.line(frame: 0, count: 7)
        let f1 = HexTicker.line(frame: 1, count: 7)
        XCTAssertEqual(String(f0.dropFirst()), String(f1.dropLast()))
        XCTAssertNotEqual(f0, f1)
    }

    func testNegativeFrameClampsInsteadOfCrashing() {
        XCTAssertEqual(HexTicker.line(frame: -5, count: 4).count, 4)
    }

    func testZeroCountIsEmpty() {
        XCTAssertEqual(HexTicker.line(frame: 3, count: 0), "")
    }
}
