// Renders the repository's social preview (1280 × 640, what a shared GitHub link shows): Gloam's
// dark surface lit like dusk, the icon, the wordmark and the tagline. Kept as code, like the icon,
// so it can be redone when the tagline changes. Upload it under the repository's Settings ›
// General › Social preview (GitHub has no API for it).
// Usage: swift scripts/make-social-preview.swift [output.png]   (default assets/social-preview.png)

import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "assets/social-preview.png"
let size = CGSize(width: 1280, height: 640)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
}

guard let icon = NSImage(contentsOfFile: "assets/icon.png"),
      let wordmark = NSImage(contentsOfFile: "assets/wordmark-on-dark.svg") else {
    fatalError("Run from the repository root: assets/icon.png and assets/wordmark-on-dark.svg are needed.")
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
let cg = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
cg.translateBy(x: 0, y: size.height)
cg.scaleBy(x: 1, y: -1)  // top-left origin, like a layout
NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)

// The surface, dusk rising from below, and the lamp's glow behind the icon.
color(0x0D0B0A).setFill()
NSRect(origin: .zero, size: size).fill()
NSGradient(colors: [color(0x8C4569, 0.32), color(0x37315E, 0.14), color(0x0D0B0A, 0)])!
    .draw(fromCenter: CGPoint(x: size.width / 2, y: size.height + 120), radius: 0,
          toCenter: CGPoint(x: size.width / 2, y: size.height + 120), radius: 760, options: [])
let iconRect = CGRect(x: 208, y: 160, width: 260, height: 260)
NSGradient(colors: [color(0xFF9A3C, 0.28), color(0xFF9A3C, 0)])!
    .draw(fromCenter: CGPoint(x: iconRect.midX, y: iconRect.midY), radius: 0,
          toCenter: CGPoint(x: iconRect.midX, y: iconRect.midY), radius: 260, options: [])
icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)

// The wordmark (its box includes the descender), then the tagline under it.
let markWidth: CGFloat = 520
let markRect = CGRect(x: 538, y: 170, width: markWidth, height: markWidth * wordmark.size.height / wordmark.size.width)
wordmark.draw(in: markRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
let lines: [(String, NSFont, NSColor, CGFloat)] = [
    ("A blue light filter for your Mac", rounded(36, .semibold), color(0xF4E9DC), markRect.maxY + 22),
    ("Warms and dims the screen from sunset to bedtime", rounded(24, .regular), color(0xF4E9DC, 0.62), markRect.maxY + 74),
    ("Free · open source · no tracking", rounded(24, .regular), color(0xF4E9DC, 0.62), markRect.maxY + 108),
]
for (text, font, ink, y) in lines {
    NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: ink]).draw(at: CGPoint(x: 544, y: y))
}

NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")
