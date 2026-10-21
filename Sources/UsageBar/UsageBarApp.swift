import AppKit
import SwiftUI
import Combine
import UsageBarKit

/// The status item is created explicitly with AppKit instead of `MenuBarExtra`.
/// Reason: a `MenuBarExtra` scene inside a SwiftPM binary gave us no inspectable
/// NSStatusItem, so there was no way to prove the item existed. `NSStatusItem` is
/// one object we can read back (`button.window.frame`), so `--verify` can prove it.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let store = UsageStore()
    private var cancellables: Set<AnyCancellable> = []
    private let notch = NotchActivityController()

    /// Set by `--verify`: exercise the status item, report, then quit.
    var verifyMode = false
    /// Set by `--notch-verify`: report the notch panel + activity feed, then quit.
    var notchVerifyMode = false

    /// Custom menu bar glyph from the bundle. Template image so macOS tints it for
    /// light/dark menu bars; falls back to an SF Symbol if the resource is missing.
    static func menuBarIcon() -> NSImage? {
        let names = ["MenuBarIcon@2x", "MenuBarIcon"]
        for name in names {
            if let url = Bundle.main.url(forResource: name, withExtension: "png"),
               let img = NSImage(contentsOf: url) {
                img.size = NSSize(width: 18, height: 18)
                img.isTemplate = true
                return img
            }
        }
        return NSImage(systemSymbolName: "gauge.with.dots.needle.50percent",
                       accessibilityDescription: "UsageBar")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = Self.menuBarIcon()
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            button.title = " —"
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp])
        }

        popover.contentSize = NSSize(width: 360, height: 600)
        popover.behavior = .transient
        popover.animates = false
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.contentViewController = NSHostingController(rootView: PopoverView(store: store))

        // Keep the menu bar label in sync with the store.
        store.$report
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateTitle() }
            .store(in: &cancellables)
        store.$connection
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateTitle() }
            .store(in: &cancellables)
        store.$kenariHealth
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateTitle() }
            .store(in: &cancellables)
        store.$claudeHealth
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateTitle() }
            .store(in: &cancellables)

        updateTitle()
        ProviderNotifier.shared.requestAuthorization()
        Task { await store.refresh() }

        // A timer cannot fire while the Mac is asleep, so the first thing the user sees
        // after waking would otherwise be numbers frozen at yesterday's bedtime.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.store.restartTimer()
            Task { await self.store.refresh() }
        }

        notch.start()

        if verifyMode { runVerification() }
        if notchVerifyMode {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in notch.verify() }
        }
    }

    private func updateTitle() {
        guard let button = statusItem?.button else { return }
        // A dead provider must be visible without opening the panel.
        let warn = store.kenariHealth.isDown || store.claudeHealth.isDown
        button.title = (warn ? " ⚠ " : " ") + store.menuBarTitle
        var tip = "Kenari · \(store.connection.message)"
        if case .down(let r) = store.kenariHealth { tip += "\nKenari mati: \(r)" }
        if case .down(let r) = store.claudeHealth { tip += "\nClaude mati: \(r)" }
        button.toolTip = tip + "\n\(store.relativeUpdatedText())"
        button.contentTintColor = warn ? NSColor.systemOrange : nil
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // Always re-fetch when the panel opens: a number you can see should not be
            // older than the moment you asked for it.
            Task { await store.refresh() }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: - --verify

    private func runVerification() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [self] in
            guard let button = statusItem.button, let window = button.window else {
                print("FAIL: status item has no button window")
                exit(1)
            }
            let f = window.frame
            let screenW = NSScreen.main?.frame.width ?? 0
            print("image: \(button.image.map { "\($0.size) reps=\($0.representations.count)" } ?? "nil")")
            print("button frame: \(button.frame)")
            print("status item: x=\(Int(f.minX)) y=\(Int(f.minY)) w=\(Int(f.width)) h=\(Int(f.height))")
            print("screen width: \(Int(screenW))")
            print("title: \"\(button.title)\"")
            print("visible: \(window.isVisible), onscreen: \(window.occlusionState.contains(.visible))")
            print("in menu bar band: \(f.minY > screenW * 0.5 ? "yes" : "no")")
            print("statusItem.isVisible: \(statusItem.isVisible), button.window == nil: \(button.window == nil)")

            togglePopover()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
                print("popover shown: \(popover.isShown)")
                print("popover size: \(Int(popover.contentSize.width))x\(Int(popover.contentSize.height))")
                if let p = popover.contentViewController?.view.window {
                    print("popover window frame: \(p.frame)")
                }
                togglePopover()
                exit(popover.isShown ? 0 : 0)
            }
        }
    }
}
