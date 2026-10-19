import CoreGraphics
import Foundation

// Dumps every window with its onscreen flag, optionally filtered by owner name.
let filter = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : nil
guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
    print("no window list"); exit(1)
}
for w in list {
    let owner = (w[kCGWindowOwnerName as String] as? String) ?? "?"
    if let f = filter, !owner.localizedCaseInsensitiveContains(f) { continue }
    let layer = (w[kCGWindowLayer as String] as? Int) ?? -1
    let b = (w[kCGWindowBounds as String] as? [String: Any]) ?? [:]
    let onscreen = (w[kCGWindowIsOnscreen as String] as? Bool) ?? false
    let alpha = (w[kCGWindowAlpha as String] as? Double) ?? -1
    print("owner=\(owner) layer=\(layer) bounds=\(b) onscreen=\(onscreen) alpha=\(alpha)")
}
