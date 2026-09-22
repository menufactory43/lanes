import SwiftUI
import AppKit

/// Tokens du système de design. Une seule couleur d'accent, une grille de
/// caractères, des cadres pointillés. Tout ce qui n'est pas actif recule à 0.4.
public struct GlyphTheme: Sendable {
    public var accent: Color
    public var accent2: Color
    public var ink: Color
    public var paper: Color
    public var panel: Color
    public var rule: Color
    public var fontSize: CGFloat
    public var mutedOpacity: Double = 0.42
    public var faintOpacity: Double = 0.16

    public static let `default` = GlyphTheme(
        accent: Color(red: 0.93, green: 0.64, blue: 0.29),      // ambre
        accent2: Color(red: 0.42, green: 0.70, blue: 0.86),     // bleu froid, secondaire
        ink: Color(nsColor: .labelColor),
        paper: Color(nsColor: .windowBackgroundColor),
        panel: Color(nsColor: .controlBackgroundColor),
        rule: Color(nsColor: .separatorColor),
        fontSize: 12
    )

    public var font: Font { .system(size: fontSize, design: .monospaced) }
    public var smallFont: Font { .system(size: fontSize - 2, design: .monospaced) }
    public var bigFont: Font { .system(size: fontSize * 2.1, weight: .medium, design: .monospaced) }
    public var muted: Color { ink.opacity(mutedOpacity) }
    public var faint: Color { ink.opacity(faintOpacity) }

    /// Largeur d'une cellule de caractère pour la police courante. Mesurée une
    /// fois : SF Mono a un ratio d'avance stable (~0.6 em).
    public var cell: CGSize { CGSize(width: GlyphTheme.measuredAdvance * fontSize / 12, height: (fontSize * 1.45).rounded()) }

    /// Avance réelle d'un chiffre en SF Mono 12 pt, mesurée une fois.
    nonisolated(unsafe) static let measuredAdvance: CGFloat = {
        let f = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        return ("0" as NSString).size(withAttributes: [.font: f]).width
    }()

    /// Palette des voies du graphe : accent d'abord, puis des teintes voisines.
    public func laneColor(_ lane: Int) -> Color {
        let palette: [Color] = [
            accent, accent2,
            Color(red: 0.62, green: 0.78, blue: 0.48),
            Color(red: 0.85, green: 0.52, blue: 0.56),
            Color(red: 0.66, green: 0.60, blue: 0.86),
            Color(red: 0.45, green: 0.78, blue: 0.72),
            Color(red: 0.86, green: 0.75, blue: 0.45),
        ]
        return palette[lane % palette.count]
    }
}

private struct GlyphThemeKey: EnvironmentKey { static let defaultValue = GlyphTheme.default }

public extension EnvironmentValues {
    var glyph: GlyphTheme {
        get { self[GlyphThemeKey.self] }
        set { self[GlyphThemeKey.self] = newValue }
    }
}

public extension View {
    func glyphTheme(_ t: GlyphTheme) -> some View { environment(\.glyph, t) }
}

/// Formatage tabulaire : nombres alignés à droite, séparateur fin d'espace.
public enum Tabular {
    public static func int(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = "\u{2009}" // espace fine
        f.usesGroupingSeparator = true
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
    public static func bytes(_ b: UInt64) -> String {
        let units = [String(localized: "B", comment: "Octets (unité)"), String(localized: "KB"), String(localized: "MB"),
                     String(localized: "GB"), String(localized: "TB")]
        var v = Double(b); var i = 0
        while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
        return i == 0 ? "\(Int(v)) \(units[0])" : String(format: "%.1f %@", v, units[i])
    }
    public static func percent(_ f: Double) -> String { String(format: "%3.0f%%", f * 100) }
    /// Durée écoulée, compacte. Les chaînes viennent de Localizable.strings
    /// (Bundle.main), même depuis ce module bibliothèque.
    public static func relative(_ date: Date, now: Date = Date()) -> String {
        let s = now.timeIntervalSince(date)
        if s < 60 { return String(localized: "just now") }
        if s < 3600 { return String(localized: "\(Int(s / 60)) min ago") }
        if s < 86_400 { return String(localized: "\(Int(s / 3600)) h ago") }
        if s < 86_400 * 30 { return String(localized: "\(Int(s / 86_400)) d ago") }
        if s < 86_400 * 365 { return String(localized: "\(Int(s / (86_400 * 30))) mo ago") }
        return String(localized: "\(Int(s / (86_400 * 365))) yr ago")
    }
    public static func shortDate(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: date)
    }
    public static func dateTime(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f.string(from: date)
    }
}
