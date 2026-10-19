import SwiftUI
import UsageBarKit

/// Page 2: how many tokens actually moved, per source.
///
/// Claude Code and Kenari are independent counters — Claude's transcript `usage` blocks are
/// the only place its tokens exist, and the Kenari/OpenCode report carries its own. Adding
/// them into one number would hide which subscription the spend landed on, so each source
/// keeps its own card and the header sums them only as a grand total.
struct TokenPage: View {
    @ObservedObject var store: UsageStore
    var interactive: Bool = true

    var body: some View {
        VStack(spacing: 14) {
            totalCard
            sourceCard(
                title: "Claude Code",
                subtitle: claudeSubtitle,
                symbol: "terminal.fill",
                accent: Palette.jade,
                totals: store.claudeReport?.totals,
                models: store.claudeReport?.models ?? [],
                note: store.claudeReport == nil ? "belum ada transkrip untuk rentang ini" : nil
            )
            sourceCard(
                title: "Kenari / OpenCode",
                subtitle: store.report?.source.label ?? "—",
                symbol: "bolt.horizontal.circle.fill",
                accent: Palette.coral,
                totals: store.report?.totals,
                models: store.report?.models ?? [],
                note: store.report == nil ? "belum ada trafik untuk rentang ini" : nil
            )
            breakdownCard
        }
    }

    // MARK: total

    private var claudeTokens: Int {
        let t = store.claudeReport?.totals
        return (t?.inputTokens ?? 0) + (t?.outputTokens ?? 0)
    }
    private var kenariTokens: Int { store.report?.totals.totalTokens ?? 0 }
    private var grandTotal: Int { claudeTokens + kenariTokens }

    private var totalCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Money.tokens(grandTotal))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                Text("token")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.slate)
                Spacer()
                Text(store.range.label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Palette.slate)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Palette.track))
            }

            // One split bar: proportion per source, so the eye reads "who spent what".
            GeometryReader { geo in
                let total = max(1, grandTotal)
                HStack(spacing: 2) {
                    bar(geo.size.width * CGFloat(claudeTokens) / CGFloat(total), Palette.jade)
                    bar(geo.size.width * CGFloat(kenariTokens) / CGFloat(total), Palette.coral)
                }
            }
            .frame(height: 7)

            HStack(spacing: 14) {
                legend("Claude Code", claudeTokens, Palette.jade)
                legend("Kenari", kenariTokens, Palette.coral)
            }

            if let updated = store.lastUpdated {
                Text("diperbarui \(ago(updated))")
                    .font(.system(size: 9))
                    .foregroundStyle(Palette.slate)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private func bar(_ width: CGFloat, _ color: Color) -> some View {
        Capsule().fill(width < 1 ? Color.clear : color)
            .frame(width: max(0, width))
    }

    private func legend(_ name: String, _ value: Int, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(name).font(.system(size: 10)).foregroundStyle(Color.white.opacity(0.8))
            Text(Money.tokens(value))
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
        }
    }

    private var claudeSubtitle: String {
        guard let m = store.claudeReport?.models.first else { return "Langganan Claude" }
        return m.displayName
    }

    // MARK: per source

    private func sourceCard(title: String, subtitle: String, symbol: String, accent: Color,
                            totals: UsageTotals?, models: [ModelUsage], note: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(Palette.slate)
                }
                Spacer()
                if let t = totals {
                    Text("\(t.requests) req")
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Palette.slate)
                }
            }

            if let note {
                Text(note).font(.system(size: 10)).foregroundStyle(Palette.slate)
            } else if let t = totals {
                HStack(spacing: 8) {
                    tokenCell("Input", t.inputTokens, accent, emphasis: true)
                    tokenCell("Output", t.outputTokens, accent, emphasis: true)
                    tokenCell("Cache baca", t.cacheReadTokens, Palette.slate)
                    tokenCell("Cache tulis", t.cacheWriteTokens, Palette.slate)
                }
                // Cache is metered but re-read every turn, so it dwarfs input+output. Say so,
                // otherwise the header total looks wrong against the card.
                if t.cacheReadTokens + t.cacheWriteTokens > 0 {
                    Text("total di atas = input + output; cache tidak dihitung")
                        .font(.system(size: 8))
                        .foregroundStyle(Palette.dim)
                }
                if !models.isEmpty {
                    Divider().overlay(Color.white.opacity(0.07)).padding(.top, 2)
                    ForEach(models.prefix(4)) { m in
                        modelRow(name: m.displayName,
                                 tokens: Money.tokens(m.totalTokens),
                                 reqs: "\(m.requests) req", dim: false)
                    }
                    // Without this the visible model rows do not add up to the card total,
                    // which reads like missing data rather than a truncated list.
                    if models.count > 4 {
                        let rest = models.dropFirst(4)
                        modelRow(name: "+\(rest.count) model lain",
                                 tokens: Money.tokens(rest.reduce(0) { $0 + $1.totalTokens }),
                                 reqs: "", dim: true)
                    }
                }
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    /// Name / value / request count on one row. The req column has a fixed width so the
    /// numbers stack vertically instead of starting at a different x per row.
    private func modelRow(name: String, tokens: String, reqs: String, dim: Bool) -> some View {
        HStack(spacing: 6) {
            Text(name)
                .font(.system(size: 10))
                .foregroundStyle(dim ? Palette.dim : Color.white.opacity(0.85))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(tokens)
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(dim ? Palette.dim : .white)
            Text(reqs)
                .font(.system(size: 9))
                .monospacedDigit()
                .foregroundStyle(Palette.dim)
                .frame(width: 46, alignment: .trailing)
        }
    }

    /// Input/Output carry the accent and full size; cache is muted and smaller because it is
    /// excluded from the card total and would otherwise out-shout the numbers that matter.
    private func tokenCell(_ label: String, _ value: Int, _ color: Color,
                           emphasis: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 9)).foregroundStyle(Palette.dim)
            Text(Money.tokens(value))
                .font(.system(size: emphasis ? 14 : 12,
                              weight: emphasis ? .semibold : .medium,
                              design: .rounded))
                .monospacedDigit()
                .foregroundStyle(emphasis ? color : Color.white.opacity(0.6))
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
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Token harian").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                Spacer()
                Text(points.isEmpty ? "—" : "\(points.count) hari")
                    .font(.system(size: 10)).foregroundStyle(Palette.slate)
            }
            if points.isEmpty {
                Text("belum ada data harian").font(.system(size: 10)).foregroundStyle(Palette.slate)
            } else {
                StackedBars(points: points,
                            claude: store.claudeReport?.daily ?? [],
                            kenari: store.report?.daily ?? [])
                    .frame(height: 34)
                HStack(spacing: 12) {
                    legend("Claude Code", claudeTokens, Palette.jade)
                    legend("Kenari", kenariTokens, Palette.coral)
                }
                HStack {
                    Text(shortDay(points.first?.date))
                    Spacer()
                    Text(shortDay(points.last?.date))
                }
                .font(.system(size: 9))
                .foregroundStyle(Palette.slate)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private func shortDay(_ d: Date?) -> String {
        guard let d else { return "" }
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        f.locale = Locale(identifier: "id_ID")
        return f.string(from: d)
    }

    /// `Duration.id` rounds sub-minute gaps down to "sebentar lagi", which reads like the
    /// update has not happened yet. Below a minute, say the seconds.
    private func ago(_ date: Date) -> String {
        let secs = Int(Date().timeIntervalSince(date))
        if secs < 60 { return "\(max(0, secs)) detik lalu" }
        return Duration.id(secs) + " lalu"
    }
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

    var body: some View {
        let keys = points.map { DayKey.string($0.date) }
        let c = series(claude, keys: keys)
        let k = series(kenari, keys: keys)
        return VStack(alignment: .leading, spacing: 3) {
            row(c, color: Palette.jade)
            row(k, color: Palette.coral)
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
                RoundedRectangle(cornerRadius: 1)
                    .fill(v > 0 ? color.opacity(0.85) : Palette.track)
                    .frame(height: max(1.5, CGFloat(v) / CGFloat(maxVal) * 13))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 14, alignment: .bottom)
    }
}
