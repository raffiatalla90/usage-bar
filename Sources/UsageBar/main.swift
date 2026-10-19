import Foundation
import AppKit
import UsageBarKit

// Entry point. CLI flags are handled before the app starts, so a headless invocation
// can't hang waiting for a run loop.
let args = CommandLine.arguments

if args.contains("--set-key") {
    let key = args.drop { $0 != "--set-key" }.dropFirst().first ?? ""
    do {
        try KeyStore.setKey(key)
        print("key saved to Keychain (\(key.count) chars)")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("failed: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

if args.contains("--set-account-key") {
    let key = args.drop { $0 != "--set-account-key" }.dropFirst().first ?? ""
    do {
        try KeyStore.setAccountKey(key)
        print("account key saved to Keychain (\(key.count) chars)")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("failed: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

if args.contains("--clear-key") {
    KeyStore.clearKey()
    print("key cleared")
    exit(0)
}

if args.contains("--render-notch") {
    let path = args.drop(while: { $0 != "--render-notch" }).dropFirst().first ?? "/tmp/notch.png"
    MainActor.assumeIsolated { Renderer.renderNotch(to: path) }
}

if args.contains("--render-shot") {
    let path = args.drop(while: { $0 != "--render-shot" }).dropFirst().first ?? "/tmp/usagebar-shot.png"
    let caption = args.drop(while: { $0 != "--caption" }).dropFirst().first ?? "Pantau tanpa buka."
    MainActor.assumeIsolated { Renderer.renderShot(to: path, caption: caption) }
}

if args.contains("--save-shot") {
    MainActor.assumeIsolated {
        let store = UsageStore()
        var done = false
        Task { @MainActor in
            store.range = .last30
            await store.refresh()
            let data = MarketingShotExporter.data(from: store)
            if let p = MarketingShotExporter.save(data, caption: "Pantau tanpa buka.") {
                print("saved \(p)")
            } else {
                print("save failed")
            }
            done = true
        }
        while !done { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        exit(0)
    }
}

if args.contains("--render") {
    let path = args.drop(while: { $0 != "--render" }).dropFirst().first ?? "/tmp/usagebar.png"
    let rangeArg = args.drop(while: { $0 != "--dump" }).dropFirst().first
    let pageArg = args.drop(while: { $0 != "--page" }).dropFirst().first
    MainActor.assumeIsolated {
        Renderer.render(to: path,
                        range: rangeArg.flatMap(TimeRange.init(rawValue:)) ?? .last30,
                        page: pageArg.flatMap(Page.init(rawValue:)))
    }
}

if let i = args.firstIndex(of: "--dump") {
    let range = args.count > i + 1 ? (TimeRange(rawValue: args[i + 1]) ?? .last30) : .last30
    CLI.dump(range: range)
}

// `main.swift` is top-level code, which is nonisolated; hop to the main actor for AppKit.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    delegate.verifyMode = args.contains("--verify")
    delegate.notchVerifyMode = args.contains("--notch-verify")
    app.delegate = delegate
    app.run()
}
