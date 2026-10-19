import CoreGraphics
import Foundation

// Lists status-item-sized windows in the menu bar strip, to see whether UsageBar's
// NSStatusItem is actually laid out there (macOS hides items when the bar is full).
guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
    print("no window list"); exit(1)
}
var rows: [(Int, String, Int, Int, Int, Double)] = []
for w in list {
    let layer = (w[kCGWindowLayer as String] as? Int) ?? -1
    guard layer >= 0, layer <= 30 else { continue }
    let b = (w[kCGWindowBounds as String] as? [String: Any]) ?? [:]
    let y = (b["Y"] as? Double) ?? 999
    let h = (b["Height"] as? Double) ?? 0
    let x = (b["X"] as? Double) ?? 0
    let wd = (b["Width"] as? Double) ?? 0
    guard y < 40, h <= 40, wd > 8, wd < 260 else { continue }
    let owner = (w[kCGWindowOwnerName as String] as? String) ?? "?"
    let pid = (w[kCGWindowOwnerPID as String] as? Int) ?? 0
    rows.append((layer, owner, pid, Int(x), Int(wd), (w[kCGWindowAlpha as String] as? Double) ?? 0))
}
rows.sort { $0.3 < $1.3 }
print("status-item windows: \(rows.count)")
for r in rows { print("x=\(r.3) w=\(r.4) layer=\(r.0) alpha=\(r.5) owner=\(r.1) pid=\(r.2)") }
