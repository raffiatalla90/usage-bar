import SwiftUI
import UsageBarKit

// Marketing shot: the composition used for App Store / README hero images — blurred pastel
// backdrop, two tilted mini cards hung on a wire, the app window bleeding off the right edge,
// and a charcoal caption pill. Rendered offscreen from live data so the numbers are real.
//
// Logical canvas is 472x1024; the renderer doubles it to 944x2048.

struct ShotData {
    var tokensToday: Int
    var requests: Int
    var daily: [Double]        // last 12 buckets, oldest first
    var models: [(String, Double)]  // name, share 0...1
    var rangeLabel: String
}

struct MarketingShot: View {
    let data: ShotData
    let caption: String

    private let canvas = CGSize(width: 472, height: 1024)

    var body: some View {
        ZStack(alignment: .topLeading) {
            backdrop
            wire
            miniCards
            window
            pill
        }
        .frame(width: canvas.width, height: canvas.height)
        .clipped()
        .environment(\.colorScheme, .light)
    }

    // MARK: Backdrop

    private var backdrop: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.80, green: 0.79, blue: 0.83),
                                    Color(red: 0.71, green: 0.70, blue: 0.75)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [.white.opacity(0.92), .white.opacity(0)],
                           center: UnitPoint(x: 0.52, y: 0.14),
                           startRadius: 8, endRadius: 300)
            // The desk scene, deliberately out of focus: cool wall over a warm floor strip.
            VStack(spacing: 0) {
                Color(red: 0.55, green: 0.59, blue: 0.65)
                Color(red: 0.79, green: 0.66, blue: 0.53)
            }
            .frame(width: 520, height: 330)
            .offset(y: 110)
            .blur(radius: 30)
            .opacity(0.5)
            LinearGradient(colors: [.clear, .white.opacity(0.9)],
                           startPoint: UnitPoint(x: 0.5, y: 0.62), endPoint: .bottom)
        }
        .frame(width: canvas.width, height: canvas.height)
    }

    private var wire: some View {
        Rectangle()
            .fill(Color.black.opacity(0.14))
            .frame(width: 344, height: 0.7)
            .position(x: 236, y: 150)
    }

    // MARK: Floating cards

    /// Cards hang from the wire: their top edge sits on it, with a small clip straddling the line.
    private var miniCards: some View {
        HStack(spacing: 44) {
            chartCard.rotationEffect(.degrees(-4.5), anchor: .top)
            legendCard.rotationEffect(.degrees(3.2), anchor: .top)
        }
        .position(x: 240, y: 150 + 48)
    }

    /// Binder clip drawn on the card's own top edge, so it can never drift onto the content.
    private var clip: some View {
        RoundedRectangle(cornerRadius: 1.6)
            .fill(Color(white: 0.60))
            .frame(width: 8, height: 13)
            .overlay(RoundedRectangle(cornerRadius: 1.6).stroke(Color(white: 0.42), lineWidth: 0.6))
            .offset(y: -7)
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(short(data.tokensToday))
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Ink.cardText)
            MiniArea(points: data.daily)
                .frame(height: 34)
        }
        .padding(10)
        .frame(width: 138, height: 92, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white))
        .shadow(color: .black.opacity(0.16), radius: 12, y: 5)
        .overlay(alignment: .top) { clip }
    }

    private var legendCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(data.models.prefix(5).enumerated()), id: \.offset) { i, m in
                HStack(spacing: 5) {
                    Circle().fill(Ink.series[i % Ink.series.count]).frame(width: 5, height: 5)
                    Text(m.0)
                        .font(.system(size: 6.5, weight: .medium, design: .rounded))
                        .foregroundStyle(Ink.cardMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(10)
        .frame(width: 132, height: 96, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white))
        .shadow(color: .black.opacity(0.16), radius: 12, y: 5)
        .overlay(alignment: .top) { clip }
    }

    // MARK: App window

    private var window: some View {
        VStack(spacing: 0) {
            chrome
            Divider().overlay(Ink.cardLine)
            HStack(alignment: .top, spacing: 0) {
                sidebar.frame(width: 118)
                Divider().overlay(Ink.cardLine)
                pane
            }
        }
        .frame(width: 470, height: 470, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14).fill(.white))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Ink.cardLine, lineWidth: 0.6))
        .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
        .position(x: 270, y: 620)
    }

    private var chrome: some View {
        HStack(spacing: 5) {
            ForEach([Color(red: 0.93, green: 0.42, blue: 0.37),
                     Color(red: 0.96, green: 0.75, blue: 0.30),
                     Color(red: 0.34, green: 0.78, blue: 0.37)], id: \.self) { c in
                Circle().fill(c).frame(width: 7, height: 7)
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 6))
                    .foregroundStyle(Ink.cardMuted)
                Text("usagebar.app")
                    .font(.system(size: 7, weight: .medium, design: .rounded))
                    .foregroundStyle(Ink.cardMuted)
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 4)
            .background(Capsule().fill(Ink.cardField))
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("WORKSPACE")
                .font(.system(size: 5.5, weight: .semibold, design: .rounded))
                .foregroundStyle(Ink.cardMuted)
                .padding(.top, 10)
            navRow("chart.pie", "Kuota", selected: true)
            navRow("chart.bar", "Token")
            navRow("wrench.and.screwdriver", "Tool")
            navRow("clock", "Riwayat")
            Text("SUMBER")
                .font(.system(size: 5.5, weight: .semibold, design: .rounded))
                .foregroundStyle(Ink.cardMuted)
                .padding(.top, 10)
            navRow("sparkles", "Kenari")
            navRow("terminal", "Claude Code")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 10)
    }

    private func navRow(_ symbol: String, _ label: String, selected: Bool = false) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 6.5))
            Text(label).font(.system(size: 7, weight: selected ? .semibold : .regular, design: .rounded))
            Spacer(minLength: 0)
        }
        .foregroundStyle(selected ? Ink.accent : Ink.cardMuted)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(selected ? Ink.accent.opacity(0.12) : .clear))
    }

    private var pane: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Pemakaian")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Ink.cardText)
                Text(data.rangeLabel)
                    .font(.system(size: 7, design: .rounded))
                    .foregroundStyle(Ink.cardMuted)
            }
            .padding(.top, 12)

            HStack(spacing: 8) {
                stat("Token", short(data.tokensToday), "+12.4%")
                stat("Permintaan", "\(data.requests)", "+8.1%")
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Token harian")
                    .font(.system(size: 7, weight: .medium, design: .rounded))
                    .foregroundStyle(Ink.cardMuted)
                HStack(spacing: 4) {
                    Text(short(data.tokensToday))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(Ink.cardText)
                    Text("+12.4% vs pekan lalu")
                        .font(.system(size: 6.5, weight: .medium, design: .rounded))
                        .foregroundStyle(Ink.positive)
                }
            }

            MiniArea(points: data.daily, filled: true)
                .frame(height: 108)

            HStack {
                Text("30 hari")
                Spacer()
                Text("hari ini")
            }
            .font(.system(size: 6, design: .rounded))
            .foregroundStyle(Ink.cardMuted)

            Divider().overlay(Ink.cardLine).padding(.top, 2)

            ForEach(Array(data.models.prefix(3).enumerated()), id: \.offset) { i, m in
                HStack(spacing: 5) {
                    Circle().fill(Ink.series[i % Ink.series.count]).frame(width: 4, height: 4)
                    Text(m.0)
                        .font(.system(size: 6.5, weight: .medium, design: .rounded))
                        .foregroundStyle(Ink.cardMuted)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(short(Int(m.1 * Double(max(data.tokensToday, 1)))))
                        .font(.system(size: 6.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(Ink.cardText)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.trailing, 52)
    }

    private func stat(_ title: String, _ value: String, _ delta: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 6.5, design: .rounded))
                .foregroundStyle(Ink.cardMuted)
            HStack(spacing: 3) {
                Text(value)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Ink.cardText)
                Text(delta)
                    .font(.system(size: 6, weight: .medium, design: .rounded))
                    .foregroundStyle(Ink.positive)
            }
        }
        .padding(7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(Ink.cardField))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Ink.cardLine, lineWidth: 0.5))
    }

    // MARK: Caption

    private var pill: some View {
        Text(caption)
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Capsule().fill(Color(white: 0.29)))
            .shadow(color: .black.opacity(0.22), radius: 12, y: 5)
            .position(x: 300, y: 790)
    }
}

// MARK: - Light card palette

private enum Ink {
    static let cardText = Color(white: 0.12)
    static let cardMuted = Color(white: 0.55)
    static let cardLine = Color(white: 0.90)
    static let cardField = Color(white: 0.965)
    static let accent = Color(red: 0.23, green: 0.51, blue: 0.96)
    static let positive = Color(red: 0.13, green: 0.62, blue: 0.42)
    static let series: [Color] = [accent,
                                  Color(red: 0.20, green: 0.71, blue: 0.47),
                                  Color(red: 0.96, green: 0.62, blue: 0.24),
                                  Color(red: 0.92, green: 0.35, blue: 0.42),
                                  Color(red: 0.29, green: 0.68, blue: 0.72)]
}

/// Area line over the last 12 buckets. Normalised so the tallest bucket fills the height.
private struct MiniArea: View {
    let points: [Double]
    var filled: Bool = false

    var body: some View {
        GeometryReader { geo in
            let vals = points.isEmpty ? [0.35, 0.5, 0.42, 0.66, 0.58, 0.74] : points
            let maxV = max(vals.max() ?? 1, 1)
            let stepX = geo.size.width / CGFloat(max(vals.count - 1, 1))
            let path = Path { p in
                for (i, v) in vals.enumerated() {
                    let x = CGFloat(i) * stepX
                    let y = geo.size.height - CGFloat(v / maxV) * geo.size.height * 0.86 - 2
                    if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                    else { p.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            ZStack {
                if filled {
                    path.strokedPath(StrokeStyle(lineWidth: 1.6))
                        .fill(LinearGradient(colors: [Ink.accent.opacity(0.22), .clear],
                                             startPoint: .top, endPoint: .bottom))
                        .mask(Path { p in
                            p.move(to: .zero)
                            p.addLine(to: CGPoint(x: geo.size.width, y: 0))
                            p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height))
                            p.addLine(to: CGPoint(x: 0, y: geo.size.height))
                            p.closeSubpath()
                        })
                }
                path.stroke(Ink.accent, style: StrokeStyle(lineWidth: filled ? 1.6 : 1.4,
                                                           lineCap: .round, lineJoin: .round))
            }
        }
    }
}

private func short(_ n: Int) -> String {
    let d = Double(n)
    if d >= 1_000_000 { return String(format: "%.1fM", d / 1_000_000) }
    if d >= 1_000 { return String(format: "%.1fK", d / 1_000) }
    return "\(n)"
}

// MARK: - Export

/// Turns the live report into the shot, and the shot into a PNG. Shared by the `--render-shot`
/// CLI path and the footer's "Save promo image" item so both produce the identical artwork.
@MainActor
enum MarketingShotExporter {
    static func data(from store: UsageStore) -> ShotData {
        let report = store.report
        let daily = Array((report?.daily ?? []).map { Double($0.tokens) }.suffix(12))
        let models = (report?.models ?? [])
            .sorted { $0.totalTokens > $1.totalTokens }
            .prefix(5)
            .map { ($0.displayName, Double($0.totalTokens)) }
        let peak = max(models.map(\.1).max() ?? 1, 1)
        return ShotData(tokensToday: report?.totals.totalTokens ?? 0,
                        requests: report?.totals.requests ?? 0,
                        daily: daily,
                        models: models.map { ($0.0, $0.1 / peak) },
                        rangeLabel: "30 hari terakhir")
    }

    static func png(_ data: ShotData, caption: String) -> Data? {
        let renderer = ImageRenderer(content: MarketingShot(data: data, caption: caption))
        renderer.scale = 2
        guard let img = renderer.nsImage,
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Writes to `~/Pictures/UsageBar/shot-<timestamp>.png`. Returns the path, or nil if the
    /// render or the write failed.
    static func save(_ data: ShotData, caption: String) -> String? {
        guard let bytes = png(data, caption: caption) else { return nil }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/UsageBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("shot-\(stamp).png")
        do { try bytes.write(to: url); return url.path } catch { return nil }
    }
}

