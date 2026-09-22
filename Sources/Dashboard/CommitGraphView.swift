import SwiftUI
import Snapshot
import Analytics
import Glyph

/// Liste virtualisée des commits avec le graphe des voies dessiné en `Canvas`
/// sur la grille de caractères. Chaque ligne ne lit que son record et ses arêtes.
struct CommitGraphView: View {
    @Environment(\.glyph) private var t
    let snapshot: Snapshot
    let refsByCommit: [Int: [RefLabel]]
    let indices: [Int]?
    @Binding var selection: Int?
    var onMove: (Int) -> Void = { _ in }
    @FocusState private var focused: Bool

    private var laneWidth: CGFloat { t.cell.width * 1.6 }
    private var maxLaneShown: Int { 12 }

    var body: some View {
        let count = indices?.count ?? snapshot.commits.count
        let rows = indices ?? Array(0..<count)
        ScrollViewReader { proxy in
            List {
                ForEach(rows, id: \.self) { i in
                    CommitRow(snapshot: snapshot, index: i, showGraph: indices == nil,
                              refs: refsByCommit[i] ?? [], laneWidth: laneWidth, maxLane: maxLaneShown)
                        .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
                        .listRowSeparator(.hidden)
                        .listRowBackground(
                            selection == i
                                ? AnyView(HStack(spacing: 0) {
                                    Rectangle().fill(t.accent).frame(width: 2)
                                    Rectangle().fill(t.accent.opacity(0.13))
                                  })
                                : AnyView(Color.clear)
                        )
                        .onTapGesture { selection = (selection == i) ? nil : i }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, t.cell.height)
            .onChange(of: selection) { _, new in
                guard let new else { return }
                withAnimation(nil) { proxy.scrollTo(new, anchor: nil) }
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { onMove(-1); return .handled }
            .onKeyPress(.downArrow) { onMove(1); return .handled }
            .onKeyPress(.escape) { selection = nil; return .handled }
            .onKeyPress(.return) {
                if let sel = selection { withAnimation(nil) { proxy.scrollTo(sel, anchor: .center) } }
                return .handled
            }
            .onTapGesture { focused = true }
        }
        .accessibilityLabel("Commit graph, \(count) rows")
    }
}

struct CommitRow: View {
    @Environment(\.glyph) private var t
    let snapshot: Snapshot
    let index: Int
    let showGraph: Bool
    let refs: [RefLabel]
    let laneWidth: CGFloat
    let maxLane: Int

    var body: some View {
        let lane = snapshot.commits.lane(index)
        let edges = showGraph ? snapshot.edges.edges(row: index) : []
        let widest = min(maxLane, max(lane, edges.reduce(0) { max($0, $1.from, $1.to) }))
        HStack(spacing: 0) {
            if showGraph {
                LaneCanvas(lane: lane, edges: edges, laneWidth: laneWidth, isMerge: snapshot.commits.isMerge(index), maxLane: maxLane)
                    .frame(width: laneWidth * CGFloat(min(maxLane, 6) + 1), height: t.cell.height)
                    .clipped()
                    .accessibilityHidden(true)
                    .frame(width: laneWidth * CGFloat(widest + 1), alignment: .leading)
            }
            Text(snapshot.commits.shortHash(index))
                .foregroundStyle(t.laneColor(lane).opacity(0.9))
                .frame(width: t.cell.width * 9, alignment: .leading)
                .fixedSize()
                .padding(.leading, showGraph ? 6 : 0)
            let shown = Self.visibleRefs(refs)
            ForEach(shown.labels, id: \.self) { r in
                Tag(Self.abbreviate(r.name), color: r.kind == .tag ? t.accent2 : t.accent, filled: r.isHead)
                    .fixedSize()
                    .padding(.trailing, 4)
            }
            if shown.hidden > 0 { Text("+\(shown.hidden)").font(t.smallFont).foregroundStyle(t.muted).padding(.trailing, 4) }
            Text(snapshot.message(index))
                .foregroundStyle(t.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 8)
            Text(snapshot.authors.name(snapshot.commits.author(index)))
                .foregroundStyle(t.muted).lineLimit(1)
                .frame(width: t.cell.width * 14, alignment: .trailing)
            Text(Tabular.relative(snapshot.commits.date(index)))
                .foregroundStyle(t.muted).lineLimit(1).monospacedDigit()
                .frame(width: t.cell.width * 14, alignment: .trailing)
        }
        .font(t.font)
        .frame(maxWidth: .infinity)
        .frame(height: t.cell.height)
        .clipped()
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(snapshot.message(index)), by \(snapshot.authors.name(snapshot.commits.author(index))), \(Tabular.relative(snapshot.commits.date(index)))")
    }
}

extension CommitRow {
    /// Budget de 34 caractères d'étiquettes par ligne ; le reste devient « +n ».
    static func visibleRefs(_ refs: [RefLabel]) -> (labels: [RefLabel], hidden: Int) {
        var out: [RefLabel] = []
        var budget = 34
        for r in refs {
            let len = min(r.name.count, 24) + 2
            if out.isEmpty || len <= budget { out.append(r); budget -= len } else { break }
        }
        return (out, refs.count - out.count)
    }

    static func abbreviate(_ name: String) -> String {
        guard name.count > 24 else { return name }
        return String(name.prefix(11)) + "…" + String(name.suffix(12))
    }
}

/// Dessin d'une ligne du graphe : les voies qui passent, les arêtes vers les
/// parents, et le nœud du commit. Coordonnées sur la grille (voie × largeur).
struct LaneCanvas: View {
    @Environment(\.glyph) private var t
    let lane: Int
    let edges: [GraphEdge]
    let laneWidth: CGFloat
    let isMerge: Bool
    let maxLane: Int

    var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, size in
            let h = size.height
            let midY = h / 2
            func x(_ l: Int) -> CGFloat { laneWidth * (CGFloat(min(l, maxLane)) + 0.5) }
            for e in edges {
                let from = min(e.from, maxLane), to = min(e.to, maxLane)
                var p = Path()
                if e.kind == .pass {
                    p.move(to: CGPoint(x: x(from), y: 0)); p.addLine(to: CGPoint(x: x(from), y: h))
                    ctx.stroke(p, with: .color(t.laneColor(from).opacity(0.55)), lineWidth: 1.2)
                } else if from == to {
                    p.move(to: CGPoint(x: x(from), y: midY)); p.addLine(to: CGPoint(x: x(from), y: h))
                    ctx.stroke(p, with: .color(t.laneColor(to).opacity(0.85)), lineWidth: 1.2)
                } else {
                    // Courbe du commit (mi-hauteur) vers la voie du parent (bas de ligne).
                    p.move(to: CGPoint(x: x(from), y: midY))
                    p.addCurve(to: CGPoint(x: x(to), y: h),
                               control1: CGPoint(x: x(from), y: h * 0.95),
                               control2: CGPoint(x: x(to), y: h * 0.55))
                    ctx.stroke(p, with: .color(t.laneColor(to).opacity(0.85)), lineWidth: 1.2)
                }
            }
            // Arrivée depuis le haut : la voie du commit vient de la ligne précédente.
            var top = Path()
            top.move(to: CGPoint(x: x(lane), y: 0)); top.addLine(to: CGPoint(x: x(lane), y: midY))
            ctx.stroke(top, with: .color(t.laneColor(lane).opacity(0.85)), lineWidth: 1.2)
            let r: CGFloat = isMerge ? 2.6 : 3.2
            let dot = CGRect(x: x(lane) - r, y: midY - r, width: r * 2, height: r * 2)
            if isMerge {
                ctx.stroke(Path(ellipseIn: dot), with: .color(t.laneColor(lane)), lineWidth: 1.4)
                ctx.fill(Path(ellipseIn: dot.insetBy(dx: 1.2, dy: 1.2)), with: .color(t.paper))
            } else {
                ctx.fill(Path(ellipseIn: dot), with: .color(t.laneColor(lane)))
            }
        }
    }
}
