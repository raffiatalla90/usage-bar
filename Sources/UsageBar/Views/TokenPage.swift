import SwiftUI
import UsageBarKit

/// Page 2: how many tokens actually moved, per source — rendered as a terminal readout.
///
/// Claude Code and Kenari are independent counters — Claude's transcript `usage` blocks are
/// the only place its tokens exist, and the Kenari/OpenCode report carries its own. Adding
/// them into one number would hide which subscription the spend landed on, so each source
/// keeps its own card and the header sums them only as a grand total.
struct TokenPage: View {
    @ObservedObject var store: UsageStore
    var interactive: Bool = true

    /// Hacker-terminal palette. Green is the primary readout; amber is the only other colour,
    /// used to tell the two sources apart in the split bar. No rounded fonts anywhere.
    private enum Term {
        static let jade = Color(red: 0.30, green: 0.98, blue: 0.45)
        static let amber = Color(red: 0.98, green: 0.75, blue: 0.28)
        static let dim = Color(red: 0.30, green: 0.98, blue: 0.45).opacity(0.42)
        static let faint = Color(red: 0.30, green: 0.98, blue: 0.45).opacity(0.22)
        static let surface = Color(red: 0.02, green: 0.035, blue: 0.025)
    }

    var body: some View {
        VStack(spacing: 14) {
            totalCard
            sourceCard(
                title: "claude-code",
                subtitle: claudeSubtitle,
                accent: Term.jade,
                totals: store.claudeReport?.totals,
                models: store.claudeReport?.models ?? [],
                note: store.claudeReport == nil ? "no transcript in range" : nil
            )
            sourceCard(
                title: "kenari/opencode",
                subtitle: store.report?.source.label ?? "—",
                accent: Term.amber,
                totals: store.report?.totals,
                models: store.report?.models ?? [],
                note: store.report == nil ? "no traffic in range" : nil
            )
            breakdownCard
        }
        .font(.system(size: 10, design: .monospaced))
    }

    // MARK: total

    private var claudeTokens: Int {
        let t = store.claudeReport?.totals
        return (t?.inputTokens ?? 0) + (t?.outputTokens ?? 0)
    }
    private var kenariTokens: Int { store.report?.totals.totalTokens ?? 0 }
    private var grandTotal: Int { claudeTokens + kenariTokens }

    private var totalCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                prompt
                Text("tokens --total")
                    .foregroundStyle(Term.dim)
                Spacer()
                Text("[\(store.range.label.lowercased())]")
                    .foregroundStyle(Term.faint)
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Money.tokens(grandTotal))
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(Term.jade)
                    .shadow(color: Term.jade.opacity(0.5), radius: 4)
                Text("tok")
                    .foregroundStyle(Term.dim)
                Spacer()
            }

            // One split bar: proportion per source, so the eye reads "who spent what".
            GeometryReader { geo in
                let total = max(1, grandTotal)
                HStack(spacing: 2) {
                    bar(geo.size.width * CGFloat(claudeTokens) / CGFloat(total), Term.jade)
                    bar(geo.size.width * CGFloat(kenariTokens) / CGFloat(total), Term.amber)
                }
            }
            .frame(height: 6)

            HStack(spacing: 14) {
                legend("claude", claudeTokens, Term.jade)
                legend("kenari", kenariTokens, Term.amber)
            }

            if let updated = store.lastUpdated {
                Text("last sync \(ago(updated))")
                    .foregroundStyle(Term.faint)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .terminalSurface()
    }

    private var prompt: some View {
        Text(">")
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(Term.dim)
    }

    private func bar(_ width: CGFloat, _ color: Color) -> some View {
        Rectangle().fill(width < 1 ? Color.clear : color.opacity(0.85))
            .frame(width: max(0, width))
    }

    private func legend(_ name: String, _ value: Int, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Rectangle().fill(color).frame(width: 6, height: 6)
            Text(name).foregroundStyle(color.opacity(0.85))
            Text(Money.tokens(value))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(color)
        }
    }

    private var claudeSubtitle: String {
        guard let m = store.claudeReport?.models.first else { return "subscription" }
        return m.displayName.lowercased()
    }

    // MARK: per source

    private func sourceCard(title: String, subtitle: String, accent: Color,
                            totals: UsageTotals?, models: [ModelUsage], note: String?) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 4) {
                prompt
                Text(title).foregroundStyle(accent)
                Text("// \(subtitle)")
                    .foregroundStyle(Term.faint)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if let t = totals {
                    Text("\(t.requests) req")
                        .monospacedDigit()
                        .foregroundStyle(Term.dim)
                }
            }

            if let note {
                Text("! \(note)").foregroundStyle(Term.dim)
            } else if let t = totals {
                HStack(spacing: 8) {
                    tokenCell("in", t.inputTokens, accent, emphasis: true)
                    tokenCell("out", t.outputTokens, accent, emphasis: true)
                    tokenCell("cache-r", t.cacheReadTokens, Term.dim)
                    tokenCell("cache-w", t.cacheWriteTokens, Term.dim)
                }
                // Cache is metered but re-read every turn, so it dwarfs input+output. Say so,
                // otherwise the header total looks wrong against the card.
                if t.cacheReadTokens + t.cacheWriteTokens > 0 {
                    Text("# total = in + out; cache excluded")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(Term.faint)
                }
                if !models.isEmpty {
                    Rectangle().fill(Term.faint).frame(height: 1).padding(.top, 2)
                    ForEach(models.prefix(4)) { m in
                        modelRow(name: m.displayName.lowercased(),
                                 tokens: Money.tokens(m.totalTokens),
                                 reqs: "\(m.requests) req", dim: false, accent: accent)
                    }
                    // Without this the visible model rows do not add up to the card total,
                    // which reads like missing data rather than a truncated list.
                    if models.count > 4 {
                        let rest = models.dropFirst(4)
                        modelRow(name: "+\(rest.count) more",
                                 tokens: Money.tokens(rest.reduce(0) { $0 + $1.totalTokens }),
                                 reqs: "", dim: true, accent: accent)
                    }
                }
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .terminalSurface()
    }

    /// Name / value / request count on one row. The req column has a fixed width so the
    /// numbers stack vertically instead of starting at a different x per row.
    private func modelRow(name: String, tokens: String, reqs: String, dim: Bool,
                          accent: Color) -> some View {
        HStack(spacing: 6) {
            Text(name)
                .foregroundStyle(dim ? Term.faint : accent.opacity(0.8))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(tokens)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(dim ? Term.dim : accent)
            Text(reqs)
                .font(.system(size: 9, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Term.faint)
                .frame(width: 58, alignment: .trailing)
        }
    }

    /// Input/Output carry the accent and full size; cache is muted and smaller because it is
    /// excluded from the card total and would otherwise out-shout the numbers that matter.
    private func tokenCell(_ label: String, _ value: Int, _ color: Color,
                           emphasis: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 9, design: .monospaced)).foregroundStyle(Term.faint)
            Text(Money.tokens(value))
                .font(.system(size: emphasis ? 14 : 12,
                              weight: emphasis ? .semibold : .regular,
                              design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(emphasis ? color : Term.dim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: daily

    /// One bar per day, split by source. Claude and Kenari report their own `daily` arrays
    /// over the same day keys; showing only one of them made the chart look like the other
    /// source spent nothing, so both are summed per day here.
    private var mergedDaily: [DailyPoint] {
        var byDay: [String: (claude: Int, kenari: Int, requests: Int)] = [:]
        for p in store.claudeReport?.daily ?? [] {
            let k = DayKey.string(p.date)
            byDay[k, default: (0, 0, 0)].claude += p.tokens
            byDay[k, default: (0, 0, 0)].requests += p.requests
        }
        for p in store.report?.daily ?? [] {
            let k = DayKey.string(p.date)
            byDay[k, default: (0, 0, 0)].kenari += p.tokens
            byDay[k, default: (0, 0, 0)].requests += p.requests
        }
        return byDay
            .compactMap { key, v -> DailyPoint? in
                guard let d = DayKey.formatter.date(from: key) else { return nil }
                return DailyPoint(date: d, requests: v.requests, costMicroIDR: 0,
                                  tokens: v.claude + v.kenari)
            }
            .sorted { $0.date < $1.date }
    }

    private var breakdownCard: some View {
        let points = mergedDaily
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 4) {
                prompt
                Text("daily --tokens").foregroundStyle(Term.dim)
                Spacer()
                Text(points.isEmpty ? "—" : "\(points.count)d")
                    .foregroundStyle(Term.faint)
            }
            if points.isEmpty {
                Text("! no daily data").foregroundStyle(Term.dim)
            } else {
                StackedBars(points: points,
                            claude: store.claudeReport?.daily ?? [],
                            kenari: store.report?.daily ?? [],
                            claudeColor: Term.jade,
                            kenariColor: Term.amber)
                    .frame(height: 34)
                HStack(spacing: 12) {
                    legend("claude", claudeTokens, Term.jade)
                    legend("kenari", kenariTokens, Term.amber)
                }
                HStack {
                    Text(shortDay(points.first?.date))
                    Spacer()
                    Text(shortDay(points.last?.date))
                }
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Term.faint)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .terminalSurface()
    }

    private func shortDay(_ d: Date?) -> String {
        guard let d else { return "" }
        let f = DateFormatter()
        f.dateFormat = "dd/MM"
        f.locale = Locale(identifier: "id_ID")
        return f.string(from: d)
    }

    /// `Duration.id` rounds sub-minute gaps down to "sebentar lagi", which reads like the
    /// update has not happened yet. Below a minute, say the seconds.
    private func ago(_ date: Date) -> String {
        let secs = Int(Date().timeIntervalSince(date))
        if secs < 60 { return "\(max(0, secs))s ago" }
        return Duration.id(secs) + " ago"
    }
}

/// Near-black card with a phosphor hairline, so the page reads as a terminal pane rather than
/// a stack of macOS cards.
private struct TerminalSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Rectangle().fill(Color(red: 0.02, green: 0.035, blue: 0.025)))
            .overlay(Rectangle()
                .strokeBorder(Color(red: 0.30, green: 0.98, blue: 0.45).opacity(0.22),
                              lineWidth: 1))
    }
}

private extension View {
    func terminalSurface() -> some View { modifier(TerminalSurface()) }
}

/// Two rows, one per source, each scaled to its own peak.
///
/// A single stacked scale would be dishonest here: Kenari moved 705M tokens over 30 days and
/// Claude 4.3M, so Claude's bars would round to zero and the chart would again look like
/// Claude never ran. Separate scales keep both shapes readable; the legend carries the
/// absolute totals so the sizes are never compared by eye.
struct StackedBars: View {
    let points: [DailyPoint]
    let claude: [DailyPoint]
    let kenari: [DailyPoint]
    var claudeColor: Color = Palette.jade
    var kenariColor: Color = Palette.coral

    var body: some View {
        let keys = points.map { DayKey.string($0.date) }
        let c = series(claude, keys: keys)
        let k = series(kenari, keys: keys)
        return VStack(alignment: .leading, spacing: 3) {
            row(c, color: claudeColor)
            row(k, color: kenariColor)
        }
    }

    private func series(_ src: [DailyPoint], keys: [String]) -> [Int] {
        var byKey: [String: Int] = [:]
        for p in src { byKey[DayKey.string(p.date), default: 0] += p.tokens }
        return keys.map { byKey[$0] ?? 0 }
    }

    private func row(_ values: [Int], color: Color) -> some View {
        let maxVal = max(1, values.max() ?? 1)
        return HStack(alignment: .bottom, spacing: values.count > 14 ? 2 : 3) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                Rectangle()
                    .fill(v > 0 ? color.opacity(0.85) : color.opacity(0.10))
                    .frame(height: max(1.5, CGFloat(v) / CGFloat(maxVal) * 13))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 14, alignment: .bottom)
    }
}
