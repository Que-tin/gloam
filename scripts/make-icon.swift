// Renders the Gloam app icon ("Dusk Layers": nested squircles stepping from a slate dusk rim
// through plum and ember to a lamp-warm core) at every size macOS wants and assembles
// AppIcon.icns. Kept as code so the icon is reviewable and reproducible.
// Usage: swift scripts/make-icon.swift <output-dir>
//
// The bands are light, not paint: each glows onto the band outside it and shades gently
// towards the core, and the layers sit progressively lower, like a sun going down, which also
// keeps the stack from reading as a target. Colours are sampled from a clear dusk sky, zenith
// to horizon. Two detail levels: full (≥64px: six layers, glow) and minimal (≤32px: three
// bands and a core on a whole-pixel grid, no blur, so edges stay crisp).
// Shadows are set in device space, which the CTM does not scale, so every offset/blur is
// multiplied by px/1024 by hand.

import AppKit
import SwiftUI

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".build/icon")
let iconset = out.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

/// Continuous-corner rounded square, the curve macOS uses for app icons; the radius is
/// proportional so every layer is the same shape, only smaller (a circle would read as a target).
func squircle(_ rect: CGRect) -> CGPath {
    Path(roundedRect: rect, cornerRadius: rect.width * 0.2237, style: .continuous).cgPath
}

/// One layer: its rect on the 1024 canvas (y up) and its colour at the top and bottom edge.
struct Layer { var rect: CGRect; var top: UInt32; var bottom: UInt32 }

/// Square of side `side` centred horizontally, its centre `drop` below the canvas centre.
func layer(_ side: CGFloat, drop: CGFloat, _ top: UInt32, _ bottom: UInt32) -> Layer {
    Layer(rect: CGRect(x: 512 - side / 2, y: 512 - drop - side / 2, width: side, height: side), top: top, bottom: bottom)
}

// Zenith → horizon. The last entry is the core; its colours are the lens's centre and edge.
let fullLayers = [
    layer(824, drop: 0, 0x171C3C, 0x2B2F5A),     // slate-indigo sky
    layer(692, drop: 16, 0x37315E, 0x4A3868),    // violet
    layer(560, drop: 34, 0x6E3D69, 0x8C4569),    // plum
    layer(432, drop: 52, 0xBE5257, 0xD7634D),    // rose ember
    layer(306, drop: 70, 0xF0863B, 0xFA9C45),    // ember
    layer(184, drop: 86, 0xFFF4DC, 0xFFBA62),    // lamp-warm core
]
// ≤32px: a hand-placed grid in whole pixels (x, y from the bottom, side), so every straight
// edge is crisp; the body is snapped to the pixel grid, a hair off the 824/1024 proportion.
func minimalLayers(_ px: Int) -> [Layer] {
    let grid: [(CGFloat, CGFloat, CGFloat)] = px == 16
        ? [(2, 2, 12), (3, 3, 10), (5, 4, 6), (6, 5, 4)]
        : [(3, 3, 26), (6, 5, 20), (10, 7, 12), (13, 9, 6)]
    let u = 1024 / CGFloat(px == 16 ? 16 : 32)
    let colours: [(UInt32, UInt32)] = [(0x1F2446, 0x2C3058), (0x6A3C68, 0x86456A), (0xE3703F, 0xF28A40), (0xFFF6E2, 0xFFD08A)]
    return zip(grid, colours).map { g, c in
        Layer(rect: CGRect(x: g.0 * u, y: g.1 * u, width: g.2 * u, height: g.2 * u), top: c.0, bottom: c.1)
    }
}

func render(_ px: Int) -> Data {
    let s = CGFloat(px), k = s / 1024
    let minimal = px <= 32
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: k, y: k)
    func shadow(_ blur: CGFloat, _ c: CGColor, dy: CGFloat = 0) {
        ctx.setShadow(offset: CGSize(width: 0, height: dy * k), blur: blur * k, color: c)
    }
    func vertical(_ top: CGColor, _ bottom: CGColor, _ r: CGRect) {
        let g = CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: r.midX, y: r.maxY), end: CGPoint(x: r.midX, y: r.minY),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    let layers = minimal ? minimalLayers(px) : fullLayers
    let shape = squircle(layers[0].rect)

    ctx.saveGState()
    shadow(28, color(0x000000, 0.4), dy: -12)
    ctx.addPath(shape); ctx.setFillColor(color(0x101226)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()

    for (i, l) in layers.enumerated() {
        let path = squircle(l.rect), isCore = i == layers.count - 1
        if i > 0 && !minimal {
            // Light spill: the band glows onto the darker band around it, strongest from the core.
            ctx.saveGState()
            shadow(isCore ? 80 : 26, color(l.bottom, isCore ? 0.75 : 0.4))
            ctx.addPath(path); ctx.setFillColor(color(l.bottom)); ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        if isCore && !minimal {
            // A lens, not a tile: white-hot just below centre, falling off to amber at the edge.
            let c = CGPoint(x: l.rect.midX, y: l.rect.midY - l.rect.height * 0.08)
            let g = CGGradient(colorsSpace: space,
                               colors: [color(0xFFFCF4), color(l.top), color(0xFFDDA0), color(l.bottom)] as CFArray,
                               locations: [0, 0.3, 0.62, 1])!
            ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: l.rect.width * 0.72,
                                   options: [.drawsAfterEndLocation])
        } else {
            vertical(color(l.top), color(l.bottom), l.rect)
        }
        ctx.restoreGState()
    }

    if !minimal {
        // Lamplight falling off across the bands, so they shade towards the core like lit air.
        let core = layers[layers.count - 1].rect
        let fall = CGGradient(colorsSpace: space, colors: [color(0xFFB060, 0.22), color(0xFF9050, 0.08), color(0xFF9050, 0)] as CFArray,
                              locations: [0, 0.5, 1])!
        ctx.setBlendMode(.screen)
        ctx.drawRadialGradient(fall, startCenter: CGPoint(x: core.midX, y: core.midY), startRadius: 0,
                               endCenter: CGPoint(x: core.midX, y: core.midY), endRadius: 560, options: [])
        ctx.setBlendMode(.normal)

        // Top sheen: the face catches a little sky.
        let sheen = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.10), color(0xFFFFFF, 0)] as CFArray,
                               locations: [0, 1])!
        ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 600), options: [])
    }
    ctx.restoreGState()

    // Rim light: a top-lit hairline, as on the popover panel.
    ctx.saveGState()
    ctx.addPath(shape); ctx.setLineWidth(minimal ? 10 : 5); ctx.replacePathWithStrokedPath(); ctx.clip()
    let rim = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.24), color(0xFFFFFF, 0.05), color(0xFFFFFF, 0.03)] as CFArray,
                         locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(rim, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
try render(1024).write(to: out.appendingPathComponent("AppIcon.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", out.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
exit(iconutil.terminationStatus)
