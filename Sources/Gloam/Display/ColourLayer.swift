// Tints through each display's colour layer: the per-display accessibility matrix macOS's own
// Color Filters use (SkyLight's `SLSSetAccessibilityAdjustments`, private). Real blue removal,
// blacks stay black, the calibration untouched, on every Mac: gamma tables, used before, are
// ignored on M5 Pro and M5 Max with macOS 26 and later (an open Apple bug), and were reset by macOS
// on wakes and reconfigurations (read back, recaptured, repaired when left black).
//
// Measured on macOS 27 (built-in XDR panel and a monitor): the matrix works on linear light
// (`ColourMatrix`); it shows at the screen's next frame, so a still screen waited seconds for it
// (`Redraw` draws one); it stays through sleep, the built-in switching off and a monitor plugged
// in, and is gone after a restart; it is not in screenshots; HDR video is tinted with the rest;
// ~0.02 ms a write. It also outlives the process that set it: a crash would leave the tint on.
// A global write (no display named) clears every display's matrix, which is how it is restored.
//
// A display's matrix replaces the system Color Filter on it (grayscale vanished), so the filter
// is carried in (`ColourMatrix`) and is what "neutral" restores. Changing it, macOS writes it
// globally, clearing Gloam's: announced on the Darwin center, and written again (`filterChanged`).

import ColourFilter
import CoreGraphics
import Foundation
import GloamCore

final class ColourLayer {
    private typealias Set = @convention(c) (CFDictionary) -> Int32
    /// The call and its two keys, nil where this macOS lacks them (nothing is tinted then).
    private static let api: (set: Set, matrix: CFString, display: CFString)? = {
        guard let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let set = dlsym(skyLight, "SLSSetAccessibilityAdjustments"),
              let matrix = dlsym(skyLight, "kSLSAccessibilityAdjustmentMatrix"),
              let display = dlsym(skyLight, "kSLSAccessibilityTargetDisplay") else { return nil }
        return (unsafeBitCast(set, to: Set.self), matrix.load(as: CFString.self), display.load(as: CFString.self))
    }()

    /// Showcase runs never touch the screen.
    private let live = !Debug.isShowcase
    private var spaces: [CGDirectDisplayID: LinearRGB] = [:]
    /// Each display's matrix as last written: the same again is a WindowServer call for nothing.
    private var written: [CGDirectDisplayID: [Float]] = [:]
    /// The system Color Filter, identity when none is on.
    private var filter = ColourLayer.systemFilter()

    /// Shows each listed display at its tint and the rest neutral. Returns the displays whose
    /// matrix changed: they need a new frame to show it (`Redraw`).
    func apply(_ tints: [CGDirectDisplayID: Tint]) -> Swift.Set<CGDirectDisplayID> {
        guard live else { return [] }
        var changed = Swift.Set<CGDirectDisplayID>()
        for id in Swift.Set(tints.keys).union(written.keys) {
            let matrix = ColourMatrix.shown(tints[id] ?? .neutral, in: colourSpace(id), after: filter)
            // Never written, a display shows the filter macOS set for all.
            guard !ColourMatrix.same(matrix, written[id] ?? filter) else { continue }
            Self.write(matrix, to: id)
            written[id] = matrix
            changed.insert(id)
        }
        return changed
    }

    /// Every display neutral, on quit: one global write clears them all.
    func restore() {
        if live { Self.clearAll() }
        written = [:]
    }

    /// Screens were added, removed or rearranged: everything is cleared (an id may now name
    /// another screen, or a screen come back with last night's matrix, also one unplugged while
    /// tinted after the evening ended) and written afresh by the next push.
    func displaysChanged() {
        if live { Self.clearAll() }
        written = [:]
        spaces = [:]
    }

    /// A colour profile changed: the gains are worked out afresh in the new colour space.
    func profileChanged() { spaces = [:] }

    /// The system Color Filter changed, and macOS's global write cleared every display's matrix:
    /// each is written afresh, carrying the new filter, by the next push.
    func filterChanged() {
        filter = Self.systemFilter()
        written = [:]
    }

    /// Clears every display's matrix, whoever set it, back to the system Color Filter alone: at
    /// launch (a crash may have left one) and on quit.
    static func clearAll() {
        guard let api else { return }
        var matrix = systemFilter()
        _ = api.set([api.matrix: Data(bytes: &matrix, count: 36) as CFData] as CFDictionary)
    }

    private static func systemFilter() -> [Float] {
        var matrix = ColourMatrix.identity
        return gloamSystemColourFilter(&matrix) ? matrix : ColourMatrix.identity
    }

    private static func write(_ matrix: [Float], to id: CGDirectDisplayID) {
        guard let api else { return }
        var matrix = matrix
        _ = api.set([api.matrix: Data(bytes: &matrix, count: 36) as CFData, api.display: NSNumber(value: Int64(id))] as CFDictionary)
    }

    /// The display's linear RGB, from its ColorSync profile's primaries, or sRGB when the
    /// profile can't be used.
    func colourSpace(_ id: CGDirectDisplayID) -> LinearRGB {
        if let known = spaces[id] { return known }
        var result = Kelvin.sRGB
        if let linear = CGColorSpaceCreateLinearized(CGDisplayCopyColorSpace(id)),
           let xyz = CGColorSpace(name: CGColorSpace.genericXYZ) {
            // Display → XYZ doesn't clip (the other direction does; see Kelvin.linearRGB).
            let primary = { (rgb: [CGFloat]) -> XYZ? in
                guard let v = CGColor(colorSpace: linear, components: rgb + [1])?
                    .converted(to: xyz, intent: .absoluteColorimetric, options: nil)?.components,
                    v.count >= 3 else { return nil }
                return XYZ(x: v[0], y: v[1], z: v[2])
            }
            if let r = primary([1, 0, 0]), let g = primary([0, 1, 0]), let b = primary([0, 0, 1]),
               let convert = Kelvin.linearRGB(red: r, green: g, blue: b) {
                // A profile that can't place daylight sensibly falls back to sRGB.
                let white = convert(Kelvin.xyz(Kelvin.daylight))
                if [white.red, white.green, white.blue].allSatisfy({ $0 > 0 }) { result = convert }
            }
        }
        spaces[id] = result
        return result
    }
}
