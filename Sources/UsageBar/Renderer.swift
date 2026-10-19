import SwiftUI
import AppKit
import UsageBarKit

/// Renders the popover to a PNG without showing a window, so the layout can be reviewed
/// on machines where Screen Recording permission is not granted.
///
/// `store.refresh()` is `@MainActor`, so the main thread must keep pumping the run loop —
/// blocking it on a semaphore deadlocks the render task.
@MainActor
enum Renderer {
    /// Renders the notch panel (pill + expanded list) so the layout can be eyeballed without
    /// Screen Recording permission.
    static func renderNotch(to path: String) -> Never {
        let watcher = ActivityWatcher()
        watcher.refresh()
        let items = watcher.items
        var images: [NSImage] = []
        for expanded in [false, true] {
            let w = expanded ? 420.0 : 313.0
            let h = expanded ? 368.0 : 34.0
            let probe = watcher
            let view = NotchView(watcher: probe, toggle: {}, forceExpanded: expanded,
                                 notchWidth: 185, notchHeight: 34)
                .frame(width: w, height: h)
                .background(Color.black)
                .environment(\.colorScheme, .dark)
            let r = ImageRenderer(content: view)
            r.scale = 2
            if let img = r.nsImage { images.append(img) }
        }
        _ = items
        for (i, img) in images.enumerated() {
            guard let tiff = img.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { continue }
            let p = path.replacingOccurrences(of: ".png", with: "_\(i).png")
            try? png.write(to: URL(fileURLWithPath: p))
            print("wrote \(p) \(Int(img.size.width))x\(Int(img.size.height))")
        }
        exit(0)
    }

    static func render(to path: String, range: TimeRange, page: Page? = nil) -> Never {
        var done = false
        Task { @MainActor in
            let store = UsageStore()
            store.range = range
            await store.refresh()
            let view = PopoverView(store: store, scrolling: false, interactive: false, forcePage: page)
                .frame(width: 360)
                .background(Color(red: 0.10, green: 0.10, blue: 0.11))
                .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let img = renderer.nsImage,
               let tiff = img.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
                print("wrote \(path) \(Int(img.size.width))x\(Int(img.size.height))")
            } else {
                print("render failed")
            }
            done = true
        }
        while !done {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        exit(0)
    }
}
