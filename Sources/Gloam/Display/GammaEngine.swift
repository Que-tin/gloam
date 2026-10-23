// Tints through each display's gamma transfer table: real blue removal, blacks stay black.
//
// The table is multiplied onto the display's ColorSync calibration rather than an identity
// ramp, so calibrated monitors stay calibrated. The calibration is read before Gloam first
// tints a display (and again after every reconfiguration, which usually restores ColorSync
// first; a table that still shows Gloam's own last write, exactly or resampled, keeps the
// calibration it had, and one left so overnight is put back as soon as it's seen). If
// it looks tinted, because another tinting app owns the table, identity is used instead:
// baking someone else's tint into the base would double the warmth until relaunch.
//
// macOS occasionally leaves a table all zeros, a black screen: Gloam puts its last write back, or
// ColorSync's own restore when that doesn't take (`repairBlank`).
//
// Gains are computed in each display's own colour space (P3 for built-in screens), read from
// its ColorSync profile; see ColorTemperature.swift for why sRGB gains look wrong on P3.

import CoreGraphics
import Foundation
import GloamCore

final class GammaEngine: TintEngine {
    private struct Ramp {
        var red, green, blue: [CGGammaValue]
        var top: [CGGammaValue] { [red.last ?? 0, green.last ?? 0, blue.last ?? 0] }
    }
    private var calibration: [CGDirectDisplayID: Ramp] = [:]
    private var spaces: [CGDirectDisplayID: LinearRGB] = [:]
    private var tinted: Set<CGDirectDisplayID> = []
    /// Each display's table as last written: its top notices another app's write; whole, a
    /// tinted one is what `previous` matches entry for entry (matching the top alone also matched
    /// any fresh profile ending at full output, so a re-profiled display kept its old curve).
    private var lastWrite: [CGDirectDisplayID: Ramp] = [:]
    /// The gain each display shows now: writing the same table again (a brightness-only change on
    /// a backlight-dimmed display, every clock tick) is a WindowServer call for nothing. Dropped
    /// whenever the table may have changed under Gloam (overwritten, reconfigured, reset).
    private var gains: [CGDirectDisplayID: RGB] = [:]
    /// What `displaysChanged` dropped, for a display whose table turns out to be untouched.
    private struct Kept { var calibration, tint: Ramp; var at: Date }
    private var previous: [CGDirectDisplayID: Kept] = [:]
    /// A display away longer than this comes back to a table that isn't last night's: its entry
    /// goes rather than wait to overwrite whatever another app wrote meanwhile.
    private static let keptFor: TimeInterval = 86_400

    func apply(_ tints: [CGDirectDisplayID: Tint]) {
        let active = tints.filter { !$0.value.isNeutral }
        guard !active.isEmpty else { return reset() }
        everTinted = true
        for id in tinted.subtracting(active.keys) {
            if let base = calibration[id] { write(base, gain: .white, to: id) }
        }
        for (id, tint) in active {
            if let base = calibration[id] ?? capture(id) { write(base, gain: Kelvin.displayGain(tint, in: colourSpace(id)), to: id) }
        }
        tinted = Set(active.keys)
        settlePrevious(except: Set(active.keys))  // a screen Settings leaves alone too
    }

    /// True when a display we tinted no longer shows our table: another app (any app) has
    /// written its own since. Checked just before Gloam re-applies.
    func isOverwritten() -> Bool {
        for id in tinted {
            // The size written (the calibration's): asking the capacity cost a fifth of a tick.
            guard let ours = lastWrite[id], let read = table(id, size: ours.red.count) else { continue }
            if zip(read.top, ours.top).contains(where: { abs($0 - $1) > 0.01 }) {
                gains = [:]  // the next apply must write, not skip
                return true
            }
        }
        return false
    }

    /// A table Gloam wrote that now reads black (macOS occasionally leaves one all zeros: a black
    /// screen, also by day when nothing is tinted and `isOverwritten` doesn't look) gets Gloam's
    /// last write back; if that doesn't take, ColorSync's own restore, and everything is captured
    /// and written afresh. True when the caller must push again.
    func repairBlank() -> Bool {
        var repaired = false
        for (id, ours) in lastWrite where ours.top.contains(where: { $0 > 0.05 }) {
            guard let read = table(id, size: ours.red.count), read.top.allSatisfy({ $0 < 0.01 }) else { continue }
            CGSetDisplayTransferByTable(id, UInt32(ours.red.count), ours.red, ours.green, ours.blue)
            if let again = table(id, size: ours.red.count), again.top.allSatisfy({ $0 < 0.01 }) {
                CGDisplayRestoreColorSyncSettings()
                calibration.removeAll()
                lastWrite.removeAll()
                gains = [:]
                return true  // every display's table is ColorSync's now
            }
            gains = [:]
            repaired = true
        }
        return repaired
    }

    /// Puts the displays Gloam tinted back to their calibration, one by one: the global
    /// ColorSync restore would also wipe another app's table on displays Gloam leaves alone.
    /// A table a reconfiguration left showing Gloam's tint (the screens slept while the evening
    /// ended, and woke without macOS resetting it) gets its calibration back too: else last
    /// night's warmth stayed on all day.
    func reset() {
        for id in tinted { if let base = calibration[id] { write(base, gain: .white, to: id) } }
        tinted = []
        settlePrevious(except: [])
    }

    /// A kept table still showing Gloam's tint gets its calibration back; one macOS reset is
    /// dropped. A display that's offline (lid closed, unplugged) or can't be read keeps its entry
    /// until it's back: dropped then, the built-in reopened in the morning with last night's tint
    /// and nothing knew it was Gloam's. Tinted displays keep theirs for `capture`.
    private func settlePrevious(except tinting: Set<CGDirectDisplayID>) {
        for (id, kept) in previous where !tinting.contains(id) {
            if Date().timeIntervalSince(kept.at) > Self.keptFor { previous[id] = nil; continue }
            guard CGDisplayIsOnline(id) != 0, let read = table(id, size: Int(CGDisplayGammaTableCapacity(id))) else { continue }
            if Self.isTint(read, kept) { write(kept.calibration, gain: .white, to: id) }
            previous[id] = nil
        }
    }

    /// A display back with a table still showing Gloam's tint from before a reconfiguration gets
    /// its calibration now, not after the changes settle: called as the change arrives, while the
    /// screen may still be dark, when nothing is tinted (the morning, Gloam off).
    func settleKept() { settlePrevious(except: tinted) }

    /// Gloam wrote a table this run: only then does quitting reset them all, which would also
    /// undo another app's (a quit from Welcome, say, or a day spent off).
    private var everTinted = false

    /// On quit: the full ColorSync restore, so nothing of Gloam's can linger.
    func restoreAll() {
        if everTinted { CGDisplayRestoreColorSyncSettings() }
        tinted = []
    }

    /// Forgets every per-display base without writing: writing the old base back (as this once
    /// did) re-captured it as the "new" calibration, so a re-profiled monitor kept its old curve,
    /// and could write to displays that were gone. macOS restores each display's profile on a
    /// reconfiguration itself; the next apply captures that fresh. Merged, not replaced: two
    /// changes with no apply between them (monitors dropping out while the screens sleep) would
    /// otherwise forget what the first one kept.
    func displaysChanged() {
        for (id, base) in calibration where tinted.contains(id) {
            if let tint = lastWrite[id] { previous[id] = Kept(calibration: base, tint: tint, at: Date()) }
        }
        tinted = []
        lastWrite = [:]
        gains = [:]
        calibration.removeAll()
        spaces.removeAll()
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

    private func write(_ base: Ramp, gain: RGB, to id: CGDirectDisplayID) {
        // Unchanged to the eye: room light drifts the target by hair's breadths every tick, and a
        // monitor dimmed by signal would get a table write every 5 s all night. Against the last
        // write, so slow drift still lands; back to white is always exact.
        if let last = gains[id], gain == .white ? last == gain
            : max(abs(last.red - gain.red), abs(last.green - gain.green), abs(last.blue - gain.blue)) < 1.0 / 4096 { return }
        gains[id] = gain
        let r = base.red.map { $0 * CGGammaValue(gain.red) }
        let g = base.green.map { $0 * CGGammaValue(gain.green) }
        let b = base.blue.map { $0 * CGGammaValue(gain.blue) }
        CGSetDisplayTransferByTable(id, UInt32(r.count), r, g, b)
        lastWrite[id] = Ramp(red: r, green: g, blue: b)
    }

    private func capture(_ id: CGDirectDisplayID) -> Ramp? {
        let capacity = Int(CGDisplayGammaTableCapacity(id))
        guard capacity > 1 else { return nil }
        let read = table(id, size: capacity)
        let ramp: Ramp
        // A wake doesn't always reset the table: one still showing Gloam's own last write is
        // Gloam's tint, and capturing it as the calibration would tint everything twice.
        if let read, let kept = previous.removeValue(forKey: id),
           Date().timeIntervalSince(kept.at) <= Self.keptFor, Self.isTint(read, kept) {
            ramp = kept.calibration
        } else if let read, read.top.allSatisfy({ $0 > 0.92 }) {
            ramp = read  // a calibration curve ends near full output; a warm or dimmed table doesn't
        } else {
            let identity = (0..<capacity).map { CGGammaValue($0) / CGGammaValue(capacity - 1) }
            ramp = Ramp(red: identity, green: identity, blue: identity)
        }
        calibration[id] = ramp
        return ramp
    }

    /// The display's table now, as many entries as it reports; nil when it can't be read.
    private func table(_ id: CGDirectDisplayID, size n: Int) -> Ramp? {
        guard n > 1 else { return nil }
        var r = [CGGammaValue](repeating: 0, count: n), g = r, b = r
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(id, UInt32(n), &r, &g, &b, &count) == .success, count > 1 else { return nil }
        let k = Int(count)
        return Ramp(red: Array(r.prefix(k)), green: Array(g.prefix(k)), blue: Array(b.prefix(k)))
    }

    /// Gloam's tint, entry for entry, or as macOS hands it back slightly changed (the whole curve
    /// within 0.01) or resampled to another size (its top within 0.01 of the tint's, where the
    /// tint's top isn't the calibration's, so a profile macOS put back can't pass for it).
    /// Matching only exact copies, a resampled table kept last night's warmth all day; matching
    /// the top alone at the same size could take another app's warm table for Gloam's.
    private static func isTint(_ read: Ramp, _ kept: Kept) -> Bool {
        if same(read, kept.tint) { return true }
        let near = { (a: [CGGammaValue], b: [CGGammaValue]) in zip(a, b).allSatisfy { abs($0 - $1) <= 0.01 } }
        if read.red.count == kept.tint.red.count {
            return near(read.red, kept.tint.red) && near(read.green, kept.tint.green) && near(read.blue, kept.tint.blue)
        }
        return near(read.top, kept.tint.top) && !near(kept.tint.top, kept.calibration.top)
    }

    private static func same(_ read: Ramp, _ ours: Ramp) -> Bool {
        read.red.count == ours.red.count && [(read.red, ours.red), (read.green, ours.green), (read.blue, ours.blue)]
            .allSatisfy { zip($0, $1).allSatisfy { abs($0 - $1) < 0.005 } }
    }
}
