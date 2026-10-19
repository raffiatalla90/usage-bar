import Foundation
import Combine

@MainActor
public final class UsageStore: ObservableObject {
    // MARK: Published state
    @Published public private(set) var report: UsageReport?
    @Published public private(set) var claudeReport: UsageReport?
    @Published public private(set) var claudeQuota = ClaudeQuota()
    @Published public private(set) var account = AccountInfo()
    @Published public private(set) var connection: ConnectionState = .unknown
    @Published public private(set) var lastUpdated: Date?
    @Published public private(set) var sourceErrors: [String: String] = [:]   // source label -> message
    @Published public private(set) var isRefreshing = false
    /// Local context-saver status. Read from their own stores; no network.
    @Published public private(set) var rtk = RTKStats.empty
    @Published public private(set) var caveman = CavemanStatus.empty
    @Published public private(set) var headroom = HeadroomStats.empty

    @Published public var range: TimeRange {
        didSet { UserDefaults.standard.set(range.rawValue, forKey: Keys.range); Task { await refresh() } }
    }
    @Published public var refreshInterval: TimeInterval {
        didSet {
            UserDefaults.standard.set(refreshInterval, forKey: Keys.interval)
            restartTimer()
        }
    }
    @Published public var hasAPIKey: Bool = KeyStore.hasKey

    enum Keys {
        static let range = "usagebar.range"
        static let interval = "usagebar.refreshInterval"
        static let lastUpdated = "usagebar.lastUpdated"
    }

    private var timer: Timer?
    private let opencode = OpenCodeProvider(config: OpenCodeProvider.defaultConfig)
    private let router = NineRouterProvider(config: NineRouterProvider.defaultConfig)
    private let claude = ClaudeCodeProvider(config: ClaudeCodeProvider.defaultConfig)
    private let claudeQuotaProvider = ClaudeQuotaProvider()

    public static let intervalChoices: [TimeInterval] = [30, 60, 300, 900]

    public init() {
        let savedRange = UserDefaults.standard.string(forKey: Keys.range).flatMap(TimeRange.init(rawValue:))
        self.range = savedRange ?? .last30
        let savedInterval = UserDefaults.standard.double(forKey: Keys.interval)
        self.refreshInterval = savedInterval > 0 ? savedInterval : 60
        self.lastUpdated = UserDefaults.standard.object(forKey: Keys.lastUpdated) as? Date
        restartTimer()
        refreshLocalTools()
    }

    // MARK: Refresh

    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        sourceErrors = [:]
        var remoteError: String?
        var remoteReport: UsageReport?

        // 1) Kenari remote (authoritative: real billing numbers + plan quota)
        if let key = KeyStore.key() {
            do {
                let result = try await KenariProvider(
                    config: .init(apiKey: key, accountKey: KeyStore.accountKey())
                ).fetch(range: range)
                remoteReport = result.report
                account = result.account
                connection = .ok
            } catch {
                remoteError = error.localizedDescription
                sourceErrors["Kenari API"] = remoteError
            }
        } else {
            remoteError = "no API key"
            sourceErrors["Kenari API"] = "No API key saved"
        }

        // 2) 9router local — the gateway OpenCode actually uses for Kenari. The saved API key
        //    is a different (restricted) key than the one 9router routes with, so the remote
        //    endpoint reports 0 for recent days while real traffic exists locally. Prefer
        //    whichever source has traffic in the selected range.
        var localReport: UsageReport?
        do {
            localReport = try router.report(range: range)
        } catch {
            sourceErrors["9router local"] = error.localizedDescription
        }

        if let local = localReport, local.totals.requests > 0 {
            report = local
            connection = remoteError == nil ? .ok : .degraded(remoteError ?? "remote unavailable")
        } else if let remote = remoteReport {
            report = remote
        } else {
            // 3) OpenCode local fallback (works offline, no prices)
            do {
                report = try opencode.report(range: range)
                connection = remoteError == nil ? .ok : .degraded(remoteError ?? "remote unavailable")
            } catch {
                sourceErrors["OpenCode local"] = error.localizedDescription
                connection = .failed(remoteError ?? error.localizedDescription)
            }
        }

        // Claude Code is an independent source: its own provider card, never merged into Kenari.
        do {
            claudeReport = try claude.report(range: range)
        } catch {
            claudeReport = nil
            sourceErrors["Claude Code local"] = error.localizedDescription
        }
        // Subscription windows come from Anthropic's own usage endpoint; they are independent
        // of the selected range, so fetch them every refresh regardless of `range`.
        let fresh = await claudeQuotaProvider.fetch()
        // A transient 429 must not wipe numbers we already have: keep the last good windows
        // and surface the error beside them.
        if fresh.windows.isEmpty, !claudeQuota.windows.isEmpty {
            claudeQuota = ClaudeQuota(windows: claudeQuota.windows, error: fresh.error)
        } else {
            claudeQuota = fresh
        }

        touchUpdated()
        refreshLocalTools()
        await refreshHeadroom()
    }

    /// rtk, caveman and headroom are independent of the Kenari range, and cheap to read, so
    /// they are refreshed on the same tick rather than on a separate timer.
    public func refreshLocalTools() {
        rtk = LocalTools.rtk()
        caveman = LocalTools.caveman()
        headroom = Headroom.cached(into: headroom.reachable ? headroom : nil)
    }

    /// headroom's live numbers need its proxy to answer; keep the file-only value as fallback.
    public func refreshHeadroom() async {
        headroom = await Headroom.fetch()
    }

    private func touchUpdated() {
        lastUpdated = Date()
        UserDefaults.standard.set(lastUpdated, forKey: Keys.lastUpdated)
    }

    // MARK: Timer

    public func restartTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: Provider cards

    /// Provider blocks shown under the donut. Kenari first (billing authority), Claude Code second.
    public var providerCards: [ProviderQuota] { [kenariCard, claudeCard] }

    private var kenariCard: ProviderQuota {
        let a = account
        var rows: [QuotaRow] = []
        let planName = a.planName

        if let week = a.weeklyRemaining {
            rows.append(QuotaRow(
                title: "Kuota mingguan",
                valueText: "Sisa \(Int((week * 100).rounded()))%",
                detail: resetsText(a.weeklyResetsAt, prefix: "pulih dalam"),
                remaining: week))
        }
        if let month = a.monthlyRemaining {
            rows.append(QuotaRow(
                title: "Kuota bulanan",
                valueText: "Sisa \(Int((month * 100).rounded()))%",
                detail: resetsText(a.monthlyResetsAt, prefix: "pulih dalam"),
                remaining: month))
        }
        if let limit = a.webSearchLimit {
            let used = a.webSearchUsed ?? 0
            let left = max(0, limit - used)
            rows.append(QuotaRow(
                title: "Pencarian web",
                valueText: "Sisa \(left) dari \(limit)",
                detail: "pulih setiap hari 07.00 WIB",
                remaining: Double(left) / Double(max(1, limit))))
        }
        if let payg = a.paygCostTodayMicroIDR {
            rows.append(QuotaRow(
                title: "Dipotong dari saldo",
                valueText: Money.idr(micro: payg),
                detail: "PAYG dan pencarian web · hari ini",
                remaining: payg > 0 ? 0.15 : 1))
        }

        // Quota and balance need the account key; a restricted tool key only reads /v1/usage.
        // Say that plainly instead of showing zeros that look like real numbers.
        let note: String? = rows.isEmpty
            ? "Kuota paket butuh account key (kenari login). Jalankan: UsageBar --set-account-key <key>"
            : nil

        let subtitle: String
        if let planName { subtitle = "Paket \(planName)" }
        else if report?.source == .routerLocal { subtitle = "9router · trafik lokal" }
        else { subtitle = report?.source.label ?? "—" }

        return ProviderQuota(id: "kenari", name: "Kenari", subtitle: subtitle,
                             symbol: "bolt.horizontal.circle.fill",
                             rows: rows, note: note,
                             footnote: kenariFootnote)
    }

    private var kenariFootnote: String? {
        guard let t = report?.totals, t.requests > 0 else { return nil }
        let tokens = Money.tokens(t.inputTokens) + " in · " + Money.tokens(t.outputTokens) + " out"
        return "\(t.requests) request · \(tokens)"
    }

    private var claudeCard: ProviderQuota {
        // What the empty rows should say: a real credential problem, or just a failed fetch?
        let why: String = {
            guard let e = claudeQuota.error else { return "kuota belum terbaca" }
            if e.contains("401") || e.lowercased().contains("login") || e.contains("Token") {
                return "jalankan `claude` lalu /login"
            }
            return e
        }()
        // Quota windows exist even with no traffic in the selected range, so they win.
        guard let r = claudeReport, r.totals.requests > 0 else {
            var rows: [QuotaRow] = claudeQuota.windows.map { w in
                // Claude Code's own `/usage` reports *used*, so show used too — a "Sisa 4%"
                // next to the CLI's "98% used" reads like the two windows are swapped.
                let used = 1 - w.remaining
                return QuotaRow(title: w.label,
                                valueText: "Terpakai \(Int((used * 100).rounded()))%",
                                detail: resetsText(w.resetsAt, prefix: "pulih dalam"),
                                remaining: used)
            }
            if rows.isEmpty {
                rows = [
                    QuotaRow(title: "Kuota sesi 5 jam", valueText: "—",
                             detail: why, remaining: 0),
                    QuotaRow(title: "Kuota mingguan", valueText: "—",
                             detail: why, remaining: 0),
                ]
            }
            return ProviderQuota(
                id: "claude", name: "Claude Code", subtitle: "Langganan Claude",
                symbol: "terminal.fill", rows: rows,
                note: claudeQuota.windows.isEmpty
                    ? nil
                    : (claudeQuota.error ?? sourceErrors["Claude Code local"]))
        }
        let t = r.totals
        // Claude's limits are window-based (5-hour session + 7-day), not token budgets.
        // Show remaining per window; fall back to token totals when the usage endpoint is
        // unreachable (expired OAuth), so the card never goes blank.
        var rows: [QuotaRow] = []
        for w in claudeQuota.windows {
            let used = 1 - w.remaining
            rows.append(QuotaRow(
                title: w.label,
                valueText: "Terpakai \(Int((used * 100).rounded()))%",
                detail: resetsText(w.resetsAt, prefix: "pulih dalam"),
                remaining: used))
        }
        if rows.isEmpty {
            // No quota windows: say so instead of substituting token counts — the card is
            // about remaining allowance, and a token total reads like a quota that it isn't.
            rows = [
                QuotaRow(title: "Kuota sesi 5 jam", valueText: "—",
                         detail: why, remaining: 0),
                QuotaRow(title: "Kuota mingguan", valueText: "—",
                         detail: why, remaining: 0),
            ]
        }
        let topModel = r.models.first?.displayName ?? "—"
        return ProviderQuota(
            id: "claude", name: "Claude Code", subtitle: "Langganan Claude · \(topModel)",
            symbol: "terminal.fill", rows: rows,
            // Rows already carry the failure reason when they are empty; repeating it as a
            // note printed the same sentence three times.
            note: claudeQuota.windows.isEmpty ? nil : claudeQuota.error,
            footnote: "\(t.requests) request · \(Money.tokens(t.inputTokens)) in · \(Money.tokens(t.outputTokens)) out")
    }

    private func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    private func resetsText(_ date: Date?, prefix: String) -> String {
        guard let date else { return "waktu reset tidak tersedia" }
        let secs = Int(date.timeIntervalSinceNow)
        guard secs > 0 else { return "segera pulih" }
        return "\(prefix) \(Duration.id(secs))"
    }

    // MARK: Menu bar label

    public var menuBarTitle: String {
        guard let report else { return "—" }
        if let cost = report.totals.costMicroIDR, cost > 0 {
            return Money.idr(micro: cost).replacingOccurrences(of: "Rp ", with: "Rp")
        }
        // Everything on a free-tier Kenari key bills at Rp 0, so a cost label would read "Rp0".
        // Show what actually moved instead.
        if report.totals.totalTokens > 0 { return Money.tokens(report.totals.totalTokens) }
        return "\(report.totals.requests) req"
    }

    public func relativeUpdatedText(now: Date = Date()) -> String {
        guard let lastUpdated else { return "Never updated" }
        let secs = Int(now.timeIntervalSince(lastUpdated))
        if secs < 5 { return "Updated just now" }
        if secs < 60 { return "Updated \(secs) seconds ago" }
        let mins = secs / 60
        if mins < 60 { return "Updated \(mins) minute\(mins == 1 ? "" : "s") ago" }
        let hours = mins / 60
        return "Updated \(hours) hour\(hours == 1 ? "" : "s") ago"
    }

    public var launchAtLogin: Bool {
        get { LaunchAtLogin.isEnabled }
        set {
            do { try LaunchAtLogin.setEnabled(newValue) } catch {
                sourceErrors["Launch at Login"] = error.localizedDescription
            }
            objectWillChange.send()
        }
    }
}
