import SwiftUI

/// Cadre MDX Graphs : bordure pointillée, coins marqués d'un « + », titre en
/// petites capitales monospace. Le contenu est posé sur la grille de caractères.
public struct Frame<Content: View>: View {
    @Environment(\.glyph) private var t
    let title: String
    let trailing: String?
    let content: Content

    public init(_ title: String, trailing: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text(title.uppercased())
                    .font(t.smallFont)
                    .tracking(1.2)
                    .foregroundStyle(t.muted)
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing).font(t.smallFont).foregroundStyle(t.muted)
                }
            }
            .padding(.horizontal, t.cell.width * 1.5)
            .padding(.top, 8)
            .padding(.bottom, 6)
            content
                .font(t.font)
                .padding(.horizontal, t.cell.width * 1.5)
                .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(t.panel.opacity(0.35))
        .overlay(DashedBorder().stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 3])).foregroundStyle(t.rule))
        .overlay(alignment: .topLeading) { plus }
        .overlay(alignment: .topTrailing) { plus }
        .overlay(alignment: .bottomLeading) { plus }
        .overlay(alignment: .bottomTrailing) { plus }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private var plus: some View {
        Text("+").font(t.smallFont).foregroundStyle(t.muted)
            .frame(width: 9, height: 9)
            .background(t.paper)
            .offset(x: 0, y: 0)
            .alignmentGuide(.leading) { $0[.leading] + 4.5 }
            .alignmentGuide(.trailing) { $0[.trailing] - 4.5 }
            .alignmentGuide(.top) { $0[.top] + 4.5 }
            .alignmentGuide(.bottom) { $0[.bottom] - 4.5 }
    }
}

struct DashedBorder: Shape {
    func path(in rect: CGRect) -> Path { Path(rect.insetBy(dx: 0.5, dy: 0.5)) }
}
