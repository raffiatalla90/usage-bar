import AppKit
import SwiftUI
import UsageBarKit

// MARK: - Watcher

/// Live feed of file changes made by OpenCode / Claude Code, polled from disk.
@MainActor
final class ActivityWatcher: ObservableObject {
    enum Filter: String, CaseIterable {
        case all, opencode, claude
        var label: String {
            switch self {
            case .all: return "Semua"
            case .opencode: return "OpenCode"
            case .claude: return "Claude"
            }
        }
    }

    @Published private(set) var all: [CodeActivity] = []
    @Published private(set) var lastChange: Date?
    @Published var expanded = false
    @Published var filter: Filter = .all

    private var timer: Timer?
    private let window: TimeInterval = 6 * 3600

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func refresh() {
        let found = ActivityFeed.recent(since: Date().addingTimeInterval(-window), limit: 40)
        // Collapse repeats: three edits to one file is one row with a ×3 badge, not three rows.
        var order: [String] = []
        var byPath: [String: CodeActivity] = [:]
        for item in found {
            if var kept = byPath[item.path] {
                kept.hits += 1
                byPath[item.path] = kept
            } else {
                byPath[item.path] = item
                order.append(item.path)
            }
        }
        let merged = order.compactMap { byPath[$0] }
        if merged.map(\.id) != all.map(\.id) || merged.map(\.hits) != all.map(\.hits) { all = merged }
        lastChange = all.first?.date
    }

    var items: [CodeActivity] {
        switch filter {
        case .all: return all
        case .opencode: return all.filter { $0.agent == .opencode }
        case .claude: return all.filter { $0.agent == .claude }
        }
    }

    func count(_ f: Filter) -> Int {
        switch f {
        case .all: return all.count
        case .opencode: return all.filter { $0.agent == .opencode }.count
        case .claude: return all.filter { $0.agent == .claude }.count
        }
    }

    var isBusy: Bool {
        guard let d = lastChange else { return false }
        return Date().timeIntervalSince(d) < 45
    }

    /// Items grouped by project folder, preserving recency order of the groups.
    var groups: [(project: String, items: [CodeActivity])] {
        var order: [String] = []
        var buckets: [String: [CodeActivity]] = [:]
        for item in items {
            let key = item.projectName.isEmpty ? "lainnya" : item.projectName
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(item)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }
}

// MARK: - Shape

/// Notch panel silhouette: square top (it is welded to the screen edge), softly rounded
/// bottom corners, and a small concave flare where it meets the housing so the panel reads
/// as part of the notch instead of a floating card.
struct NotchShape: Shape {
    var bottomRadius: CGFloat = 24
    var flare: CGFloat = 12

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = min(bottomRadius, rect.width / 2, rect.height)
        let f = min(flare, rect.height / 2)
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r - f))
        // concave flare out of the top edge
        p.addQuadCurve(to: CGPoint(x: rect.minX + f, y: rect.maxY - r),
                       control: CGPoint(x: rect.minX, y: rect.maxY - r))
        p.addLine(to: CGPoint(x: rect.maxX - r - f, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY - r + f),
                       control: CGPoint(x: rect.maxX - r, y: rect.maxY - r))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r + f))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Controller

/// Borderless panel welded into the notch band.
///
/// Collapsed: a black strip spanning the notch plus a wing on each side (the centre ~185 pt is
/// the physical camera housing, so all content lives in the wings). Expanded: the same strip
/// grows downward, flush with the screen edge, so it looks like the notch itself opens.
@MainActor
final class NotchActivityController {
    private let watcher = ActivityWatcher()
    private var panel: NSPanel!
    private var hosting: NSHostingView<NotchView>!
    private var expanded = false
    private var raiseTimer: Timer?
    private var shownAt = Date()

    private let contentHeight: CGFloat = 336
    private let expandedWidth: CGFloat = 420
    private let wing: CGFloat = 64
    private var notchWidth: CGFloat = 185
    private var notchHeight: CGFloat = 34

    func start() {
        watcher.start()
        _ = notchGeometry()
        buildPanel()
        reposition(animated: false)
        // Re-assert stacking order: other notch utilities reorder their own windows.
        raiseTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.expanded else { return }
                self.panel.orderFrontRegardless()
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reposition(animated: false) }
        }
    }

    private func buildPanel() {
        let size = NSSize(width: notchWidth + wing * 2, height: notchHeight)
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        // Above other notch utilities (Vorssaint sits at statusWindow+1 = 26).
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 5)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.appearance = NSAppearance(named: .darkAqua)

        hosting = NSHostingView(rootView: NotchView(watcher: watcher,
                                                    toggle: { [weak self] in self?.toggle() },
                                                    notchWidth: notchWidth,
                                                    notchHeight: notchHeight))
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
        panel.orderFrontRegardless()
    }

    private func notchGeometry() -> (notchRect: NSRect, screen: NSScreen)? {
        guard let screen = NSScreen.main else { return nil }
        let top = screen.frame.maxY
        let inset = screen.safeAreaInsets.top
        var w: CGFloat = 185
        if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            w = max(120, r.minX - l.maxX)
        }
        let h = max(inset, 24)
        notchWidth = w
        notchHeight = h
        return (NSRect(x: screen.frame.midX - w / 2, y: top - h, width: w, height: h), screen)
    }

    private func targetFrame() -> NSRect? {
        guard let (notch, screen) = notchGeometry() else { return nil }
        let top = screen.frame.maxY
        if expanded {
            // Flush with the top edge: the notch band itself is drawn black, so panel and
            // notch merge into one silhouette.
            let h = notch.height + contentHeight
            let x = min(max(notch.midX - expandedWidth / 2, 8), screen.frame.maxX - expandedWidth - 8)
            return NSRect(x: x, y: top - h, width: expandedWidth, height: h)
        }
        let w = notch.width + wing * 2
        return NSRect(x: notch.minX - wing, y: top - notch.height, width: w, height: notch.height)
    }

    private func reposition(animated: Bool) {
        guard let frame = targetFrame() else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 0.9, 0.28, 1)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
        hosting.frame = NSRect(origin: .zero, size: frame.size)
    }

    func toggle() {
        // A stray click can land on the strip the instant it appears under the cursor, so the
        // panel would open by itself at login. Ignore taps for the first moment.
        guard Date().timeIntervalSince(shownAt) > 0.4 else { return }
        expanded.toggle()
        watcher.expanded = expanded
        if expanded { watcher.refresh() }
        reposition(animated: true)
        panel.orderFrontRegardless()
    }

    /// `--notch-verify`: prove the panel is on screen and the feed has rows, then exit.
    func verify() {
        let f = panel.frame
        let onScreen = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [String: Any] == nil)
            ? false
            : (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
                .contains { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() }
        print("panel: x=\(Int(f.minX)) y=\(Int(f.minY)) w=\(Int(f.width)) h=\(Int(f.height))")
        print("notch: w=\(Int(notchWidth)) h=\(Int(notchHeight))")
        print("level: \(panel.level.rawValue) visible: \(panel.isVisible) onscreen: \(onScreen)")
        print("items: \(watcher.all.count)  groups: \(watcher.groups.map { "\($0.project)=\($0.items.count)" }.joined(separator: ", "))")
        toggle()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            let e = self.panel.frame
            print("expanded: w=\(Int(e.width)) h=\(Int(e.height)) topGap=\(Int(self.notchGeometry()!.screen.frame.maxY - e.maxY))")
            exit(0)
        }
    }
}

// MARK: - View

struct NotchView: View {
    @ObservedObject var watcher: ActivityWatcher
    var toggle: () -> Void
    /// Renderer override so both states can be captured without a live panel.
    var forceExpanded: Bool? = nil
    var notchWidth: CGFloat = 185
    var notchHeight: CGFloat = 34

    @State private var hovered: String?
    @State private var pulse = false

    private var expanded: Bool { forceExpanded ?? watcher.expanded }

    private enum Ink {
        static let surface = Color(red: 0.043, green: 0.047, blue: 0.055)
        static let hairline = Color.white.opacity(0.075)
        static let text = Color.white.opacity(0.94)
        static let dim = Color.white.opacity(0.40)
        static let faint = Color.white.opacity(0.26)
        static let opencode = Color(red: 0.49, green: 0.89, blue: 0.76)
        static let claude = Color(red: 0.94, green: 0.71, blue: 0.55)
        static let live = Color(red: 0.42, green: 0.93, blue: 0.62)
    }

    var body: some View {
        Group {
            if expanded { panel } else { strip }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    // MARK: Collapsed

    /// Flush black strip welded to the top edge. Wings carry the live state; the middle gap
    /// is the camera housing and stays black so nothing shows through from behind.
    private var strip: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                ZStack {
                    if watcher.isBusy {
                        Circle().fill(Ink.live.opacity(0.35))
                            .frame(width: 13, height: 13)
                            .scaleEffect(pulse ? 1.0 : 0.55)
                            .opacity(pulse ? 0.25 : 0.8)
                    }
                    Circle()
                        .fill(watcher.isBusy ? Ink.live : Color.white.opacity(0.22))
                        .frame(width: 5.5, height: 5.5)
                }
                if watcher.isBusy {
                    Text("live")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(Ink.live.opacity(0.9))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 13)

            Color.black.frame(width: notchWidth)

            HStack(spacing: 5) {
                Text("\(watcher.all.count)")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Ink.text)
                Text("berkas")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(Ink.faint)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 13)
        }
        .frame(height: notchHeight)
        .background(Color.black)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
    }

    // MARK: Expanded

    private var panel: some View {
        VStack(spacing: 0) {
            // Notch band: painted solid black so the panel's silhouette continues the housing.
            Color.black.frame(height: notchHeight)
            card
        }
        .background(NotchShape().fill(Ink.surface))
        .overlay(NotchShape().stroke(Ink.hairline, lineWidth: 1))
        .contentShape(NotchShape())
        .onTapGesture(perform: toggle)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            filterBar
            Rectangle().fill(Ink.hairline).frame(height: 1).padding(.horizontal, 14)
            list
            footer
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Perubahan kode")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Ink.text)
            Spacer(minLength: 0)
            Text(watcher.isBusy ? "sedang menulis" : "diam sejak \(watcher.lastChange.map(ago) ?? "—")")
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .foregroundStyle(watcher.isBusy ? Ink.live.opacity(0.85) : Ink.faint)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var filterBar: some View {
        HStack(spacing: 5) {
            ForEach(ActivityWatcher.Filter.allCases, id: \.self) { f in
                let active = watcher.filter == f
                Button {
                    watcher.filter = f
                } label: {
                    HStack(spacing: 5) {
                        if let tint = tint(for: f) {
                            Circle().fill(tint).frame(width: 5, height: 5)
                        }
                        Text(f.label)
                            .font(.system(size: 10, weight: active ? .semibold : .regular, design: .rounded))
                            .foregroundStyle(active ? Ink.text : Ink.dim)
                        Text("\(watcher.count(f))")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(active ? Ink.text.opacity(0.55) : Ink.faint)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(active ? Color.white.opacity(0.085) : Color.clear)
                    )
                    .overlay(
                        Capsule().strokeBorder(active ? Color.white.opacity(0.09) : Color.white.opacity(0.05),
                                               lineWidth: 0.75)
                    )
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func tint(for f: ActivityWatcher.Filter) -> Color? {
        switch f {
        case .all: return nil
        case .opencode: return Ink.opencode
        case .claude: return Ink.claude
        }
    }

    @ViewBuilder
    private var list: some View {
        if forceExpanded == nil {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    groupRows
                }
                .padding(.vertical, 6)
            }
        } else {
            // ImageRenderer cannot rasterise a ScrollView; a clipped static stack stands in
            // for it so the render shows exactly what the panel shows at rest.
            VStack(alignment: .leading, spacing: 0) {
                groupRows
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .frame(height: 238, alignment: .top)
            .clipped()
        }
    }

    private var groupRows: some View {
        ForEach(watcher.groups, id: \.project) { group in
            if watcher.groups.count > 1 {
                HStack(spacing: 7) {
                    Text(group.project)
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(Ink.dim)
                    Rectangle().fill(Ink.hairline).frame(height: 1)
                    Text("\(group.items.count)")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(Ink.faint)
                }
                .padding(.horizontal, 16)
                .padding(.top, 7)
                .padding(.bottom, 4)
            }
            ForEach(group.items) { row($0) }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text("klik baris untuk buka di Finder")
                .font(.system(size: 9, design: .rounded))
                .foregroundStyle(Ink.faint)
            Spacer()
            Text("klik untuk tutup")
                .font(.system(size: 9, design: .rounded))
                .foregroundStyle(Ink.faint)
        }
        .padding(.horizontal, 16)
        .padding(.top, 9)
        .padding(.bottom, 11)
        .overlay(alignment: .top) {
            Rectangle().fill(Ink.hairline).frame(height: 1)
        }
    }

    private func row(_ item: CodeActivity) -> some View {
        let tint = item.agent == .opencode ? Ink.opencode : Ink.claude
        let hot = hovered == item.id
        return HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(tint)
                .frame(width: 2.5, height: 22)
                .opacity(hot ? 1 : 0.65)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.fileName)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Ink.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if item.hits > 1 {
                        Text("×\(item.hits)")
                            .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(tint.opacity(0.9))
                            .padding(.horizontal, 3.5)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(tint.opacity(0.13)))
                    }
                }
                Text(item.subpath)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Ink.dim)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 2) {
                Text(item.tool.lowercased())
                    .font(.system(size: 8.5, weight: .medium, design: .rounded))
                    .foregroundStyle(tint.opacity(hot ? 0.95 : 0.6))
                Text(ago(item.date))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Ink.faint)
            }

            Image(systemName: "arrow.up.forward")
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(Ink.dim)
                .opacity(hot ? 1 : 0)
                .frame(width: 10)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(hot ? 0.05 : 0))
        )
        .padding(.horizontal, 7)
        .contentShape(Rectangle())
        .onHover { inside in
            guard forceExpanded == nil else { return }
            hovered = inside ? item.id : (hovered == item.id ? nil : hovered)
        }
        .onTapGesture {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
        }
    }

    private func ago(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)j"
    }
}
