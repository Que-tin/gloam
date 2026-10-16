// Gloam's menu-bar glyph: the app icon's dusk layers reduced to a monochrome template. Three
// nested continuous-corner squircles; as the evening deepens they light one at a time from the
// core outward (day: thin outlines · sunset: core filled · wind-down: middle band thickens ·
// night: rim thickens), always with a 1pt dark gap between layers so night never collapses
// into a filled square. Stepping aside for an excepted app shows the core as a small hollow
// square; off adds an SF-style slash.
//
// Squircles, never circles: concentric circles read as a target or an eye.

import SwiftUI
import AppKit

struct GloamGlyph: View {
    enum Mode { case running, aside, off }

    var mode: Mode = .running
    /// 0 = day (outlines only) … 1 = night (all three layers lit). The four stages sit at
    /// 0, ⅓, ⅔ and 1.
    var depth: Double = 0

    static let size: CGFloat = 18
    // Three layers as (half-extent, unlit stroke, lit stroke). Lit strokes are chosen so a 1pt
    // dark gap always separates neighbours: a fully lit glyph must still read as layers, never
    // as a filled square (the first version did, in a 16pt menu bar). The core fills solid.
    static let layers: [(half: CGFloat, unlit: CGFloat, lit: CGFloat)] = [
        (7.5, 1.0, 1.75),   // rim: inner edge 5.75 when lit
        (4.75, 1.0, 1.5),   // middle: outer 4.75 (1pt below the rim), inner 3.25 when lit
        (2.25, 1.0, 2.25),  // core: 1pt below the middle; "lit" fills it
    ]
    static let corner: CGFloat = 0.3        // corner radius as a fraction of the side

    var body: some View {
        let layers = Self.layers, roundness = Self.corner
        return Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            func squircle(_ h: CGFloat, _ k: CGFloat) -> Path {
                Path(roundedRect: CGRect(x: c.x - h, y: c.y - h, width: h * 2, height: h * 2),
                     cornerRadius: h * 2 * k, style: .continuous)
            }
            func ring(_ h: CGFloat, _ w: CGFloat, corner k: CGFloat) {
                guard w < h else { return ctx.fill(squircle(h, k), with: .foreground) }
                var p = squircle(h, k)
                p.addPath(squircle(h - w, k))
                ctx.fill(p, with: .foreground, style: .init(eoFill: true))
            }

            // The evening lights the layers one at a time, core first: depth 0…⅓ the core,
            // ⅓…⅔ the middle, ⅔…1 the rim. Each thickens smoothly from outline to lit band.
            let d = mode == .running ? min(max(depth, 0), 1) * 3 : 0
            for (n, layer) in layers.enumerated() {
                if mode == .aside && n == 2 { continue }
                let litAmount = min(1, max(0, d - Double(2 - n)))
                ring(layer.half, layer.unlit + (layer.lit - layer.unlit) * CGFloat(litAmount), corner: roundness)
            }

            if mode == .aside {
                // Stepping aside for an excepted app: the core becomes a small hollow square.
                ring(1.5, 1, corner: 0.15)
            }

            if mode == .off {
                // Slash with a cut-out halo, the way SF Symbols' ".slash" variants separate it.
                var slash = Path()
                slash.move(to: CGPoint(x: 3, y: 3)); slash.addLine(to: CGPoint(x: 15, y: 15))
                ctx.blendMode = .clear
                ctx.stroke(slash, with: .color(.black), style: .init(lineWidth: 3.5, lineCap: .round))
                ctx.blendMode = .normal
                ctx.stroke(slash, with: .foreground, style: .init(lineWidth: 1.5, lineCap: .round))
            }
        }
        .frame(width: Self.size, height: Self.size)
    }

    private static var cache: [String: NSImage] = [:]

    /// The status-item image, rendered once per mode and 1/24 step of depth. The menu bar
    /// re-evaluates its label on every model change; rendering each time would be wasteful.
    static func cached(mode: Mode, depth: Double) -> NSImage {
        let step = (min(1, max(0, depth)) * 24).rounded() / 24
        let key = "\(mode)-\(step)"
        if let hit = cache[key] { return hit }
        let img = image(mode: mode, depth: step)
        cache[key] = img
        return img
    }

    /// Template NSImage for the status item; macOS tints it for light/dark menu bars.
    private static func image(mode: Mode, depth: Double) -> NSImage {
        let r = ImageRenderer(content: GloamGlyph(mode: mode, depth: depth).foregroundStyle(.black))
        r.scale = 2  // crisp on Retina; 1× screens downsample it cleanly
        let img = r.nsImage ?? NSImage(size: NSSize(width: size, height: size))
        img.isTemplate = true
        img.accessibilityDescription = "Gloam"
        return img
    }
}
