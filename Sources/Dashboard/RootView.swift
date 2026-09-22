import SwiftUI
import Snapshot
import Analytics
import Glyph

/// Vue racine du tableau de bord. Trois colonnes : contexte, graphe, analyse.
/// Tout ce qui est visible à la première frame ne dépend que du snapshot ;
/// les cadres qui dépendent des analytics affichent leur squelette pendant
/// les quelques millisecondes où elles se calculent.
public struct RootView: View {
    @Environment(\.glyph) private var t
    @Bindable var model: DashboardModel
    let onOpen: () -> Void
    let onSelectRepo: (String) -> Void
    let onForgetRepo: (String) -> Void

    public init(model: DashboardModel, onOpen: @escaping () -> Void, onSelectRepo: @escaping (String) -> Void, onForgetRepo: @escaping (String) -> Void = { _ in }) {
        self.model = model
        self.onOpen = onOpen
        self.onSelectRepo = onSelectRepo
        self.onForgetRepo = onForgetRepo
    }

    public var body: some View {
        ZStack {
            t.paper.ignoresSafeArea()
            if let s = model.snapshot {
                dashboard(s)
            } else {
                BuildingView(model: model, onOpen: onOpen, onSelectRepo: onSelectRepo, onClone: { model.showClone = true })
            }
        }
        .font(t.font)
        .sheet(isPresented: $model.showClone) {
            CloneSheet(providers: model.providers) { path in
                model.showClone = false
                if let path { onSelectRepo(path) }
            }
            .glyphTheme(t)
        }
    }

    @ViewBuilder
    private func dashboard(_ s: Snapshot) -> some View {
        let a = model.analytics
        VStack(spacing: 0) {
            HeaderBar(snapshot: s, analytics: a, filter: $model.filter, building: model.building, onOpen: onOpen, onClone: { model.showClone = true })
            Rectangle().fill(t.faint).frame(height: 1)
            StatsRow(snapshot: s, analytics: a).padding(.horizontal, 16).padding(.vertical, 12)
            HStack(alignment: .top, spacing: 10) {
                ScrollView(.vertical) {
                    VStack(spacing: 10) {
                        ReposWidget(repos: model.repos, current: model.currentRepoPath, discovering: model.discovering, onSelect: onSelectRepo, onOpen: onOpen,
                                    providers: model.providers, onForget: { path in model.repos.removeAll { $0.path == path }; onForgetRepo(path) })
                        if let a { SinceVisitWidget(since: a.sinceLastVisit, snapshot: s, selection: $model.selectedCommit) }
                        WorkingTreeWidget(snapshot: s)
                        if let sel = model.selectedCommit, sel < s.commits.count {
                            CommitDetailWidget(snapshot: s, index: sel, refs: a?.refsByCommit[sel] ?? [], model: model)
                        }
                        if let a { HealthWidget(snapshot: s, analytics: a) }
                    }
                }
                .frame(width: 330)
                .scrollIndicators(.never)

                VStack(spacing: 0) {
                    CommitGraphView(snapshot: s, refsByCommit: a?.refsByCommit ?? [:], indices: model.filteredIndices, selection: $model.selectedCommit,
                                    onMove: { model.moveSelection(by: $0) })
                }
                .overlay(RoundedRectangle(cornerRadius: 0).stroke(t.rule, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                ScrollView(.vertical) {
                    VStack(spacing: 10) {
                        if let a {
                            ActivityWidget(cal: a.calendar)
                            AuthorsWidget(authors: a.authors, river: a.river, total: s.commits.count)
                            HotFilesWidget(files: a.hotFiles)
                            DirectoriesWidget(dirs: a.directories)
                            ClockWidget(clock: a.clock)
                        } else {
                            Frame(String(localized: "activity")) { Text(verbatim: "…").foregroundStyle(t.muted) }
                        }
                    }
                }
                .frame(width: 330)
                .scrollIndicators(.never)
            }
            .padding(.horizontal, 12).padding(.bottom, 12)
        }
    }
}

/// Premier lancement sur un dépôt (ou aucun dépôt) : la même structure que le
/// tableau de bord, avec la progression au centre. Pas d'écran vide.
struct BuildingView: View {
    @Environment(\.glyph) private var t
    let model: DashboardModel
    let onOpen: () -> Void
    let onSelectRepo: (String) -> Void
    let onClone: () -> Void

    var body: some View {
        let name = model.currentRepoPath.map { URL(fileURLWithPath: $0).lastPathComponent }
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                Text(name ?? "Lanes").font(.system(size: t.fontSize * 1.5, weight: .semibold, design: .monospaced)).foregroundStyle(t.ink)
                if case .building(let stage, let detail) = model.building {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text(detail.isEmpty ? stage : "\(stage) · \(detail)").font(t.smallFont).foregroundStyle(t.muted) }
                }
                Spacer()
                Button("open…", action: onOpen).buttonStyle(.plain).font(t.font).foregroundStyle(t.accent).keyboardShortcut("o", modifiers: .command)
                Button("clone…", action: onClone).buttonStyle(.plain).font(t.font).foregroundStyle(t.accent).keyboardShortcut("o", modifiers: [.command, .shift])
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Rectangle().fill(t.faint).frame(height: 1)
            HStack(alignment: .top, spacing: 0) {
                ForEach([String(localized: "commits"), String(localized: "authors"), String(localized: "branches"),
                         String(localized: "files"), String(localized: "uncommitted"), String(localized: "streak")], id: \.self) { l in
                    Stat(l, "—"); Spacer()
                }
            }.padding(.horizontal, 16).padding(.vertical, 12)
            HStack(alignment: .top, spacing: 10) {
                VStack(spacing: 10) {
                    ReposWidget(repos: model.repos, current: model.currentRepoPath, discovering: model.discovering, onSelect: onSelectRepo, onOpen: onOpen, providers: model.providers)
                    Frame(String(localized: "since your last visit")) { Text(verbatim: "…").foregroundStyle(t.faint) }
                    Frame(String(localized: "working tree")) { Text(verbatim: "…").foregroundStyle(t.faint) }
                }.frame(width: 330)
                VStack(spacing: 14) {
                    Spacer()
                    switch model.building {
                    case .building(let stage, let detail):
                        Text("LANES").font(.system(size: 28, weight: .semibold, design: .monospaced)).tracking(6).foregroundStyle(t.ink)
                        Text(name.map { String(localized: "first time opening \($0): building the snapshot") } ?? String(localized: "first time opening this repository: building the snapshot")).foregroundStyle(t.muted)
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text(detail.isEmpty ? stage : "\(stage) · \(detail)").foregroundStyle(t.ink) }
                        Text("next time it will open instantly").font(t.smallFont).foregroundStyle(t.faint)
                    case .failed(let msg):
                        Text("LANES").font(.system(size: 28, weight: .semibold, design: .monospaced)).tracking(6).foregroundStyle(t.ink)
                        Text(msg).foregroundStyle(.red).multilineTextAlignment(.center).frame(maxWidth: 480)
                        Button("open another repository…", action: onOpen).buttonStyle(.plain).foregroundStyle(t.accent)
                    case .idle:
                        Text("LANES").font(.system(size: 28, weight: .semibold, design: .monospaced)).tracking(6).foregroundStyle(t.ink)
                        Text("git dashboard · read-only").foregroundStyle(t.muted)
                        HStack(spacing: 18) {
                            Button("open a repository…  ⌘O", action: onOpen).buttonStyle(.plain).foregroundStyle(t.accent)
                            Button("clone…  ⌘⇧O", action: onClone).buttonStyle(.plain).foregroundStyle(t.accent)
                        }
                        Text("or drop a folder here, or pick a repository on the left").font(t.smallFont).foregroundStyle(t.muted)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(Rectangle().stroke(t.rule, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                VStack(spacing: 10) {
                    ForEach([String(localized: "activity · 53 weeks"), String(localized: "authors"), String(localized: "hot files · 90 days"),
                              String(localized: "where the code lives · ownership"), String(localized: "code clock")], id: \.self) { f in
                        Frame(f) { Text(verbatim: "…").foregroundStyle(t.faint) }
                    }
                }.frame(width: 330)
            }
            .padding(.horizontal, 12).padding(.bottom, 12)
        }
    }
}

struct EmptyRepoView: View {
    @Environment(\.glyph) private var t
    let state: DashboardModel.BuildState
    let onOpen: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text("LANES").font(.system(size: 28, weight: .semibold, design: .monospaced)).tracking(6).foregroundStyle(t.ink)
            Text("git dashboard · read-only").font(t.font).foregroundStyle(t.muted)
            switch state {
            case .building(let stage, let detail):
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(detail.isEmpty ? stage : "\(stage) · \(detail)").font(t.font).foregroundStyle(t.muted) }
                    .padding(.top, 10)
            case .failed(let msg):
                Text(msg).font(t.font).foregroundStyle(.red).multilineTextAlignment(.center).frame(maxWidth: 480)
                Button("open another repository…", action: onOpen).buttonStyle(.plain).font(t.font).foregroundStyle(t.accent).padding(.top, 6)
            case .idle:
                Button("open a repository…  ⌘O", action: onOpen).buttonStyle(.plain).font(t.font).foregroundStyle(t.accent).padding(.top, 10)
                    .keyboardShortcut("o", modifiers: .command)
                Text("or drop a folder here").font(t.smallFont).foregroundStyle(t.muted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
