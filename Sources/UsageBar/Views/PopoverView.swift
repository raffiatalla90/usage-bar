import SwiftUI
import UsageBarKit

// Visual language copied from the reference panel: near-black surface, one step lighter
// cards, capsule segmented control, thick donut with legend, quota rows with a marker,
// sparkline per provider, pill button in the footer.
enum Palette {
    static let panel  = Color(red: 0.10, green: 0.10, blue: 0.11)
    static let card   = Color(red: 0.16, green: 0.16, blue: 0.17)
    static let track  = Color.white.opacity(0.10)
    static let coral  = Color(red: 0.91, green: 0.44, blue: 0.30)
    static let jade   = Color(red: 0.07, green: 0.64, blue: 0.48)
    static let blue   = Color(red: 0.04, green: 0.52, blue: 1.00)
    static let slate  = Color(red: 0.58, green: 0.58, blue: 0.61)
    static let modelColors: [Color] = [coral, jade, blue, .purple, .yellow, .pink]
}

/// What the donut and the sparkline measure. Cost is only meaningful when something is
/// actually billed; every model on this Kenari key is free tier, so tokens is the default.
enum Measure: String, CaseIterable, Identifiable {
    case cost, tokens, requests
    var id: String { rawValue }
    var label: String {
        switch self {
        case .cost: return "Cost"
        case .tokens: return "Tokens"
        case .requests: return "Requests"
        }
    }
}

enum Page: String, CaseIterable, Identifiable {
    case usage, tokens, tools
    var id: String { rawValue }
    var label: String {
        switch self {
        case .usage: return "Kuota"
        case .tokens: return "Token"
        case .tools: return "Tool"
        }
    }
}

struct PopoverView: View {
    @ObservedObject var store: UsageStore
    /// `ScrollView` does not lay out its content under `ImageRenderer`, so the offscreen
    /// render path builds the same stack without the scroll container.
    var scrolling: Bool = true
    /// `Menu` labels do not rasterise under `ImageRenderer`; the offscreen render uses
    /// static labels instead so the layout can be inspected.
    var interactive: Bool = true
    @State private var now = Date()
    /// Result of the last "Simpan gambar promo" action, shown in the footer so the click has
    /// a visible effect inside the panel.
    @State private var shotPath: String?
    @State private var shotFailed = false
    @AppStorage("usagebar.measure") private var measureRaw = Measure.tokens.rawValue
    /// Which page the popover shows. Persisted so reopening lands where you left off.
    @AppStorage("usagebar.page") private var pageRaw = Page.usage.rawValue
    /// Offscreen render overrides the persisted page so each one can be inspected.
    var forcePage: Page? = nil
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var measure: Measure { Measure(rawValue: measureRaw) ?? .tokens }
    private var page: Page { forcePage ?? Page(rawValue: pageRaw) ?? .usage }

    var body: some View {
        VStack(spacing: 0) {
            header
            pageTabs
            if scrolling {
                ScrollView { content }.frame(maxHeight: 470)
            } else {
                content
            }
            footer
        }
        .frame(width: 360)
        .background(Palette.panel)
        .preferredColorScheme(.dark)
        .onReceive(tick) { now = $0 }
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .usage: sections
        case .tokens: TokenPage(store: store, interactive: interactive).padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 14)
        case .tools: ToolsPage(store: store).padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 14)
        }
    }

    private var pageTabs: some View {
        HStack(spacing: 2) {
            ForEach(Page.allCases) { p in
                let active = page == p
                Text(p.label)
                    .font(.system(size: 11, weight: active ? .semibold : .medium))
                    .foregroundStyle(active ? Color.white : Palette.slate)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(active ? Color.black.opacity(0.55) : Color.clear))
                    .contentShape(Capsule())
                    .onTapGesture { pageRaw = p.rawValue }
            }
        }
        .padding(3)
        .background(Capsule().fill(Palette.track))
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private var sections: some View {
        VStack(spacing: 14) {
            donutCard
            ForEach(store.providerCards) { card in
                providerCard(card)
            }
            if !store.sourceErrors.isEmpty { errors }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 14)
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 6) {
            if interactive {
                Menu {
                    ForEach(Measure.allCases) { m in
                        Button(m.label) { measureRaw = m.rawValue }
                    }
                } label: {
                    measureLabel
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            } else {
                measureLabel
            }

            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(Palette.slate)
                .help("Source: \(store.report?.source.label ?? "—") · \(store.connection.message)")

            Spacer()

            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .help(store.connection.message)

            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "square.on.square")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.slate)
            }
            .buttonStyle(.plain)
            .help("Refresh now")
            .disabled(store.isRefreshing)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var measureLabel: some View {
        HStack(spacing: 6) {
            Text(measure.label)
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(.white)
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.slate)
        }
    }

    private var statusColor: Color {
        switch store.connection {
        case .ok: return Palette.jade
        case .degraded: return Palette.coral
        case .failed: return .red
        case .unknown: return Palette.slate
        }
    }

    // MARK: donut + legend

    /// Donut and legend are built from one grouped list: each source keeps its own top
    /// models, and everything left over collapses into a single "Lainnya" slice, so the ring
    /// and the legend always add up to the same total.
    ///
    /// Claude used to be invisible here: the ring was built from the Kenari/9router report
    /// alone, so a machine running both subscriptions showed only Kenari models. The two
    /// sources are now merged, and each keeps at least one slice so the smaller one cannot be
    /// squeezed out by a top-4 cut.
    private var grouped: [(name: String, value: Int, color: Color)] {
        func value(_ m: ModelUsage) -> Int {
            switch measure {
            case .cost: return m.costMicroIDR ?? 0
            case .tokens: return m.totalTokens
            case .requests: return m.requests
            }
        }
        func rows(_ report: UsageReport?, colors: [Color]) -> [(name: String, value: Int, color: Color)] {
            guard let models = report?.models else { return [] }
            return models.map { (m: $0, v: value($0)) }.filter { $0.v > 0 }
                .sorted { $0.v > $1.v }
                .enumerated()
                .map { i, row in (row.m.displayName, row.v, colors[i % colors.count]) }
        }

        let claudeRows = rows(store.claudeReport, colors: [Palette.jade, Palette.blue])
        let kenariRows = rows(store.report, colors: [Palette.coral, .purple, .yellow, .pink])

        // Two per source, so both are always represented; the rest is one slice per source.
        let head = Array(claudeRows.prefix(2)) + Array(kenariRows.prefix(2))
        var restCount = 0
        var restSum = 0
        for row in claudeRows.dropFirst(2) + kenariRows.dropFirst(2) {
            restCount += 1
            restSum += row.value
        }
        guard restCount > 0 else { return head }
        return head + [("Lainnya (\(restCount))", restSum, Palette.slate)]
    }

    /// Donut centre and legend must describe the same number, so both come from the full
    /// model list of both sources rather than from the visible slice set.
    private var grandTotal: Int {
        func sum(_ report: UsageReport?) -> Int {
            guard let models = report?.models else { return 0 }
            return models.reduce(0) { acc, m in
                switch measure {
                case .cost: return acc + (m.costMicroIDR ?? 0)
                case .tokens: return acc + m.totalTokens
                case .requests: return acc + m.requests
                }
            }
        }
        return sum(store.report) + sum(store.claudeReport)
    }

    /// Claude's share is often under 1% of the ring (its input is small, its cache reads are
    /// excluded from `totalTokens`), so a slice that thin looks like a missing source. Say the
    /// percentage outright instead of letting the eye decide it is a bug.
    private var claudeShareNote: String? {
        guard measure == .tokens else { return nil }
        let claude = store.claudeReport?.totals.totalTokens ?? 0
        let total = grandTotal
        guard claude > 0, total > 0 else { return nil }
        let pct = Double(claude) / Double(total) * 100
        guard pct < 5 else { return nil }
        return String(format: "Claude %.1f%% dari total token · pilih Requests untuk porsi sebanding", pct)
    }

    private var donutCard: some View {
        let data = grouped
        return VStack(spacing: 14) {
            segmented
            HStack(spacing: 18) {
                DonutChart(slices: data.map { ($0.value, $0.color) }, lineWidth: 17)
                    .frame(width: 106, height: 106)
                    .overlay {
                        VStack(spacing: 1) {
                            Text(centerValue(grandTotal))
                                .font(.system(size: 20, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                            Text(centerCaption)
                                .font(.system(size: 10))
                                .foregroundStyle(Palette.slate)
                        }
                    }
                VStack(alignment: .leading, spacing: 9) {
                    if data.isEmpty {
                        Text("No usage in this window")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.slate)
                    }
                    ForEach(Array(data.prefix(5).enumerated()), id: \.offset) { _, s in
                        HStack(alignment: .top, spacing: 7) {
                            Circle().fill(s.color).frame(width: 8, height: 8)
                                .padding(.top, 4)
                            Text(s.name)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.white.opacity(0.9))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                            Text(shortValue(s.value))
                                .font(.system(size: 10, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(Palette.slate)
                                .padding(.top, 1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let note = claudeShareNote {
                Text(note)
                    .font(.system(size: 9))
                    .foregroundStyle(Palette.slate)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Palette.card))
    }

    private var segmented: some View {
        HStack(spacing: 2) {
            ForEach(TimeRange.allCases) { r in
                let active = store.range == r
                Text(r.label)
                    .font(.system(size: 12, weight: active ? .semibold : .medium))
                    .foregroundStyle(active ? Color.white : Palette.slate)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(active ? Color.black.opacity(0.55) : Color.clear))
                    .contentShape(Capsule())
                    .onTapGesture { store.range = r }
            }
        }
        .padding(3)
        .background(Capsule().fill(Palette.track))
    }

    private var centerCaption: String {
        switch measure {
        case .cost: return "rupiah"
        case .tokens: return "tokens"
        case .requests: return "requests"
        }
    }

    private func centerValue(_ total: Int) -> String {
        switch measure {
        case .cost: return Money.idr(micro: total).replacingOccurrences(of: "Rp ", with: "Rp")
        case .tokens: return Money.tokens(total)
        case .requests: return "\(total)"
        }
    }

    private func shortValue(_ v: Int) -> String {
        switch measure {
        case .cost: return Money.idr(micro: v)
        case .tokens: return Money.tokens(v)
        case .requests: return "\(v)"
        }
    }

    // MARK: provider card

    private func providerCard(_ card: ProviderQuota) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Image(systemName: card.symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(card.id == "claude" ? Palette.jade : Palette.coral)
                VStack(alignment: .leading, spacing: 1) {
                    Text(card.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(card.subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.slate)
                }
                Spacer()
            }

            ForEach(card.rows) { row in
                quotaRow(title: row.title, fraction: row.remaining,
                         left: row.valueText, rightTop: "", rightBottom: row.detail,
                         color: card.id == "claude" ? Palette.jade : Palette.blue,
                         leftEmphasis: true)
            }

            if let note = card.note {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.slate)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let foot = card.footnote {
                Text(foot)
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(Color.white.opacity(0.55))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Palette.card))
    }

    private func quotaRow(title: String, fraction: Double, left: String,
                          rightTop: String, rightBottom: String, color: Color,
                          leftEmphasis: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.85))
                Spacer()
                Text(left)
                    .font(.system(size: leftEmphasis ? 12 : 10, weight: leftEmphasis ? .semibold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(leftEmphasis ? Color.white : Palette.slate)
                if !rightTop.isEmpty {
                    Text(rightTop)
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.slate)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.track)
                    Capsule()
                        .fill(color)
                        .frame(width: max(3, geo.size.width * min(1, max(0, fraction))))
                }
            }
            .frame(height: 5)
            Text(rightBottom)
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(Palette.slate)
        }
    }

    // MARK: errors

    private var errors: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(store.sourceErrors.sorted(by: { $0.key < $1.key }), id: \.key) { key, msg in
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Palette.coral)
                    Text("\(key): \(msg)")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.slate)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.coral.opacity(0.10)))
    }

    // MARK: footer

    private var footer: some View {
        VStack(spacing: 0) {
            if let path = shotPath {
                shotBanner(path: path, ok: true)
            } else if shotFailed {
                shotBanner(path: nil, ok: false)
            }
            footerRow
        }
    }

    /// The save happens behind a transient popover, so the confirmation has to live here —
    /// a Finder window would dismiss the panel before the user could see it.
    private func shotBanner(path: String?, ok: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 9))
                .foregroundStyle(ok ? Palette.jade : Palette.coral)
            Text(ok ? "Tersimpan: \(path ?? "") · path disalin" : "Gagal menyimpan gambar")
                .font(.system(size: 9))
                .foregroundStyle(Color.white.opacity(0.75))
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Palette.card)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
        }
    }

    private var footerRow: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("UsageBar \(version)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.75))
                Text("Next update in \(nextUpdateText)")
                    .font(.system(size: 9))
                    .foregroundStyle(Palette.slate)
            }
            Spacer()
            Button { saveShot() } label: {
                Image(systemName: "camera")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 18)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.10)))
            }
            .buttonStyle(.plain)
            .help("Simpan gambar promo")
            if interactive {
                Menu {
                    Button("Refresh now") { Task { await store.refresh() } }
                    Divider()
                    Toggle("Launch at Login", isOn: Binding(
                        get: { store.launchAtLogin },
                        set: { store.launchAtLogin = $0 }
                    ))
                    Menu("Refresh every") {
                        ForEach(UsageStore.intervalChoices, id: \.self) { i in
                            Button("\(Int(i))s") { store.refreshInterval = i }
                        }
                    }
                    Divider()
                    Button("Quit UsageBar") { NSApplication.shared.terminate(nil) }
                } label: {
                    optionsLabel
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            } else {
                optionsLabel
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Palette.panel)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
        }
    }

    private var optionsLabel: some View {
        HStack(spacing: 4) {
            Text("Options").font(.system(size: 11, weight: .medium))
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.white.opacity(0.12)))
    }

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    /// Writes the hero shot and reports the result inline. Relying on Finder to reveal it was
    /// unreliable: this app is an `.accessory` process behind a transient popover, so activating
    /// Finder could close the popover before anything visibly happened.
    private func saveShot() {
        let data = MarketingShotExporter.data(from: store)
        let path = MarketingShotExporter.save(data, caption: "Pantau tanpa buka.")
        // App is a UIElement bundle with no console; a log line is the only way to tell
        // "clicked and failed" apart from "never clicked" after the fact.
        let log = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/UsageBar.log")
        let line = "\(Date()) saveShot -> \(path ?? "FAILED")\n"
        if let h = try? FileHandle(forWritingTo: log) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? line.write(to: log, atomically: true, encoding: .utf8)
        }
        if let path {
            shotPath = path
            shotFailed = false
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
        } else {
            shotPath = nil
            shotFailed = true
        }
    }

    private var nextUpdateText: String {
        let elapsed = now.timeIntervalSince(store.lastUpdated ?? now)
        let left = max(0, store.refreshInterval - elapsed)
        let m = Int(left) / 60, s = Int(left) % 60
        return m > 0 ? "\(m)m" : "\(s)s"
    }
}

// MARK: - Components

struct DonutChart: View {
    let slices: [(value: Int, color: Color)]
    var lineWidth: CGFloat = 18

    var body: some View {
        let total = max(1, slices.reduce(0) { $0 + $1.value })
        let gap = slices.count > 1 ? 0.006 : 0
        ZStack {
            Circle().stroke(Palette.track, lineWidth: lineWidth)
            var start = 0.0
            ForEach(Array(slices.enumerated()), id: \.offset) { _, s in
                let end = start + Double(s.value) / Double(total)
                Circle()
                    .trim(from: start + gap / 2, to: max(start + gap / 2, end - gap / 2))
                    .stroke(s.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
                let _ = start = end
            }
        }
    }
}
