import SwiftUI
import Snapshot
import Analytics
import Glyph

struct HeaderBar: View {
    @Environment(\.glyph) private var t
    let snapshot: Snapshot
    let analytics: Analytics?
    @Binding var filter: String
    let building: DashboardModel.BuildState
    let onOpen: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            HStack(spacing: 8) {
                Text(snapshot.meta.repoName).font(.system(size: t.fontSize * 1.5, weight: .semibold, design: .monospaced)).foregroundStyle(t.ink)
                Tag(snapshot.meta.head, color: t.accent, filled: true)
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
                Text("⚠ \(msg)").font(t.smallFont).foregroundStyle(.red).lineLimit(1)
            case .idle:
                Text("snapshot \(Tabular.relative(snapshot.meta.builtAt))").font(t.smallFont).foregroundStyle(t.muted)
            }
            HStack(spacing: 4) {
                Text("/").foregroundStyle(t.muted)
                TextField("filtrer message, auteur, hash", text: $filter)
                    .textFieldStyle(.plain)
                    .frame(width: t.cell.width * 30)
            }
            .font(t.font)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(t.rule, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            Button("ouvrir…", action: onOpen).buttonStyle(.plain).font(t.font).foregroundStyle(t.accent)
                .keyboardShortcut("o", modifiers: .command)
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
            Stat("commits", Tabular.int(snapshot.commits.count), note: analytics?.firstCommit.map { "depuis \(Tabular.shortDate($0))" })
            Spacer()
            Stat("auteurs", Tabular.int(snapshot.authors.count), note: analytics.map { "\($0.authors.filter { $0.recent > 0 }.count) actifs · 90 j" })
            Spacer()
            Stat("branches", Tabular.int(h.localBranches), note: "\(h.remoteBranches) distantes · \(h.tags) tags")
            Spacer()
            Stat("fichiers", Tabular.int(h.trackedFiles), note: Tabular.bytes(h.sizeBytes) + " d'objets")
            Spacer()
            Stat("travail", "\(h.modified + h.staged)", note: "\(h.staged) indexés · \(h.untracked) non suivis")
            Spacer()
            Stat("série", analytics.map { "\($0.calendar.currentStreak) j" } ?? "–", note: analytics.map { "\(Tabular.int($0.calendar.total)) commits · 53 sem." })
        }
    }
}

struct ActivityWidget: View {
    @Environment(\.glyph) private var t
    let cal: ActivityCalendar

    var body: some View {
        Frame("activité · 53 semaines", trailing: "max \(cal.maxPerDay)/j") {
            GeometryReader { geo in
                let labelW: CGFloat = 18
                let gap: CGFloat = 1.5
                let cell = max(3, floor((geo.size.width - labelW - 6 - gap * CGFloat(cal.weeks - 1)) / CGFloat(cal.weeks)))
                HStack(alignment: .top, spacing: 6) {
                    VStack(alignment: .leading, spacing: gap) {
                        ForEach(Array(["lu", "", "me", "", "ve", "", "di"].enumerated()), id: \.offset) { _, d in
                            Text(d).font(.system(size: max(6, cell), design: .monospaced)).foregroundStyle(t.muted).frame(width: labelW, height: cell, alignment: .leading)
                        }
                    }
                    CellGrid(columns: cal.weeks, rows: 7, levels: cal.levels, cellSize: cell, gap: gap)
                }
            }
            .frame(height: 7 * 6.5 + 8)
            .accessibilityLabel("\(cal.total) commits sur 53 semaines, série actuelle \(cal.currentStreak) jours")
        }
    }
}

struct AuthorsWidget: View {
    @Environment(\.glyph) private var t
    let authors: [AuthorStat]
    let river: River
    let total: Int

    var body: some View {
        Frame("auteurs", trailing: "\(authors.count)") {
            VStack(alignment: .leading, spacing: 3) {
                if river.months.count > 1 {
                    StackedBars(series: river.series, colors: (0..<river.series.count).map { $0 == river.series.count - 1 ? t.faint : t.laneColor($0) }, height: 48)
                    HStack {
                        Text(river.months.first.map { Tabular.shortDate($0).prefix(7).description } ?? "").font(t.smallFont).foregroundStyle(t.muted)
                        Spacer()
                        Text("commits / mois").font(t.smallFont).foregroundStyle(t.muted)
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
                        Text(a.recent > 0 ? "\(a.recent) · 90 j" : Tabular.relative(a.last)).font(t.smallFont).foregroundStyle(t.muted).lineLimit(1)
                    }
                    .frame(height: t.cell.height)
                }
                if authors.count > 8 {
                    Text("… et \(authors.count - 8) autres").font(t.smallFont).foregroundStyle(t.muted)
                }
            }
        }
    }
}

struct HotFilesWidget: View {
    @Environment(\.glyph) private var t
    let files: [FileStat]

    var body: some View {
        Frame("fichiers chauds · 90 jours", trailing: files.isEmpty ? "aucun changement" : "changements") {
            if files.isEmpty {
                Text("rien n'a bougé depuis 90 jours").foregroundStyle(t.muted)
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
        Frame("où le code vit · propriété", trailing: "90 jours") {
            if dirs.isEmpty {
                Text("aucune activité récente").foregroundStyle(t.muted)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(dirs.prefix(8)) { d in
                        HStack(spacing: 6) {
                            Text(d.path).foregroundStyle(t.ink).lineLimit(1).truncationMode(.middle).frame(width: t.cell.width * 14, alignment: .leading)
                            Meter(d.share, width: 8, color: t.accent2)
                            Text(Tabular.percent(d.share)).foregroundStyle(t.muted).monospacedDigit()
                            Spacer(minLength: 2)
                            if let owner = d.owner {
                                Text("\(owner) \(Tabular.percent(d.ownerShare).trimmingCharacters(in: .whitespaces))").font(t.smallFont).foregroundStyle(t.muted).lineLimit(1)
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
        Frame("horloge du code", trailing: clock.peak.map { "pic \(["lu", "ma", "me", "je", "ve", "sa", "di"][$0.day]) \($0.hour)h" }) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(["lu", "ma", "me", "je", "ve", "sa", "di"], id: \.self) { d in
                        Text(d).font(t.smallFont).foregroundStyle(t.muted).frame(height: 9)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    CellGrid(columns: 24, rows: 7, levels: clock.levels.map { Optional($0) }, cellSize: 9, gap: 2, color: t.accent2)
                    HStack { Text("0h"); Spacer(); Text("6h"); Spacer(); Text("12h"); Spacer(); Text("18h"); Spacer(); Text("23h") }
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
        Frame("depuis ta dernière visite", trailing: since.lastVisit.map { Tabular.relative($0) } ?? "première visite") {
            if since.lastVisit == nil {
                Text("bienvenue. la prochaine fois, ce cadre te dira ce qui a bougé.").foregroundStyle(t.muted)
            } else if since.commits == 0 {
                Text("rien de nouveau. le dépôt n'a pas bougé.").foregroundStyle(t.muted)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 0) {
                        Text("\(since.commits) commit\(since.commits > 1 ? "s" : "")").foregroundStyle(t.ink)
                        Text(" de ").foregroundStyle(t.muted)
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
        Frame("santé du dépôt") {
            VStack(alignment: .leading, spacing: 3) {
                Leader("taille des objets", Tabular.bytes(h.sizeBytes))
                Leader("objets libres", Tabular.int(h.looseObjects), emphasis: h.looseObjects > 5_000)
                Leader("packs", Tabular.int(h.packs))
                Leader("branches périmées · 180 j", Tabular.int(h.staleBranches), emphasis: h.staleBranches > 0)
                if !analytics.staleBranches.isEmpty {
                    Text(analytics.staleBranches.prefix(6).joined(separator: "  ")).font(t.smallFont).foregroundStyle(t.muted).lineLimit(2)
                }
                Leader("non fusionnées dans HEAD", Tabular.int(analytics.unmergedBranches.count))
                if !analytics.largestFiles.isEmpty {
                    Rule()
                    Text("plus gros fichiers suivis").font(t.smallFont).tracking(1).foregroundStyle(t.muted)
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
        Frame("arbre de travail", trailing: st.count == 0 ? "propre ✓" : "\(st.count) entrée\(st.count > 1 ? "s" : "")") {
            if st.count == 0 {
                Text("rien à valider, arbre propre.").foregroundStyle(t.muted)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(0..<min(st.count, 10), id: \.self) { i in
                        HStack(spacing: 6) {
                            Text(String(st.code(i))).foregroundStyle(color(st.code(i))).frame(width: t.cell.width)
                            Text(st.isStaged(i) ? "●" : "○").foregroundStyle(st.isStaged(i) ? t.accent : t.muted).font(t.smallFont)
                            Text(st.path(i)).foregroundStyle(t.ink).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    if st.count > 10 { Text("… \(st.count - 10) de plus").font(t.smallFont).foregroundStyle(t.muted) }
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

    var body: some View {
        Frame("commit", trailing: snapshot.commits.shortHash(index)) {
            VStack(alignment: .leading, spacing: 4) {
                Text(snapshot.message(index)).foregroundStyle(t.ink).lineLimit(3)
                Leader("auteur", snapshot.authors.name(snapshot.commits.author(index)))
                Leader("date", Tabular.dateTime(snapshot.commits.date(index)))
                Leader("parents", "\(snapshot.commits.parentCount(index))")
                Text(snapshot.commits.fullHash(index)).font(t.smallFont).foregroundStyle(t.muted).textSelection(.enabled)
                if !refs.isEmpty {
                    HStack(spacing: 4) { ForEach(refs.prefix(6), id: \.self) { Tag($0.name, color: $0.kind == .tag ? t.accent2 : t.accent, filled: $0.isHead) } }
                }
            }
        }
    }
}

struct ReposWidget: View {
    @Environment(\.glyph) private var t
    let repos: [RepoEntry]
    let current: String?
    let discovering: Bool
    let onSelect: (String) -> Void
    let onOpen: () -> Void
    @AppStorage("reposCollapsed") private var collapsed = false

    var body: some View {
        let currentName = repos.first { $0.path == current }?.name
        Frame(collapsed ? "▸ dépôts" : "▾ dépôts", trailing: discovering ? "recherche…" : "\(repos.count) · ⌘1…9 · ⌘[ ⌘]") {
            VStack(alignment: .leading, spacing: 1) {
                if collapsed {
                    HStack(spacing: 6) {
                        Text(currentName ?? "—").foregroundStyle(t.accent).lineLimit(1)
                        Spacer()
                        Text("\(repos.count) dépôts").font(t.smallFont).foregroundStyle(t.muted)
                    }
                } else {
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 1) { rows }
                    }
                    .frame(maxHeight: t.cell.height * 12 + 12)
                    .scrollIndicators(.automatic)
                    if repos.isEmpty {
                        Text("aucun dépôt connu").foregroundStyle(t.muted)
                    }
                    Button("+ ouvrir un autre dépôt…", action: onOpen).buttonStyle(.plain).foregroundStyle(t.accent).padding(.top, 4)
                }
            }
        }
        .overlay(alignment: .topLeading) {
            // Zone de clic sur le titre pour replier / déplier.
            Button { withAnimation(.easeOut(duration: 0.15)) { collapsed.toggle() } } label: {
                Color.clear.frame(width: 120, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(collapsed ? "déplier les dépôts" : "replier les dépôts")
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
                                Text(head).font(t.smallFont).foregroundStyle(t.muted).lineLimit(1).truncationMode(.middle).frame(maxWidth: t.cell.width * 10, alignment: .trailing)
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
                    .accessibilityLabel("\(r.name), \(r.head ?? ""), \(r.commits.map { "\($0) commits" } ?? "")")
                    .help(r.path)
                }
    }
}
