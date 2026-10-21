import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

/// One macOS notification per state change, never one per refresh tick.
/// Only fires when the app runs from a bundle: an unbundled `swift run` has no
/// notification identity, and the render/verify modes must stay silent.
public final class ProviderNotifier: @unchecked Sendable {
    public static let shared = ProviderNotifier()

    private var authorized = false
    private var lastSignature = ""

    public func requestAuthorization() {
        #if canImport(UserNotifications)
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] ok, _ in
            self?.authorized = ok
        }
        #endif
    }

    /// `failures` maps provider name -> reason. Empty means everything is healthy again.
    public func report(failures: [String: String]) {
        #if canImport(UserNotifications)
        let names = failures.keys.sorted()
        let signature = names.joined(separator: ",")
        guard signature != lastSignature else { return }
        let previous = lastSignature
        lastSignature = signature
        guard authorized, Bundle.main.bundleIdentifier != nil else { return }
        if names.isEmpty {
            guard !previous.isEmpty else { return }
            post(title: "Semua provider aktif lagi",
                 body: previous.split(separator: ",").joined(separator: " & ") + " sudah bisa dibaca.")
        } else {
            let reasons = names.compactMap { n in failures[n].map { "\(n): \($0)" } }
            post(title: "\(names.joined(separator: " & ")) tidak aktif",
                 body: reasons.joined(separator: " · "))
        }
        #endif
    }

    #if canImport(UserNotifications)
    private func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: "usagebar.\(title.hashValue)",
                                           content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
    #endif
}
