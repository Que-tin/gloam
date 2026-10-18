// Renders the disk image's window background (560 × 360 pt, at 1× and 2×): a dusk sky from violet
// to ember, a soft arrow from where the app sits to where Applications sits, and one line saying
// what to do. Kept as code, like the icon, so it is reviewable. Mid-tone where the icon labels
// sit, because Finder draws them itself, black or white by appearance: the plum there gives
// black 5:1 and white 4.2:1 contrast (Gloam's dark surface left black labels unreadable).
// The icon positions here must match the Finder layout in build-app.sh.
// Usage: swift scripts/make-dmg-background.swift <output-dir>  (writes background.png, background@2x.png)

import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".build/dmg-background")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let size = CGSize(width: 560, height: 360)
let app = CGPoint(x: 150, y: 140), applications = CGPoint(x: 410, y: 140)  // icon centres, top-left origin

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func render(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    // In points, flipped so positions read like Finder's (origin top left); text knows it's flipped.
    let cg = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    cg.translateBy(x: 0, y: size.height * scale)
    cg.scaleBy(x: scale, y: -scale)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)

    // The sky, top to bottom (flipped, so 90° runs downwards), and the last of the sun below it.
    NSGradient(colors: [color(0x5E5383), color(0x93708F), color(0xC98A6E)], atLocations: [0, 0.55, 1],
               colorSpace: .sRGB)!.draw(in: NSRect(origin: .zero, size: size), angle: 90)
    NSGradient(colors: [color(0xFFB070, 0.35), color(0xFFB070, 0)])!
        .draw(fromCenter: CGPoint(x: size.width / 2, y: size.height + 40), radius: 0,
              toCenter: CGPoint(x: size.width / 2, y: size.height + 40), radius: 220, options: [])

    // The arrow: a gentle arc from the app towards Applications, ending in an open head.
    let start = CGPoint(x: app.x + 82, y: app.y), end = CGPoint(x: applications.x - 82, y: app.y)
    let arrow = NSBezierPath()
    arrow.move(to: start)
    arrow.curve(to: end, controlPoint1: CGPoint(x: start.x + 30, y: start.y - 18), controlPoint2: CGPoint(x: end.x - 30, y: end.y - 18))
    arrow.move(to: CGPoint(x: end.x - 11, y: end.y - 9))
    arrow.line(to: end)
    arrow.line(to: CGPoint(x: end.x - 12, y: end.y + 7))
    arrow.lineWidth = 2.5
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    color(0xFFF6EC, 0.75).setStroke()
    arrow.stroke()

    // The one instruction, under the labels.
    let base = NSFont.systemFont(ofSize: 15, weight: .medium)
    let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 15) } ?? base
    let text = NSAttributedString(string: "Drag Gloam into Applications", attributes: [
        .font: font, .foregroundColor: color(0x2A1405, 0.85), .kern: 0.2,
    ])
    let bounds = text.size()
    text.draw(at: CGPoint(x: (size.width - bounds.width) / 2, y: 278))

    NSGraphicsContext.restoreGraphicsState()
    rep.size = size
    return rep
}

for (scale, name) in [(CGFloat(1), "background.png"), (2, "background@2x.png")] {
    try render(scale: scale).representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
}
