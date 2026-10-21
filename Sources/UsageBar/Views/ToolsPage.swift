import SwiftUI
import UsageBarKit

/// Page 3: are rtk and caveman actually running?
///
/// Both are context savers that sit in front of the coding agents, and neither has an API —
/// the only honest answer comes from their own files: rtk's command history, caveman's
/// active-mode marker and per-session mode files.
struct ToolsPage: View {
    @ObservedObject var store: UsageStore

    /// Levels are read once on appear and after every write; they are not on the refresh tick
    /// because each read hits a different file (or a loopback HTTP call) and nothing else
    /// changes them while the popover is open.
    /// Seeded synchronously so the offscreen render (which never runs `.task`) still shows the
    /// real selection; `loadLevels()` re-reads on appear and after every write. Headroom falls
    /// back to its documented default so a fresh install still highlights one chip.
    @State private var cavemanLevel: String? = ToolSettings.cavemanLevel()
    @State private var rtkLevel: String? = ToolSettings.rtkLevel()
    @State private var headroomLevel: String? = ToolSettings.headroomStoredLevel() ?? "coding"
    @State private var note: String?

    var body: some View {
        VStack(spacing: 14) {
            headroomCard
            rtkCard
            cavemanCard
            activeCard
            if let note {
                Text(note).font(.system(size: 9)).foregroundStyle(Palette.coral)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            footnote
        }
        .task { await loadLevels() }
    }

    private func loadLevels() async {
        cavemanLevel = ToolSettings.cavemanLevel()
        rtkLevel = ToolSettings.rtkLevel()
        headroomLevel = await ToolSettings.headroomLevel(port: store.headroom.port)
            ?? ToolSettings.headroomStoredLevel() ?? "coding"
    }

    /// One row of choices per tool. `nil` current means "nothing stored yet" — the tool is on
    /// its own default, which is why no chip is highlighted instead of guessing which one.
    private func levelPicker(_ levels: [ToolLevel], current: String?,
                             set: @escaping (String) -> Void) -> some View {
        HStack(spacing: 4) {
            Text("level").font(.system(size: 9)).foregroundStyle(Palette.slate)
            ForEach(levels) { level in
                let active = current == level.id
                Text(level.label)
                    .font(.system(size: 9, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? Palette.panel : Color.white.opacity(0.85))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(
                        Capsule().fill(active ? Palette.jade : Color.white.opacity(0.07))
                    )
                    .contentShape(Capsule())
                    .onTapGesture { set(level.id) }
                    .help(level.id)
            }
            Spacer(minLength: 0)
        }
    }

    private func apply(_ work: @escaping () throws -> Void) {
        do {
            try work()
            note = nil
            Task { await loadLevels(); store.refreshLocalTools() }
        } catch {
            note = error.localizedDescription
        }
    }

    // MARK: active project

    /// "What am I working on, and what did it save?" — answered from the two tools that
    /// actually record a working directory: rtk's `project_path` (today) and headroom's
    /// `persistent_savings.projects` (lifetime). Rows are merged and sorted by recency, so
    /// the top row is the directory touched last, whichever tool saw it.
    private struct ActiveRow: Identifiable {
        let id: String
        /// What the row prints: a `~`-collapsed path for rtk, the project key for headroom.
        let label: String
        let tool: String
        let saved: Int
        let last: Date?
        let running: Bool
    }

    private var activeRows: [ActiveRow] {
        // headroom groups by project name and everything it has seen so far collapses into
        // the home folder; rtk logs the home cwd whenever a command runs from `~`. A row
        // named after the user says nothing about what is open, so both are dropped instead
        // of sitting at the top of the list with the newest timestamp.
        let home = FileManager.default.homeDirectoryForCurrentUser.lastPathComponent
        func isUseful(_ name: String) -> Bool { !name.isEmpty && name != home }

        let rtkRows = store.rtk.projects
            .filter { isUseful($0.name) }
            .map { p in
                ActiveRow(id: "rtk:\(p.path)", label: p.displayPath, tool: "rtk",
                          saved: p.savedTokens, last: p.lastRun, running: true)
            }
        let hrRows = store.headroom.projects
            .filter { isUseful($0.name) }
            .map { p in
                ActiveRow(id: "hr:\(p.name)", label: p.name, tool: "headroom",
                          saved: p.tokensSaved, last: p.lastActivity,
                          running: p.lastActivity.map { Date().timeIntervalSince($0) < 3600 } ?? false)
            }
        return (rtkRows + hrRows).sorted {
            ($0.last ?? .distantPast) > ($1.last ?? .distantPast)
        }
    }

    private var activeCard: some View {
        let rows = activeRows
        let current = rows.first
        return VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Image(systemName: "folder.badge.gearshape")
                    .font(.system(size: 15))
                    .foregroundStyle(current == nil ? Palette.slate : Palette.jade)
                VStack(alignment: .leading, spacing: 1) {
                    Text("proyek aktif").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    Text(current.map { "sedang dikerjakan: \($0.label)" } ?? "belum ada aktivitas hari ini")
                        .font(.system(size: 10)).foregroundStyle(Palette.slate)
                        .lineLimit(1)
                }
                Spacer()
                if let c = current, let last = c.last {
                    Text(verbatim: Duration.id(Int(Date().timeIntervalSince(last))) + " lalu")
                        .font(.system(size: 9))
                        .monospacedDigit()
                        .foregroundStyle(Palette.slate)
                }
            }

            if rows.isEmpty {
                Text("rtk dan headroom belum mencatat folder kerja")
                    .font(.system(size: 10)).foregroundStyle(Palette.slate)
            } else {
                ForEach(rows.prefix(5)) { row in
                    HStack(spacing: 7) {
                        Circle()
                            .fill(row.running ? Palette.jade : Palette.slate.opacity(0.5))
                            .frame(width: 5, height: 5)
                        Text(row.label)
                            .font(.system(size: 10))
                            .foregroundStyle(Color.white.opacity(0.9))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(row.tool)
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(Palette.slate)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.white.opacity(0.07)))
                        Spacer(minLength: 6)
                        Text(verbatim: "hemat " + Money.tokens(row.saved))
                            .font(.system(size: 10, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(row.saved > 0 ? Palette.jade : Palette.slate)
                    }
                }
                if rows.count > 5 {
                    Text(verbatim: "+\(rows.count - 5) folder lain hari ini")
                        .font(.system(size: 9)).foregroundStyle(Palette.slate)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    // MARK: headroom

    private var headroomCard: some View {
        let h = store.headroom
        return VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 15))
                    .foregroundStyle(h.isRunning ? Palette.jade : Palette.slate)
                VStack(alignment: .leading, spacing: 1) {
                    Text("headroom").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    Text("proxy pemangkas token").font(.system(size: 10)).foregroundStyle(Palette.slate)
                }
                Spacer()
                if let mode = h.mode {
                    Text(mode)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Palette.blue)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.07)))
                }
                statusPill(running: h.isRunning, label: h.isRunning ? "jalan" : "mati")
            }

            levelPicker(ToolSettings.headroomLevels, current: headroomLevel) { level in
                Task {
                    do {
                        let needsRestart = try await ToolSettings.setHeadroomLevel(level, port: h.port)
                        headroomLevel = level
                        if needsRestart {
                            // LaunchAgent install: bounce it so the profile takes effect now.
                            if await ToolSettings.restartHeadroom(port: h.port) {
                                headroomLevel = await ToolSettings.headroomLevel(port: h.port)
                                note = "profil \(level) aktif — proxy di-restart"
                            } else {
                                note = "profil tersimpan — proxy perlu di-restart agar berlaku"
                            }
                        } else {
                            note = nil
                        }
                        store.refreshLocalTools()
                    } catch {
                        note = error.localizedDescription
                    }
                }
            }

            if h.requests == 0, h.tokensSavedAll == 0 {
                Text(h.error ?? "belum ada trafik tercatat")
                    .font(.system(size: 10)).foregroundStyle(Palette.slate)
            } else {
                HStack(spacing: 8) {
                    metric("Token dihemat", Money.tokens(h.tokensSavedAll), Palette.jade)
                    metric("Rasio biaya", String(format: "%.1f%%", h.savingsPct), Palette.blue)
                }
                HStack(spacing: 8) {
                    metric("Hemat biaya", String(format: "$%.2f", h.savedUSD), Palette.jade)
                    metric("Permintaan", Money.tokens(h.requests), .white)
                }
                if h.sessionTokensSaved > 0 {
                    Text(verbatim: "sesi ini \(Money.tokens(h.sessionTokensSaved)) · \(h.sessionRequests) req · \(String(format: "$%.2f", h.sessionUSD))")
                        .font(.system(size: 9))
                        .monospacedDigit()
                        .foregroundStyle(Palette.slate)
                }
                if let last = h.lastActivity {
                    Text(verbatim: "terakhir \(Duration.id(Int(Date().timeIntervalSince(last)))) lalu · \(Money.tokens(h.requestsCompressed)) dari \(Money.tokens(h.requests)) req dipangkas · port \(h.port)")
                        .font(.system(size: 9))
                        .monospacedDigit()
                        .foregroundStyle(Palette.slate)
                }
                if !h.isRunning, let e = h.error {
                    Text(e).font(.system(size: 9)).foregroundStyle(Palette.coral)
                }
            }

        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    // MARK: rtk

    private var rtkCard: some View {
        let r = store.rtk
        return VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Image(systemName: "scissors")
                    .font(.system(size: 15))
                    .foregroundStyle(r.isRunning ? Palette.jade : Palette.slate)
                VStack(alignment: .leading, spacing: 1) {
                    Text("rtk").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    Text(r.installed ? "proxy filter token" : "belum terpasang")
                        .font(.system(size: 10)).foregroundStyle(Palette.slate)
                }
                Spacer()
                statusPill(running: r.isRunning, label: r.isRunning ? "jalan" : "idle")
            }

            levelPicker(ToolSettings.rtkLevels, current: rtkLevel) { level in
                apply { try ToolSettings.setRtkLevel(level) }
            }

            if let error = r.error, !r.dbFound {
                Text(error).font(.system(size: 10)).foregroundStyle(Palette.slate)
            } else {
                HStack(spacing: 8) {
                    metric("Hemat hari ini", Money.tokens(r.savedToday), Palette.jade)
                    metric("Perintah", "\(r.commandsToday)", .white)
                }
                HStack(spacing: 8) {
                    metric("Hemat 30 hari", Money.tokens(r.saved30d), Palette.jade)
                    metric("Rasio", String(format: "%.0f%%", r.savingsPctToday), Palette.blue)
                }
                if let last = r.lastRun {
                    Text(verbatim: "terakhir \(Duration.id(Int(Date().timeIntervalSince(last)))) lalu · \(Money.tokens(r.commands30d)) perintah / 30 hari")
                        .font(.system(size: 9))
                        .monospacedDigit()
                        .foregroundStyle(Palette.slate)
                }
                if let active = r.activeProject, let last = active.lastRun {
                    Text(verbatim: "aktif di \(active.displayPath) · \(active.commands) perintah · hemat \(Money.tokens(active.savedTokens))")
                        .font(.system(size: 9))
                        .monospacedDigit()
                        .foregroundStyle(Palette.slate)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

                    }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    // MARK: caveman

    private var cavemanCard: some View {
        let c = store.caveman
        return VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 15))
                    .foregroundStyle(c.running ? Palette.jade : Palette.slate)
                VStack(alignment: .leading, spacing: 1) {
                    Text("caveman").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    Text("pemadat output LLM").font(.system(size: 10)).foregroundStyle(Palette.slate)
                }
                Spacer()
                statusPill(running: c.running, label: c.running ? "aktif" : "mati")
            }

            levelPicker(ToolSettings.cavemanLevels, current: cavemanLevel) { level in
                apply { try ToolSettings.setCavemanLevel(level) }
            }

            if c.agents.isEmpty {
                Text("belum ada penanda mode").font(.system(size: 10)).foregroundStyle(Palette.slate)
            }
            ForEach(c.agents) { a in
                HStack(spacing: 8) {
                    Circle()
                        .fill(a.isRunning ? Palette.jade : Palette.slate.opacity(0.5))
                        .frame(width: 6, height: 6)
                    Text(a.name).font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.9))
                    Spacer()
                    if let mode = a.mode {
                        Text(mode)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(a.isRunning ? Palette.jade : Palette.slate)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.white.opacity(0.07)))
                    }
                    Text(a.lastToggled.map { Duration.id(Int(Date().timeIntervalSince($0))) } ?? "—")
                        .font(.system(size: 9))
                        .monospacedDigit()
                        .foregroundStyle(Palette.slate)
                }
            }
            if let s = c.agents.first(where: { $0.sessions > 0 }) {
                Text(verbatim: "\(s.sessions) sesi tercatat di \(s.name)")
                    .font(.system(size: 9))
                    .foregroundStyle(Palette.slate)
            }

                    }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private var footnote: some View {
        Text("dibaca dari history.db rtk, .caveman-active, ~/.headroom · tanpa jaringan keluar")
            .font(.system(size: 9))
            .foregroundStyle(Palette.slate)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: bits

    private func metric(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 9)).foregroundStyle(Palette.slate)
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color == .white ? Color.white : color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
    }

    private func statusPill(running: Bool, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(running ? Palette.jade : Palette.slate).frame(width: 5, height: 5)
            Text(label).font(.system(size: 9, weight: .semibold))
                .foregroundStyle(running ? Palette.jade : Palette.slate)
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill((running ? Palette.jade : Palette.slate).opacity(0.14)))
    }
}
