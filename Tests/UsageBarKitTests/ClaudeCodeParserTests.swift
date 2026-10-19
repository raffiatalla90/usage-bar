import XCTest
@testable import UsageBarKit

final class ClaudeCodeParserTests: XCTestCase {
    func testGuardByGuard() throws {
        let files = try ClaudeCodeProvider.jsonlFiles(under: ClaudeCodeProvider.defaultConfig.projectsURL)
        var totLines = 0, totAssistant = 0, totUsage = 0
        for url in files {
            let data = try FileHandle(forReadingFrom: url).readToEnd()!
            let lines = data.split(separator: UInt8(ascii: "\n"))
            totLines += lines.count
            for line in lines {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
                guard (obj["type"] as? String) == "assistant" else { continue }
                totAssistant += 1
                if let msg = obj["message"] as? [String: Any], msg["usage"] is [String: Any] { totUsage += 1 }
            }
        }
        print("files=\(files.count) lines=\(totLines) assistant=\(totAssistant) usage=\(totUsage)")
        let agg = ClaudeCodeProvider.aggregate(url: files[0])
        print("first file agg days=\(agg.count) size=\(files[0].lastPathComponent)")
        XCTAssertGreaterThan(totUsage, 0)
    }
}
