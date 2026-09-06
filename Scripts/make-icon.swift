// Génère AppIcon.icns : carré sombre arrondi, trois voies ambre/bleu et leurs nœuds.
import AppKit

func render(_ size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    let r = CGRect(x: 0, y: 0, width: size, height: size)
    let inset = size * 0.08
    let bg = CGPath(roundedRect: r.insetBy(dx: inset, dy: inset), cornerWidth: size * 0.2, cornerHeight: size * 0.2, transform: nil)
    ctx.addPath(bg); ctx.setFillColor(CGColor(red: 0.075, green: 0.08, blue: 0.09, alpha: 1)); ctx.fillPath()
    // Bordure pointillée façon cadre MDX
    ctx.addPath(CGPath(roundedRect: r.insetBy(dx: inset * 1.9, dy: inset * 1.9), cornerWidth: size * 0.14, cornerHeight: size * 0.14, transform: nil))
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.18)); ctx.setLineWidth(size * 0.012); ctx.setLineDash(phase: 0, lengths: [size * 0.03, size * 0.03]); ctx.strokePath()
    ctx.setLineDash(phase: 0, lengths: [])
    let amber = CGColor(red: 0.93, green: 0.64, blue: 0.29, alpha: 1)
    let blue = CGColor(red: 0.42, green: 0.70, blue: 0.86, alpha: 1)
    let lw = size * 0.045
    ctx.setLineWidth(lw); ctx.setLineCap(.round)
    let x0 = size * 0.36, x1 = size * 0.64
    let yTop = size * 0.78, yBot = size * 0.22
    // Voie principale
    ctx.setStrokeColor(amber); ctx.move(to: CGPoint(x: x0, y: yTop)); ctx.addLine(to: CGPoint(x: x0, y: yBot)); ctx.strokePath()
    // Branche : part du haut, s'écarte, revient
    ctx.setStrokeColor(blue)
    ctx.move(to: CGPoint(x: x0, y: size * 0.66))
    ctx.addCurve(to: CGPoint(x: x1, y: size * 0.55), control1: CGPoint(x: x0, y: size * 0.56), control2: CGPoint(x: x1, y: size * 0.66))
    ctx.addLine(to: CGPoint(x: x1, y: size * 0.45))
    ctx.addCurve(to: CGPoint(x: x0, y: size * 0.34), control1: CGPoint(x: x1, y: size * 0.34), control2: CGPoint(x: x0, y: size * 0.44))
    ctx.strokePath()
    // Nœuds
    func dot(_ p: CGPoint, _ c: CGColor, hollow: Bool = false) {
        let rr = size * 0.055
        let rect = CGRect(x: p.x - rr, y: p.y - rr, width: rr * 2, height: rr * 2)
        if hollow {
            ctx.setFillColor(CGColor(red: 0.075, green: 0.08, blue: 0.09, alpha: 1)); ctx.fillEllipse(in: rect)
            ctx.setStrokeColor(c); ctx.setLineWidth(lw * 0.8); ctx.strokeEllipse(in: rect.insetBy(dx: lw * 0.4, dy: lw * 0.4))
        } else { ctx.setFillColor(c); ctx.fillEllipse(in: rect) }
    }
    dot(CGPoint(x: x0, y: yTop), amber)
    dot(CGPoint(x: x0, y: size * 0.66), amber, hollow: true)
    dot(CGPoint(x: x1, y: size * 0.50), blue)
    dot(CGPoint(x: x0, y: size * 0.34), amber, hollow: true)
    dot(CGPoint(x: x0, y: yBot), amber)
    img.unlockFocus()
    return img
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = out.deletingPathExtension().appendingPathExtension("iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    let img = render(CGFloat(px))
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(x: 0, y: 0, width: px, height: px), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent("icon_\(name).png"))
}
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil"); p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try! p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print("icône écrite : \(out.path)")
