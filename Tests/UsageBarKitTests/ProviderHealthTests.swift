import XCTest
@testable import UsageBarKit

/// The menu bar dot and the card badge are driven purely by this enum, so the mapping from
/// state to visible text is what users actually see. Healthy states must stay silent —
/// a badge on every card is noise, not a warning.
final class ProviderHealthTests: XCTestCase {

    func testHealthyAndUnknownShowNothing() {
        XCTAssertNil(ProviderHealth.live.badge)
        XCTAssertNil(ProviderHealth.unknown.badge)
        XCTAssertFalse(ProviderHealth.live.isDown)
        XCTAssertTrue(ProviderHealth.live.isLive)
    }

    func testStaleKeepsNumbersButFlagsThem() {
        let stale = ProviderHealth.stale("pakai data lokal")
        XCTAssertEqual(stale.badge, "data lama · pakai data lokal")
        XCTAssertFalse(stale.isDown, "stale numbers are still real numbers: never treat as dead")
    }

    func testDownAlwaysHasAVisibleLabel() {
        let down = ProviderHealth.down("401 Unauthorized")
        XCTAssertEqual(down.badge, "401 Unauthorized")
        XCTAssertTrue(down.isDown)
        // An empty reason must not collapse the badge into an invisible capsule.
        XCTAssertEqual(ProviderHealth.down("").badge, "tidak aktif")
    }
}
