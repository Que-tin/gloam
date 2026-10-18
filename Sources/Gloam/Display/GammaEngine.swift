// Tints through each display's gamma transfer table: real blue removal, blacks stay black.
//
// The table is multiplied onto the display's ColorSync calibration rather than an identity
// ramp, so calibrated monitors stay calibrated. The calibration is read before Gloam first
// tints a display (and again after every reconfiguration, which usually restores ColorSync
// first; a table that still shows Gloam's own last write keeps the calibration it had). If
// it looks tinted, because another tinting app owns the table, identity is used instead:
// baking someone else's tint into the base would double the warmth until relaunch.
//
// Gains are computed in each display's own colour space (P3 for built-in screens), read from
// its ColorSync profile; see ColorTemperature.swift for why sRGB gains look wrong on P3.

import CoreGraphics
import GloamCore

final class GammaEngine: TintEngine {
    private struct Ramp { var red, green, blue: [CGGammaValue] }
    private var calibration: [CGDirectDisplayID: Ramp] = [:]
    private var spaces: [CGDirectDisplayID: LinearRGB] = [:]
    private var tinted: Set<CGDirectDisplayID> = []
    /// The top of each ramp as last written, to notice when something else rewrites it.
    private var written: [CGDirectDisplayID: [CGGammaValue]] = [:]
    /// The whole ramp last written while tinting (never a plain calibration write): only a
    /// table matching it entry for entry is Gloam's own. Matching the top alone also matched any
    /// fresh profile ending at full output, so a re-profiled display kept its old curve.
    private var tintRamp: [CGDirectDisplayID: Ramp] = [:]
    /// The gain each display shows now: writing the same table again (a brightness-only change on
    /// a backlight-dimmed display, every clock tick) is a WindowServer call for nothing. Dropped
    /// whenever the table may have changed under Gloam (overwritten, reconfigured, reset).
    private var gains: [CGDirectDisplayID: RGB] = [:]
    /// What `displaysChanged` dropped, for a display whose table turns out to be untouched.
    private var previous: [CGDirectDisplayID: (calibration: Ramp, tint: Ramp)] = [:]

    func apply(_ tints: [CGDirectDisplayID: Tint]) {
        let active = tints.filter { !$0.value.isNeutral }
        guard !active.isEmpty else { return reset() }
        for id in tinted.subtracting(active.keys) {
            if let base = calibration[id] { write(base, gain: .white, to: id) }
        }
        for (id, tint) in active {
            if let base = calibration[id] ?? capture(id) { write(base, gain: Kelvin.displayGain(tint, in: space(id)), to: id) }
        }
        tinted = Set(active.keys)
    }

    /// True when a display we tinted no longer shows our table: another app (any app) has
    /// written its own since. Checked just before Gloam re-applies.
    func isOverwritten() -> Bool {
        for id in tinted {
            guard let ours = written[id] else { continue }
            let n = Int(CGDisplayGammaTableCapacity(id))
            guard n > 1 else { continue }
            var r = [CGGammaValue](repeating: 0, count: n), g = r, b = r
            var count: UInt32 = 0
            guard CGGetDisplayTransferByTable(id, UInt32(n), &r, &g, &b, &count) == .success, count > 1 else { continue }
            let top = [r[Int(count) - 1], g[Int(count) - 1], b[Int(count) - 1]]
            if zip(top, ours).contains(where: { abs($0 - $1) > 0.01 }) {
                gains = [:]  // the next apply must write, not skip
                return true
            }
        }
        return false
    }

    /// Puts the displays Gloam tinted back to their calibration, one by one: the global
    /// ColorSync restore would also wipe another app's table on displays Gloam leaves alone.
    func reset() {
        for id in tinted { if let base = calibration[id] { write(base, gain: .white, to: id) } }
        tinted = []
    }

    /// On quit: the full ColorSync restore, so nothing of Gloam's can linger.
    func restoreAll() {
        CGDisplayRestoreColorSyncSettings()
        tinted = []
        gains = [:]
    }

    /// Forgets every per-display base without writing: writing the old base back (as this once
    /// did) re-captured it as the "new" calibration, so a re-profiled monitor kept its old curve,
    /// and could write to displays that were gone. macOS restores each display's profile on a
    /// reconfiguration itself; the next apply captures that fresh.
    func displaysChanged() {
        previous = calibration.reduce(into: [:]) { result, entry in
            if let tint = tintRamp[entry.key] { result[entry.key] = (entry.value, tint) }
        }
        tinted = []
        written = [:]
        gains = [:]
        tintRamp = [:]
        calibration.removeAll()
        spaces.removeAll()
    }

    /// The display's linear RGB, from its ColorSync profile's primaries, or sRGB when the
    /// profile can't be used.
    func colourSpace(_ id: CGDirectDisplayID) -> LinearRGB { space(id) }

    private func space(_ id: CGDirectDisplayID) -> LinearRGB {
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

    private func write(_ base: Ramp, gain: RGB, to id: CGDirectDisplayID) {
        guard gains[id] != gain else { return }
        gains[id] = gain
        let r = base.red.map { $0 * CGGammaValue(gain.red) }
        let g = base.green.map { $0 * CGGammaValue(gain.green) }
        let b = base.blue.map { $0 * CGGammaValue(gain.blue) }
        CGSetDisplayTransferByTable(id, UInt32(r.count), r, g, b)
        written[id] = [r.last!, g.last!, b.last!]
        tintRamp[id] = gain == .white ? nil : Ramp(red: r, green: g, blue: b)
    }

    private func capture(_ id: CGDirectDisplayID) -> Ramp? {
        let capacity = Int(CGDisplayGammaTableCapacity(id))
        guard capacity > 1 else { return nil }
        var ramp = Ramp(
            red: .init(repeating: 0, count: capacity),
            green: .init(repeating: 0, count: capacity),
            blue: .init(repeating: 0, count: capacity))
        var count: UInt32 = 0
        let ok = CGGetDisplayTransferByTable(id, UInt32(capacity), &ramp.red, &ramp.green, &ramp.blue, &count) == .success
        let n = Int(count)
        // A wake doesn't always reset the table: one still showing Gloam's own last write is
        // Gloam's tint, and capturing it as the calibration would tint everything twice.
        if ok, n > 1, let (base, tint) = previous.removeValue(forKey: id), tint.red.count == n,
           [(ramp.red, tint.red), (ramp.green, tint.green), (ramp.blue, tint.blue)].allSatisfy({ read, ours in
               zip(read.prefix(n), ours).allSatisfy { abs($0 - $1) < 0.005 }
           }) {
            ramp = base
        } else if ok, n > 1, Self.looksLikeCalibration(ramp, n) {
            ramp = Ramp(red: Array(ramp.red.prefix(n)), green: Array(ramp.green.prefix(n)), blue: Array(ramp.blue.prefix(n)))
        } else {
            let identity = (0..<capacity).map { CGGammaValue($0) / CGGammaValue(capacity - 1) }
            ramp = Ramp(red: identity, green: identity, blue: identity)
        }
        calibration[id] = ramp
        return ramp
    }

    /// A calibration curve ends near full output on every channel; a warm or dimmed table doesn't.
    private static func looksLikeCalibration(_ r: Ramp, _ n: Int) -> Bool {
        [r.red[n - 1], r.green[n - 1], r.blue[n - 1]].allSatisfy { $0 > 0.92 }
    }
}
