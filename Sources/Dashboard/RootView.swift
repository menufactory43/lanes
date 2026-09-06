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

    public init(model: DashboardModel, onOpen: @escaping () -> Void, onSelectRepo: @escaping (String) -> Void) {
        self.model = model
        self.onOpen = onOpen
        self.onSelectRepo = onSelectRepo
    }

    public var body: some View {
        ZStack {
            t.paper.ignoresSafeArea()
            if let s = model.snapshot {
                dashboard(s)
            } else {
                HStack(alignment: .top, spacing: 10) {
                    if !model.repos.isEmpty {
                        ReposWidget(repos: model.repos, current: model.currentRepoPath, discovering: model.discovering, onSelect: onSelectRepo, onOpen: onOpen)
                            .frame(width: 330).padding(12)
                    }
                    EmptyRepoView(state: model.building, onOpen: onOpen)
                }
            }
        }
        .font(t.font)
    }

    @ViewBuilder
    private func dashboard(_ s: Snapshot) -> some View {
        let a = model.analytics
        VStack(spacing: 0) {
            HeaderBar(snapshot: s, analytics: a, filter: $model.filter, building: model.building, onOpen: onOpen)
            Rectangle().fill(t.faint).frame(height: 1)
            StatsRow(snapshot: s, analytics: a).padding(.horizontal, 16).padding(.vertical, 12)
            HStack(alignment: .top, spacing: 10) {
                ScrollView(.vertical) {
                    VStack(spacing: 10) {
                        ReposWidget(repos: model.repos, current: model.currentRepoPath, discovering: model.discovering, onSelect: onSelectRepo, onOpen: onOpen)
                        if let a { SinceVisitWidget(since: a.sinceLastVisit, snapshot: s, selection: $model.selectedCommit) }
                        WorkingTreeWidget(snapshot: s)
                        if let sel = model.selectedCommit, sel < s.commits.count {
                            CommitDetailWidget(snapshot: s, index: sel, refs: a?.refsByCommit[sel] ?? [])
                        }
                        if let a { HealthWidget(snapshot: s, analytics: a) }
                    }
                }
                .frame(width: 330)
                .scrollIndicators(.never)

                VStack(spacing: 0) {
                    CommitGraphView(snapshot: s, refsByCommit: a?.refsByCommit ?? [:], indices: model.filteredIndices, selection: $model.selectedCommit)
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
                            Frame("activité") { Text("…").foregroundStyle(t.muted) }
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

struct EmptyRepoView: View {
    @Environment(\.glyph) private var t
    let state: DashboardModel.BuildState
    let onOpen: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text("LANES").font(.system(size: 28, weight: .semibold, design: .monospaced)).tracking(6).foregroundStyle(t.ink)
            Text("tableau de bord git · lecture seule").font(t.font).foregroundStyle(t.muted)
            switch state {
            case .building(let stage, let detail):
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(detail.isEmpty ? stage : "\(stage) · \(detail)").font(t.font).foregroundStyle(t.muted) }
                    .padding(.top, 10)
            case .failed(let msg):
                Text(msg).font(t.font).foregroundStyle(.red).multilineTextAlignment(.center).frame(maxWidth: 480)
                Button("ouvrir un autre dépôt…", action: onOpen).buttonStyle(.plain).font(t.font).foregroundStyle(t.accent).padding(.top, 6)
            case .idle:
                Button("ouvrir un dépôt…  ⌘O", action: onOpen).buttonStyle(.plain).font(t.font).foregroundStyle(t.accent).padding(.top, 10)
                    .keyboardShortcut("o", modifiers: .command)
                Text("ou glisse un dossier ici").font(t.smallFont).foregroundStyle(t.muted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
