import AppKit

// Probes menu bar capacity: adds a real NSStatusItem, waits a beat, then reports where
// AppKit laid it out. A frame pushed off-screen (x < 0 or x beyond the screen) means the
// menu bar is full and macOS is hiding items instead of drawing them.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
item.button?.title = "  probe  "

DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
    if let win = item.button?.window {
        let f = win.frame
        let screenW = NSScreen.main?.frame.width ?? 0
        print("status item frame: x=\(Int(f.minX)) y=\(Int(f.minY)) w=\(Int(f.width)) h=\(Int(f.height))")
        print("screen width: \(Int(screenW))")
        print("occlusion: \(win.occlusionState.contains(.visible) ? "visible" : "hidden")")
        print("isVisible: \(win.isVisible)")
        let offscreen = f.maxX > screenW || f.minX < 0 || f.width == 0
        print(offscreen ? "RESULT: overflow - menu bar is full, item pushed off-screen" : "RESULT: room available")
    } else {
        print("RESULT: no button window - status item not created")
    }
    NSStatusBar.system.removeStatusItem(item)
    exit(0)
}

app.run()
