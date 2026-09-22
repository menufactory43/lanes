import SwiftUI
import Snapshot
import Analytics
import Glyph
import AppKit

/// Jours de la semaine abrégés sur deux lettres, lundi d'abord.
var weekdayShort: [String] {
    [String(localized: "Mo", comment: "lundi, 2 lettres"), String(localized: "Tu"), String(localized: "We"),
     String(localized: "Th"), String(localized: "Fr"), String(localized: "Sa"), String(localized: "Su")]
}

/// Heure pleine pour l'horloge du code : « 14:00 » en anglais, « 14h » en français.
func hourLabel(_ h: Int) -> String { String(localized: "\(h):00") }

struct HeaderBar: View {
    @Environment(\.glyph) private var t
    let snapshot: Snapshot
    let analytics: Analytics?
    @Binding var filter: String
    let building: DashboardModel.BuildState
    let onOpen: () -> Void
    var onClone: () -> Void = {}
    @FocusState private var filterFocused: Bool

    var body: some View {
        let h = snapshot.health
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            HStack(spacing: 8) {
                Text(snapshot.meta.repoName).font(.system(size: t.fontSize * 1.5, weight: .semibold, design: .monospaced)).foregroundStyle(t.ink)
                Tag(displayHead(snapshot.meta.head), color: t.accent, filled: true)
                if let ab = h.aheadBehind {
                    Text("↑\(ab.ahead) ↓\(ab.behind)")
                        .font(t.smallFont).monospacedDigit()
                        .foregroundStyle(ab.ahead + ab.behind == 0 ? t.muted : t.accent)
                        .help("\(ab.ahead) commit(s) to push, \(ab.behind) to pull")
                } else {
                    Text("no upstream").font(t.smallFont).foregroundStyle(t.faint)
                }
                if h.stashes > 0 {
                    Text("\(h.stashes) stashes").font(t.smallFont).foregroundStyle(t.accent2)
                }
            }
            Text(snapshot.meta.repoPath.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(t.smallFont).foregroundStyle(t.muted).lineLimit(1).truncationMode(.middle)
            Spacer()
            switch building {
            case .building(let stage, let detail):
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(detail.isEmpty ? stage : "\(stage) · \(detail)").font(t.smallFont).foregroundStyle(t.muted)
                }
            case .failed(let msg):
                Text(verbatim: "⚠ \(msg)").font(t.smallFont).foregroundStyle(.red).lineLimit(1)
            case .idle:
                Text("snapshot \(Tabular.relative(snapshot.meta.builtAt))").font(t.smallFont).foregroundStyle(t.muted)
            }
            HStack(spacing: 4) {
                Text("/").foregroundStyle(t.muted)
                TextField("filter message, author, hash", text: $filter)
                    .textFieldStyle(.plain)
                    .focused($filterFocused)
                    .frame(width: t.cell.width * 30)
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("app.lanes.focusFilter"))) { _ in filterFocused = true }
            .font(t.font)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(t.rule, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            Button("open…", action: onOpen).buttonStyle(.plain).font(t.font).foregroundStyle(t.accent)
                .keyboardShortcut("o", modifiers: .command)
            Button("clone…", action: onClone).buttonStyle(.plain).font(t.font).foregroundStyle(t.accent)
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

struct StatsRow: View {
    @Environment(\.glyph) private var t
    let snapshot: Snapshot
    let analytics: Analytics?

    var body: some View {
        let h = snapshot.health
        HStack(alignment: .top, spacing: 0) {
            Stat(String(localized: "commits"), Tabular.int(snapshot.commits.count), note: analytics?.firstCommit.map { String(localized: "since \(Tabular.shortDate($0))") })
            Spacer()
            Stat(String(localized: "authors"), Tabular.int(snapshot.authors.count), note: analytics.map { String(localized: "\($0.authors.filter { $0.recent > 0 }.count) active · 90 d") })
            Spacer()
            Stat(String(localized: "branches"), Tabular.int(h.localBranches), note: String(localized: "\(h.remoteBranches) remote · \(h.tags) tags"))
            Spacer()
            Stat(String(localized: "files"), Tabular.int(h.trackedFiles), note: String(localized: "\(Tabular.bytes(h.sizeBytes)) of objects"))
            Spacer()
            Stat(String(localized: "uncommitted"), "\(h.modified + h.staged)", note: String(localized: "\(h.staged) staged · \(h.untracked) untracked"))
            Spacer()
            Stat(String(localized: "streak"), analytics.map { String(localized: "\($0.calendar.currentStreak) d") } ?? "–",
                 note: analytics.map { String(localized: "\(Tabular.int($0.calendar.total)) commits · 53 wk") })
        }
    }
}

struct ActivityWidget: View {
    @Environment(\.glyph) private var t
    let cal: ActivityCalendar

    var body: some View {
        Frame(String(localized: "activity · 53 weeks"), trailing: String(localized: "max \(cal.maxPerDay)/d")) {
            GeometryReader { geo in
                let labelW: CGFloat = 18
                let gap: CGFloat = 1.5
                let cell = max(3, floor((geo.size.width - labelW - 6 - gap * CGFloat(cal.weeks - 1)) / CGFloat(cal.weeks)))
                HStack(alignment: .top, spacing: 6) {
                    VStack(alignment: .leading, spacing: gap) {
                        ForEach(Array(weekdayShort.enumerated().map { $0.offset % 2 == 0 ? $0.element : "" }.enumerated()), id: \.offset) { _, d in
                            Text(verbatim: d).font(.system(size: max(6, cell), design: .monospaced)).foregroundStyle(t.muted).frame(width: labelW, height: cell, alignment: .leading)
                        }
                    }
                    CellGrid(columns: cal.weeks, rows: 7, levels: cal.levels, cellSize: cell, gap: gap)
                }
            }
            .frame(height: 7 * 6.5 + 8)
            .accessibilityLabel("\(cal.total) commits over 53 weeks, current streak \(cal.currentStreak) days")
        }
    }
}

struct AuthorsWidget: View {
    @Environment(\.glyph) private var t
    let authors: [AuthorStat]
    let river: River
    let total: Int

    var body: some View {
        Frame(String(localized: "authors"), trailing: "\(authors.count)") {
            VStack(alignment: .leading, spacing: 3) {
                if river.months.count > 1 {
                    StackedBars(series: river.series, colors: (0..<river.series.count).map { $0 == river.series.count - 1 ? t.faint : t.laneColor($0) }, height: 48)
                    HStack {
                        Text(river.months.first.map { Tabular.shortDate($0).prefix(7).description } ?? "").font(t.smallFont).foregroundStyle(t.muted)
                        Spacer()
                        Text("commits / month").font(t.smallFont).foregroundStyle(t.muted)
                        Spacer()
                        Text(river.months.last.map { Tabular.shortDate($0).prefix(7).description } ?? "").font(t.smallFont).foregroundStyle(t.muted)
                    }
                    Rule()
                }
                ForEach(Array(authors.prefix(8).enumerated()), id: \.element.id) { i, a in
                    HStack(spacing: 6) {
                        Text(a.name).foregroundStyle(i < 5 ? t.ink : t.muted).lineLimit(1).truncationMode(.tail).frame(width: t.cell.width * 16, alignment: .leading)
                        Meter(a.share, width: 10, color: i < 5 ? t.laneColor(i) : t.muted)
                        Text(Tabular.percent(a.share)).foregroundStyle(t.muted).monospacedDigit()
                        Spacer(minLength: 2)
                        Text(a.recent > 0 ? String(localized: "\(a.recent) · 90 d") : Tabular.relative(a.last)).font(t.smallFont).foregroundStyle(t.muted).lineLimit(1)
                    }
                    .frame(height: t.cell.height)
                }
                if authors.count > 8 {
                    Text("… and \(authors.count - 8) more").font(t.smallFont).foregroundStyle(t.muted)
                }
            }
        }
    }
}

struct HotFilesWidget: View {
    @Environment(\.glyph) private var t
    let files: [FileStat]

    var body: some View {
        Frame(String(localized: "hot files · 90 days"), trailing: files.isEmpty ? String(localized: "no changes") : String(localized: "changes")) {
            if files.isEmpty {
                Text("nothing changed in 90 days").foregroundStyle(t.muted)
            } else {
                let mx = Double(files.first?.changes ?? 1)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(files) { f in
                        HStack(spacing: 6) {
                            Text(f.path).foregroundStyle(t.ink).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            Meter(Double(f.changes) / mx, width: 8)
                            Text(String(format: "%3d", f.changes)).foregroundStyle(t.muted).monospacedDigit()
                        }
                    }
                }
            }
        }
    }
}

struct DirectoriesWidget: View {
    @Environment(\.glyph) private var t
    let dirs: [DirectoryStat]

    var body: some View {
        Frame(String(localized: "where the code lives · ownership"), trailing: String(localized: "90 days")) {
            if dirs.isEmpty {
                Text("no recent activity").foregroundStyle(t.muted)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(dirs.prefix(8)) { d in
                        HStack(spacing: 6) {
                            Text(d.path).foregroundStyle(t.ink).lineLimit(1).truncationMode(.middle).frame(width: t.cell.width * 14, alignment: .leading)
                            Meter(d.share, width: 8, color: t.accent2)
                            Text(Tabular.percent(d.share)).foregroundStyle(t.muted).monospacedDigit()
                            Spacer(minLength: 2)
                            if let owner = d.owner {
                                Text(verbatim: "\(owner) \(Tabular.percent(d.ownerShare).trimmingCharacters(in: .whitespaces))").font(t.smallFont).foregroundStyle(t.muted).lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct ClockWidget: View {
    @Environment(\.glyph) private var t
    let clock: CodeClock

    var body: some View {
        Frame(String(localized: "code clock"), trailing: clock.peak.map { String(localized: "peak \(weekdayShort[$0.day]) \(hourLabel($0.hour))") }) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(weekdayShort, id: \.self) { d in
                        Text(verbatim: d).font(t.smallFont).foregroundStyle(t.muted).frame(height: 9)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    CellGrid(columns: 24, rows: 7, levels: clock.levels.map { Optional($0) }, cellSize: 9, gap: 2, color: t.accent2)
                    HStack { Text(verbatim: hourLabel(0)); Spacer(); Text(verbatim: hourLabel(6)); Spacer(); Text(verbatim: hourLabel(12)); Spacer(); Text(verbatim: hourLabel(18)); Spacer(); Text(verbatim: hourLabel(23)) }
                        .font(t.smallFont).foregroundStyle(t.muted).frame(width: 24 * 11 - 2)
                }
            }
        }
    }
}

struct SinceVisitWidget: View {
    @Environment(\.glyph) private var t
    let since: SinceLastVisit
    let snapshot: Snapshot
    @Binding var selection: Int?

    var body: some View {
        Frame(String(localized: "since your last visit"), trailing: since.lastVisit.map { Tabular.relative($0) } ?? String(localized: "first visit")) {
            if since.lastVisit == nil {
                Text("welcome. next time, this frame will show what changed.").foregroundStyle(t.muted)
            } else if since.commits == 0 {
                Text("nothing new. the repository hasn't changed.").foregroundStyle(t.muted)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 0) {
                        Text("\(since.commits) commits").foregroundStyle(t.ink)
                        Text(" by ").foregroundStyle(t.muted)
                        Text(since.authors.prefix(3).joined(separator: ", ") + (since.authors.count > 3 ? " +\(since.authors.count - 3)" : "")).foregroundStyle(t.accent).lineLimit(1)
                    }
                    ForEach(since.commitIndices.prefix(5), id: \.self) { i in
                        Button {
                            selection = i
                        } label: {
                            HStack(spacing: 6) {
                                Text(snapshot.commits.shortHash(i)).foregroundStyle(t.muted)
                                Text(snapshot.message(i)).foregroundStyle(t.ink).lineLimit(1)
                                Spacer()
                            }
                        }.buttonStyle(.plain)
                    }
                    if !since.files.isEmpty {
                        Rule()
                        ForEach(since.files.prefix(5)) { f in
                            Leader(f.path, "\(f.changes)×")
                        }
                    }
                }
            }
        }
    }
}

struct HealthWidget: View {
    @Environment(\.glyph) private var t
    let snapshot: Snapshot
    let analytics: Analytics

    var body: some View {
        let h = snapshot.health
        Frame(String(localized: "repository health")) {
            VStack(alignment: .leading, spacing: 3) {
                Leader(String(localized: "object size"), Tabular.bytes(h.sizeBytes))
                Leader(String(localized: "loose objects"), Tabular.int(h.looseObjects), emphasis: h.looseObjects > 5_000)
                Leader(String(localized: "packs"), Tabular.int(h.packs))
                Leader(String(localized: "stale branches · 180 d"), Tabular.int(h.staleBranches), emphasis: h.staleBranches > 0)
                if !analytics.staleBranches.isEmpty {
                    Text(analytics.staleBranches.prefix(6).joined(separator: "  ")).font(t.smallFont).foregroundStyle(t.muted).lineLimit(2)
                }
                Leader(String(localized: "not merged into HEAD"), Tabular.int(analytics.unmergedBranches.count))
                if !analytics.largestFiles.isEmpty {
                    Rule()
                    Text("largest tracked files").font(t.smallFont).tracking(1).foregroundStyle(t.muted)
                    ForEach(analytics.largestFiles.prefix(5)) { f in
                        Leader(f.path, Tabular.bytes(f.size), emphasis: f.size > 5_000_000)
                    }
                }
            }
        }
    }
}

struct WorkingTreeWidget: View {
    @Environment(\.glyph) private var t
    let snapshot: Snapshot

    var body: some View {
        let st = snapshot.status
        Frame(String(localized: "working tree"), trailing: st.count == 0 ? String(localized: "clean ✓") : String(localized: "\(st.count) entries")) {
            if st.count == 0 {
                Text("nothing to commit, working tree clean.").foregroundStyle(t.muted)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(0..<min(st.count, 10), id: \.self) { i in
                        HStack(spacing: 6) {
                            Text(String(st.code(i))).foregroundStyle(color(st.code(i))).frame(width: t.cell.width)
                            Text(st.isStaged(i) ? "●" : "○").foregroundStyle(st.isStaged(i) ? t.accent : t.muted).font(t.smallFont)
                            Text(st.path(i)).foregroundStyle(t.ink).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    if st.count > 10 { Text("… \(st.count - 10) more").font(t.smallFont).foregroundStyle(t.muted) }
                }
            }
        }
    }

    func color(_ c: Character) -> Color {
        switch c {
        case "M": return t.accent
        case "A": return Color(red: 0.62, green: 0.78, blue: 0.48)
        case "D", "U": return Color(red: 0.85, green: 0.52, blue: 0.56)
        case "?": return t.muted
        default: return t.accent2
        }
    }
}

struct CommitDetailWidget: View {
    @Environment(\.glyph) private var t
    let snapshot: Snapshot
    let index: Int
    let refs: [RefLabel]
    let model: DashboardModel

    var body: some View {
        let hash = snapshot.commits.fullHash(index)
        let files = model.commitFiles[hash]
        Frame(String(localized: "commit"), trailing: snapshot.commits.shortHash(index)) {
            VStack(alignment: .leading, spacing: 4) {
                Text(snapshot.message(index)).foregroundStyle(t.ink).lineLimit(3)
                Leader(String(localized: "author"), snapshot.authors.name(snapshot.commits.author(index)))
                Leader(String(localized: "date"), Tabular.dateTime(snapshot.commits.date(index)))
                Leader(String(localized: "parents"), "\(snapshot.commits.parentCount(index))")
                Text(hash).font(t.smallFont).foregroundStyle(t.muted).textSelection(.enabled)
                if !refs.isEmpty {
                    HStack(spacing: 4) { ForEach(refs.prefix(6), id: \.self) { Tag($0.name, color: $0.kind == .tag ? t.accent2 : t.accent, filled: $0.isHead) } }
                }
                Rule()
                if let files {
                    let added = files.reduce(0) { $0 + max(0, $1.added) }, deleted = files.reduce(0) { $0 + max(0, $1.deleted) }
                    HStack(spacing: 6) {
                        Text("\(files.count) files").font(t.smallFont).tracking(1).foregroundStyle(t.muted)
                        Spacer()
                        Text("+\(added)").font(t.smallFont).foregroundStyle(Color(red: 0.62, green: 0.78, blue: 0.48))
                        Text("−\(deleted)").font(t.smallFont).foregroundStyle(Color(red: 0.85, green: 0.52, blue: 0.56))
                    }
                    let mx = max(1, files.map { max(0, $0.added) + max(0, $0.deleted) }.max() ?? 1)
                    ForEach(files.prefix(14)) { f in
                        HStack(spacing: 6) {
                            Text(String(f.status)).font(t.smallFont).foregroundStyle(statusColor(f.status)).frame(width: t.cell.width)
                            Text(f.path).foregroundStyle(t.ink).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            if f.isBinary {
                                Text("bin").font(t.smallFont).foregroundStyle(t.muted)
                            } else {
                                DiffBar(added: f.added, deleted: f.deleted, max: mx)
                                Text("\(f.added + f.deleted)").font(t.smallFont).foregroundStyle(t.muted).monospacedDigit().frame(width: t.cell.width * 4, alignment: .trailing)
                            }
                        }
                    }
                    if files.count > 14 { Text("… \(files.count - 14) more").font(t.smallFont).foregroundStyle(t.muted) }
                    if files.isEmpty { Text("no files (empty commit or merge without changes)").foregroundStyle(t.muted) }
                } else if let err = model.commitFilesError {
                    Text(err).font(t.smallFont).foregroundStyle(.red).lineLimit(2)
                } else {
                    Text("…").foregroundStyle(t.muted)
                }
            }
        }
        .task(id: hash) { await model.loadCommitFiles(index) }
    }

    func statusColor(_ c: Character) -> Color {
        switch c {
        case "A": return Color(red: 0.62, green: 0.78, blue: 0.48)
        case "D": return Color(red: 0.85, green: 0.52, blue: 0.56)
        case "R", "C": return t.accent2
        default: return t.accent
        }
    }
}

/// Barre +/− proportionnelle, 6 cellules.
struct DiffBar: View {
    @Environment(\.glyph) private var t
    let added: Int, deleted: Int, max: Int
    var body: some View {
        let cells = 6
        let a = Int((Double(added) / Double(max) * Double(cells)).rounded(.up))
        let d = Int((Double(deleted) / Double(max) * Double(cells)).rounded(.up))
        HStack(spacing: 0) {
            Text(String(repeating: "█", count: Swift.min(cells, a))).foregroundStyle(Color(red: 0.62, green: 0.78, blue: 0.48))
            Text(String(repeating: "█", count: Swift.min(cells - Swift.min(cells, a), d))).foregroundStyle(Color(red: 0.85, green: 0.52, blue: 0.56))
            Text(String(repeating: "░", count: Swift.max(0, cells - Swift.min(cells, a) - Swift.min(cells - Swift.min(cells, a), d)))).foregroundStyle(t.faint)
        }
        .font(t.smallFont)
    }
}

struct ReposWidget: View {
    @Environment(\.glyph) private var t
    let repos: [RepoEntry]
    let current: String?
    let discovering: Bool
    let onSelect: (String) -> Void
    let onOpen: () -> Void
    var providers: DashboardProviders = .none
    var onForget: (String) -> Void = { _ in }
    @AppStorage("reposCollapsed") private var collapsed = false

    var body: some View {
        let currentName = repos.first { $0.path == current }?.name
        Frame((collapsed ? "▸ " : "▾ ") + String(localized: "repositories"), trailing: discovering ? String(localized: "searching…") : "\(repos.count) · ⌘1…9 · ⌘[ ⌘]") {
            VStack(alignment: .leading, spacing: 1) {
                if collapsed {
                    HStack(spacing: 6) {
                        Text(currentName ?? "—").foregroundStyle(t.accent).lineLimit(1)
                        Spacer()
                        Text("\(repos.count) repositories").font(t.smallFont).foregroundStyle(t.muted)
                    }
                } else {
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 1) { rows }
                    }
                    .frame(maxHeight: t.cell.height * 12 + 12)
                    .scrollIndicators(.automatic)
                    if repos.isEmpty {
                        Text("no known repositories").foregroundStyle(t.muted)
                    }
                    Button("+ open another repository…", action: onOpen).buttonStyle(.plain).foregroundStyle(t.accent).padding(.top, 4)
                }
            }
        }
        .overlay(alignment: .topLeading) {
            // Zone de clic sur le titre pour replier / déplier.
            Button { withAnimation(.easeOut(duration: 0.15)) { collapsed.toggle() } } label: {
                Color.clear.frame(width: 120, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(collapsed ? String(localized: "expand repositories") : String(localized: "collapse repositories"))
        }
    }

    @ViewBuilder private var rows: some View {
                ForEach(Array(repos.enumerated()), id: \.element.id) { i, r in
                    let isCurrent = r.path == current
                    Button { onSelect(r.path) } label: {
                        HStack(spacing: 6) {
                            Text(i < 9 ? "\(i + 1)" : " ").font(t.smallFont).foregroundStyle(t.faint).frame(width: t.cell.width)
                            Text(r.name).foregroundStyle(isCurrent ? t.accent : t.ink).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            if let head = r.head {
                                Text(displayHead(head)).font(t.smallFont).foregroundStyle(t.muted).lineLimit(1).truncationMode(.middle).frame(maxWidth: t.cell.width * 10, alignment: .trailing)
                            }
                            Text(r.commits.map { Tabular.int($0) } ?? (r.hasSnapshot ? "" : "·")).font(t.smallFont).foregroundStyle(t.muted).monospacedDigit()
                                .frame(width: t.cell.width * 6, alignment: .trailing)
                        }
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(isCurrent ? t.accent.opacity(0.12) : .clear)
                        .overlay(alignment: .leading) { if isCurrent { Rectangle().fill(t.accent).frame(width: 2) } }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: "\(r.name), \(r.head.map(displayHead) ?? ""), \(r.commits.map { String(localized: "\($0) commits") } ?? "")"))
                    .help(r.path)
                    .contextMenu {
                        Button("Open in Finder") { providers.openInFinder(r.path) }
                        Button("Open in Terminal") { providers.openInTerminal(r.path) }
                        ForEach(providers.editors) { e in Button("Open in \(e.name)") { providers.openInEditor(r.path, e) } }
                        Divider()
                        Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(r.path, forType: .string) }
                        Button("Remove from List") { onForget(r.path) }
                    }
                }
    }
}
