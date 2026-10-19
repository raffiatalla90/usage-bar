import SwiftUI
import UsageBarKit

// Minimal dark surface: near-black panel, translucent cards with a hairline border instead
// of a lighter fill, one accent per source, tabular digits everywhere numbers move.
enum Palette {
    static let panel  = Color(red: 0.055, green: 0.055, blue: 0.062)
    static let card   = Color.white.opacity(0.045)
    static let stroke = Color.white.opacity(0.075)
    static let track  = Color.white.opacity(0.08)
    static let coral  = Color(red: 0.96, green: 0.45, blue: 0.34)
    static let jade   = Color(red: 0.18, green: 0.80, blue: 0.60)
    static let blue   = Color(red: 0.29, green: 0.56, blue: 1.00)
    static let slate  = Color(red: 0.66, green: 0.66, blue: 0.70)
    static let dim    = Color(red: 0.56, green: 0.56, blue: 0.60)
    static let modelColors: [Color] = [coral, jade, blue, .purple, .yellow, .pink]
}

/// One card look for the whole popover: translucent fill plus a 1 pt border, so cards read
/// as panels rather than as raised blocks.
struct CardSurface: ViewModifier {
    var radius: CGFloat = 12
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: radius)
                .strokeBorder(Palette.stroke, lineWidth: 1))
    }
}

extension View {
    func cardSurface(radius: CGFloat = 12) -> some View { modifier(CardSurface(radius: radius)) }
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
        HStack(spacing: 18) {
            ForEach(Page.allCases) { p in
                let active = page == p
                VStack(spacing: 4) {
                    Text(p.label)
                        .font(.system(size: 11.5, weight: active ? .semibold : .regular))
                        .foregroundStyle(active ? Color.white : Palette.dim)
                    Rectangle()
                        .fill(active ? Color.white : Color.clear)
                        .frame(height: 1.5)
                        .clipShape(Capsule())
                }
                .contentShape(Rectangle())
                .onTapGesture { pageRaw = p.rawValue }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
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
        HStack(spacing: 8) {
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

            Spacer()

            HStack(spacing: 5) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 5, height: 5)
                Text(store.connection.message)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Palette.dim)
                    .lineLimit(1)
            }
            .help(store.connection.message)

            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(store.isRefreshing ? Palette.dim : Palette.slate)
            }
            .buttonStyle(.plain)
            .help("Refresh now")
            .disabled(store.isRefreshing)
        }
        .padding(.horizontal, 16)
        .padding(.top, 13)
        .padding(.bottom, 9)
    }

    private var measureLabel: some View {
        HStack(spacing: 5) {
            Text(measure.label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.9)
                .foregroundStyle(Palette.slate)
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(Palette.dim)
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
        // Sorted by size so the legend reads biggest-first instead of interleaving sources.
        let head = (Array(claudeRows.prefix(2)) + Array(kenariRows.prefix(2)))
            .sorted { $0.value > $1.value }
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
        return VStack(spacing: 13) {
            segmented
            HStack(spacing: 16) {
                DonutChart(slices: data.map { ($0.value, $0.color) }, lineWidth: 12)
                    .frame(width: 92, height: 92)
                    .overlay {
                        VStack(spacing: 0) {
                            Text(centerValue(grandTotal))
                                .font(.system(size: 17, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                            Text(centerCaption)
                                .font(.system(size: 9))
                                .foregroundStyle(Palette.dim)
                        }
                    }
                VStack(alignment: .leading, spacing: 7) {
                    if data.isEmpty {
                        Text("Belum ada pemakaian di rentang ini")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Palette.dim)
                    }
                    ForEach(Array(data.prefix(5).enumerated()), id: \.offset) { _, s in
                        HStack(spacing: 7) {
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(s.color)
                                .frame(width: 6, height: 6)
                            Text(s.name)
                                .font(.system(size: 10.5))
                                .foregroundStyle(Color.white.opacity(0.82))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text(shortValue(s.value))
                                .font(.system(size: 10, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(Palette.slate)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let note = claudeShareNote {
                Text(note)
                    .font(.system(size: 9))
                    .foregroundStyle(Palette.dim)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(13)
        .cardSurface()
    }

    private var segmented: some View {
        HStack(spacing: 14) {
            ForEach(TimeRange.allCases) { r in
                let active = store.range == r
                Text(r.label)
                    .font(.system(size: 10.5, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? Color.white : Palette.dim)
                    .contentShape(Rectangle())
                    .onTapGesture { store.range = r }
            }
            Spacer()
        }
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
        let accent = card.id == "claude" ? Palette.jade : Palette.coral
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: card.symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(card.name)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(card.subtitle)
                        .font(.system(size: 9))
                        .foregroundStyle(Palette.dim)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 4)
            }

            VStack(spacing: 11) {
                ForEach(card.rows) { row in
                    quotaRow(title: row.title, fraction: row.remaining,
                             left: row.valueText, rightTop: "", rightBottom: row.detail,
                             color: accent, leftEmphasis: true,
                             depleted: row.remaining <= 0.001)
                }
            }

            if let note = card.note {
                Text(note)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let foot = card.footnote {
                Text(foot)
                    .font(.system(size: 9.5))
                    .monospacedDigit()
                    .foregroundStyle(Palette.dim.opacity(0.85))
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private func quotaRow(title: String, fraction: Double, left: String,
                          rightTop: String, rightBottom: String, color: Color,
                          leftEmphasis: Bool = false, depleted: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.78))
                Spacer(minLength: 6)
                Text(left)
                    .font(.system(size: leftEmphasis ? 12 : 10,
                                  weight: leftEmphasis ? .semibold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(depleted ? Palette.coral : Color.white)
                if !rightTop.isEmpty {
                    Text(rightTop)
                        .font(.system(size: 9.5))
                        .foregroundStyle(Palette.dim)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Depleted keeps a full-width coral-tinted track: a bare track reads as
                    // "no data", which is exactly what the 0% row used to look like.
                    Capsule().fill(depleted ? Palette.coral.opacity(0.20) : Palette.track)
                    if !depleted {
                        Capsule()
                            .fill(color)
                            .frame(width: max(3, geo.size.width * min(1, fraction)))
                    }
                }
            }
            .frame(height: 4)
            Text(depleted ? "habis · \(rightBottom)" : rightBottom)
                .font(.system(size: 9.5))
                .monospacedDigit()
                .foregroundStyle(depleted ? Palette.coral.opacity(0.9) : Palette.dim)
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
        footerRow
    }

    private var footerRow: some View {
        HStack(spacing: 8) {
            Text("\(version) · update \(nextUpdateText)")
                .font(.system(size: 9.5))
                .monospacedDigit()
                .foregroundStyle(Palette.dim)
            Spacer()
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
        .padding(.vertical, 9)
        .background(Palette.panel)
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.stroke).frame(height: 1)
        }
    }

    private var optionsLabel: some View {
        HStack(spacing: 3) {
            Text("Opsi").font(.system(size: 10, weight: .medium))
            Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
        }
        .foregroundStyle(Palette.slate)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .overlay(Capsule().strokeBorder(Palette.stroke, lineWidth: 1))
    }

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
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
