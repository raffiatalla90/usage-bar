import Foundation
import UsageBarKit

/// Headless reporting: `UsageBar --dump [today|yesterday|last30]`.
/// Uses the same source precedence as the menu bar: Kenari remote when it has traffic for
/// the range, otherwise the 9router local gateway, otherwise OpenCode's own store.
enum CLI {
    static func dump(range: TimeRange) -> Never {
        let sem = DispatchSemaphore(value: 0)
        Task {
            var account = AccountInfo()
            var report: UsageReport?
            var notes: [String] = []

            if let key = KeyStore.key() {
                do {
                    let r = try await KenariProvider(
                        config: .init(apiKey: key, accountKey: KeyStore.accountKey())
                    ).fetch(range: range)
                    account = r.account
                    report = r.report
                    notes.append("kenari: ok")
                } catch {
                    notes.append("kenari: \(error.localizedDescription)")
                }
            } else {
                notes.append("kenari: no API key")
            }

            var local: UsageReport?
            do {
                local = try NineRouterProvider(config: NineRouterProvider.defaultConfig).report(range: range)
            } catch {
                notes.append("9router: \(error.localizedDescription)")
            }
            if let local, local.totals.requests > 0 { report = local }
            else if report == nil {
                do {
                    report = try OpenCodeProvider(config: OpenCodeProvider.defaultConfig).report(range: range)
                } catch {
                    notes.append("opencode: \(error.localizedDescription)")
                }
            }

            guard let report else {
                print("no data — \(notes.joined(separator: "; "))")
                sem.signal(); exit(2)
            }

            print("source: \(report.source.label)")
            print("range: \(range.label)")
            print("requests: \(report.totals.requests)")
            print("tokens in/out/cacheRead: \(report.totals.inputTokens) / \(report.totals.outputTokens) / \(report.totals.cacheReadTokens)")
            print("cost: \(Money.idr(micro: report.totals.costMicroIDR))")
            if let b = account.availableMicroIDR ?? account.balanceMicroIDR {
                print("balance: \(Money.idr(micro: b))")
            } else {
                print("balance: unavailable (restricted key)")
            }
            if let plan = account.planName { print("plan: \(plan)") }
            if let w = account.weeklyRemaining {
                print("weekly remaining: \(Int((w * 100).rounded()))%  resets \(account.weeklyResetsAt.map { "\($0)" } ?? "—")")
            }
            if let m = account.monthlyRemaining {
                print("monthly remaining: \(Int((m * 100).rounded()))%  resets \(account.monthlyResetsAt.map { "\($0)" } ?? "—")")
            }
            if let limit = account.webSearchLimit {
                print("web search: \(limit - (account.webSearchUsed ?? 0))/\(limit) left today")
            }
            if let payg = account.paygCostTodayMicroIDR { print("payg today: \(Money.idr(micro: payg))") }
            do {
                let claude = try ClaudeCodeProvider(config: ClaudeCodeProvider.defaultConfig).report(range: range)
                print("claude code: \(claude.totals.requests) req, in \(claude.totals.inputTokens) out \(claude.totals.outputTokens) total \(claude.totals.inputTokens + claude.totals.outputTokens)")
                for m in claude.models.prefix(4) { print("  claude/\(m.model) req=\(m.requests) tok=\(m.totalTokens)") }
            } catch {
                print("claude code: \(error.localizedDescription)")
            }
            print("models:")
            for m in report.models.prefix(12) {
                print("  \(m.model)  req=\(m.requests)  tok=\(m.totalTokens)  cost=\(Money.idr(micro: m.costMicroIDR))")
            }
            print("daily points: \(report.daily.count)")
            if let peak = report.daily.max(by: { $0.requests < $1.requests }) {
                print("busiest day: \(DayKey.string(peak.date)) req=\(peak.requests)")
            }
            if !notes.isEmpty { print("notes: \(notes.joined(separator: "; "))") }
            sem.signal(); exit(0)
        }
        sem.wait()
        exit(2)
    }
}
