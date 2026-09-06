import SwiftUI

/// Barre horizontale en blocs : `████░░░░`. `width` en caractères.
public struct Meter: View {
    @Environment(\.glyph) private var t
    let fraction: Double
    let width: Int
    let color: Color?

    public init(_ fraction: Double, width: Int = 12, color: Color? = nil) {
        self.fraction = fraction.isFinite ? min(max(fraction, 0), 1) : 0
        self.width = width
        self.color = color
    }

    public var body: some View {
        let filled = Int((fraction * Double(width)).rounded())
        HStack(spacing: 0) {
            Text(String(repeating: "█", count: filled)).foregroundStyle(color ?? t.accent)
            Text(String(repeating: "░", count: width - filled)).foregroundStyle(t.faint)
        }
        .font(t.font)
        .accessibilityLabel(Tabular.percent(fraction))
    }
}

/// Courbe d'étincelle en glyphes ▁▂▃▄▅▆▇█.
public struct Spark: View {
    @Environment(\.glyph) private var t
    let values: [Double]
    let color: Color?
    static let glyphs: [Character] = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]

    public init(_ values: [Double], color: Color? = nil) { self.values = values; self.color = color }

    public var body: some View {
        let mx = values.max() ?? 0
        let s = String(values.map { v -> Character in
            guard mx > 0, v > 0 else { return "▁" }
            let i = Int((v / mx * 7).rounded(.down))
            return Spark.glyphs[min(7, max(0, i))]
        })
        Text(s).font(t.font).foregroundStyle(color ?? t.accent)
            .accessibilityLabel("\(values.count) valeurs, maximum \(Int(mx))")
    }
}

/// Statistique : petit libellé, grand chiffre tabulaire.
public struct Stat: View {
    @Environment(\.glyph) private var t
    let label: String
    let value: String
    let note: String?

    public init(_ label: String, _ value: String, note: String? = nil) { self.label = label; self.value = value; self.note = note }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(t.smallFont).tracking(1).foregroundStyle(t.muted)
            Text(value).font(t.bigFont).foregroundStyle(t.ink).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            if let note { Text(note).font(t.smallFont).foregroundStyle(t.muted).lineLimit(1) }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Grille de cellules (calendrier d'activité, matrice) dessinée en `Canvas`
/// sur la grille de caractères. `levels` ∈ [0, 1], `nil` = cellule absente.
public struct CellGrid: View {
    @Environment(\.glyph) private var t
    let columns: Int
    let rows: Int
    let levels: [Double?]        // rows × columns, indexé [row * columns + col]
    let cellSize: CGFloat
    let gap: CGFloat
    let color: Color?

    public init(columns: Int, rows: Int, levels: [Double?], cellSize: CGFloat = 9, gap: CGFloat = 2, color: Color? = nil) {
        self.columns = columns; self.rows = rows; self.levels = levels
        self.cellSize = cellSize; self.gap = gap; self.color = color
    }

    public var body: some View {
        let w = CGFloat(columns) * (cellSize + gap) - gap
        let h = CGFloat(rows) * (cellSize + gap) - gap
        Canvas(rendersAsynchronously: false) { ctx, _ in
            let accent = color ?? t.accent
            for r in 0..<rows {
                for c in 0..<columns {
                    let i = r * columns + c
                    guard i < levels.count, let lv = levels[i] else { continue }
                    let rect = CGRect(x: CGFloat(c) * (cellSize + gap), y: CGFloat(r) * (cellSize + gap), width: cellSize, height: cellSize)
                    if lv <= 0 {
                        ctx.fill(Path(rect), with: .color(t.ink.opacity(0.07)))
                    } else {
                        ctx.fill(Path(rect), with: .color(accent.opacity(0.25 + 0.75 * min(1, lv))))
                    }
                }
            }
        }
        .frame(width: w, height: h)
    }
}

/// Barres empilées par colonne (rivière d'activité). `series[s][col]`.
public struct StackedBars: View {
    @Environment(\.glyph) private var t
    let series: [[Double]]
    let colors: [Color]
    let height: CGFloat

    public init(series: [[Double]], colors: [Color], height: CGFloat = 56) {
        self.series = series; self.colors = colors; self.height = height
    }

    public var body: some View {
        let cols = series.first?.count ?? 0
        let totals = (0..<cols).map { c in series.reduce(0) { $0 + $1[c] } }
        let mx = max(totals.max() ?? 1, 1)
        GeometryReader { geo in
            Canvas(rendersAsynchronously: false) { ctx, size in
                guard cols > 0 else { return }
                let gap: CGFloat = 1.5
                let bw = max(1, (size.width - gap * CGFloat(cols - 1)) / CGFloat(cols))
                for c in 0..<cols {
                    var y = size.height
                    for (s, values) in series.enumerated() {
                        let h = CGFloat(values[c] / mx) * size.height
                        guard h > 0 else { continue }
                        let rect = CGRect(x: CGFloat(c) * (bw + gap), y: y - h, width: bw, height: max(h, 0.5))
                        ctx.fill(Path(rect), with: .color(colors[s % colors.count]))
                        y -= h
                    }
                }
            }
            .frame(width: geo.size.width, height: height)
        }
        .frame(height: height)
    }
}

/// Ligne « libellé …… valeur » avec points de conduite.
public struct Leader: View {
    @Environment(\.glyph) private var t
    let label: String
    let value: String
    let emphasis: Bool

    public init(_ label: String, _ value: String, emphasis: Bool = false) { self.label = label; self.value = value; self.emphasis = emphasis }

    public var body: some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(emphasis ? t.ink : t.muted).lineLimit(1).truncationMode(.middle).layoutPriority(1)
            Rectangle().fill(t.faint).frame(height: 1).frame(minWidth: 6, maxWidth: .infinity).padding(.horizontal, 2).offset(y: 3)
            Text(value).foregroundStyle(t.ink).monospacedDigit().lineLimit(1).fixedSize().layoutPriority(2)
        }
        .font(t.font)
    }
}

/// Pastille pour une référence (branche, tag).
public struct Tag: View {
    @Environment(\.glyph) private var t
    let text: String
    let color: Color
    let filled: Bool

    public init(_ text: String, color: Color, filled: Bool = false) { self.text = text; self.color = color; self.filled = filled }

    public var body: some View {
        Text(text)
            .font(t.smallFont)
            .foregroundStyle(filled ? t.paper : color)
            .padding(.horizontal, 4).padding(.vertical, 0.5)
            .background(RoundedRectangle(cornerRadius: 2).fill(filled ? color : color.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(color.opacity(0.6), lineWidth: 0.5))
            .lineLimit(1)
    }
}

/// Séparateur horizontal fin en tirets.
public struct Rule: View {
    @Environment(\.glyph) private var t
    public init() {}
    public var body: some View {
        Rectangle().fill(t.faint).frame(height: 1).padding(.vertical, 4)
    }
}
