import XCTest
@testable import UsageBarKit

/// The three savers each keep their level somewhere different, and all three files are also
/// hand-edited, so the writers must preserve everything they do not own. Pinned here:
/// caveman's `off` is expressed by deleting the flag (never writing the literal), rtk's
/// `level` is only read inside `[awareness]`, and a missing table gets appended.
final class ToolSettingsTests: XCTestCase {

    private var home: URL!

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    // MARK: caveman

    func testCavemanRoundTripPreservesOtherKeys() throws {
        let url = ToolSettings.cavemanConfigURL(home: home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(#"{"defaultMode":"lite","theme":"dark"}"#.utf8).write(to: url)

        XCTAssertEqual(ToolSettings.cavemanLevel(home: home), "lite")
        try ToolSettings.setCavemanLevel("ultra", home: home)

        XCTAssertEqual(ToolSettings.cavemanLevel(home: home), "ultra")
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(obj?["theme"] as? String, "dark")
        XCTAssertEqual(try String(contentsOf: ToolSettings.cavemanFlagURL(home: home), encoding: .utf8),
                       "ultra\n")
    }

    func testCavemanOffDeletesFlagInsteadOfWritingLiteral() throws {
        try ToolSettings.setCavemanLevel("full", home: home)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ToolSettings.cavemanFlagURL(home: home).path))

        try ToolSettings.setCavemanLevel("off", home: home)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ToolSettings.cavemanFlagURL(home: home).path))
        XCTAssertEqual(ToolSettings.cavemanLevel(home: home), "off")
    }

    // MARK: rtk

    func testRtkLevelIgnoresOtherTables() {
        let toml = """
        [display]
        level = "wrong"

        [awareness]
        level = "high"
        """
        XCTAssertEqual(ToolSettings.rtkLevel(inTOML: toml), "high")
    }

    func testRtkSettingReplacesInPlaceAndKeepsRest() {
        let toml = "[tracking]\nenabled = true\n\n[awareness]\nlevel = \"default\"\n"
        let out = ToolSettings.rtkSetting("full", inTOML: toml)
        XCTAssertEqual(out, "[tracking]\nenabled = true\n\n[awareness]\nlevel = \"full\"\n")
    }

    func testRtkSettingAppendsMissingTable() {
        let out = ToolSettings.rtkSetting("high", inTOML: "[display]\ncolors = true")
        XCTAssertTrue(out.hasSuffix("[display]\ncolors = true\n\n[awareness]\nlevel = \"high\"\n"))
    }

    func testRtkRoundTripOnDisk() throws {
        let url = ToolSettings.rtkConfigURL(home: home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("[tracking]\nenabled = true\n\n[awareness]\nlevel = \"default\"\n".utf8).write(to: url)

        XCTAssertEqual(ToolSettings.rtkLevel(home: home), "default")
        try ToolSettings.setRtkLevel("full", home: home)
        XCTAssertEqual(ToolSettings.rtkLevel(home: home), "full")

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("[tracking]\nenabled = true"))
    }

    // MARK: levels

    func testHeadroomSchemaPrefersEffectiveValue() {
        let json = Data("""
        {"fields":[{"key":"other","value":"x"},
                   {"key":"savings_profile","value":"coding","stored":"balanced","default":"coding"}]}
        """.utf8)
        XCTAssertEqual(ToolSettings.headroomProfile(fromSchema: json), "coding")
    }

    func testHeadroomSchemaFallsBackWhenFieldMissing() {
        XCTAssertNil(ToolSettings.headroomProfile(fromSchema: Data(#"{"fields":[]}"#.utf8)))
        XCTAssertNil(ToolSettings.headroomProfile(fromSchema: Data("bukan json".utf8)))
    }

    func testLevelTablesCoverEveryToolValue() {
        XCTAssertEqual(ToolSettings.cavemanLevels.map(\.id), ["lite", "full", "ultra", "off"])
        XCTAssertEqual(ToolSettings.rtkLevels.map(\.id), ["default", "high", "full"])
        XCTAssertEqual(ToolSettings.headroomLevels.map(\.id), ["coding", "balanced", "agent-90"])
    }
}
