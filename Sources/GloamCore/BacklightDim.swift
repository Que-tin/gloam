// Dims a display by its backlight instead of its signal, relative to whatever brightness the
// user (or auto-brightness) had set: the "baseline".
//
// Why the backlight: a dimmed signal keeps the backlight at full power and drives the liquid
// crystal into its slow dark range (light text on dark backgrounds smears), crushes shadows
// below ~30%, and on some chips gamma tables no longer work at all. The backlight is the lever
// the brightness keys use: no smearing, no banding, less power, and it reaches the ~40 cd/m²
// a dark room asks for. Dedicated brightness tools dim this way for the same reasons.
//
// Why a baseline and not a level: the slider belongs to the user and to auto-brightness.
// Gloam only ever applies a fraction to what it finds, and when something else moves the
// backlight (a key press, a brighter room) it adopts the move at once, keeping its fraction
// relative to the new level rather than fighting it. The baseline is therefore scaled by the
// same ratio the outside move had; it may exceed 1 on paper (the user went to full brightness
// at night), which just means "full brightness, until the schedule changes".

import Foundation

public struct BacklightDim: Equatable, Codable, Sendable {
    /// The light (0…1 of the display's maximum, linear) the display would show undimmed, and
    /// what the morning restores.
    public private(set) var baseline: Double
    /// What Gloam last wrote, while it is dimming; nil when it is leaving the backlight alone.
    public private(set) var written: Double?
    /// The fraction that went with `written`.
    public private(set) var fraction = 1.0
    /// The slider value that went with the baseline when dimming began, for an exact restore
    /// (writing the light back lands a step low); dropped once an outside move is adopted.
    public var baselineLevel: Double?
    /// The light floor an outside move set: where the user put the light while Gloam was holding
    /// it at the floor (a press up must not be written straight back down), or below the floor.
    /// Such a press says "this much light now", not "my day is brighter": scaling the baseline by
    /// it grew the morning level with every press, up to full brightness.
    private var heldFloor: Double?
    /// The display's own step (a DDC monitor's 1/100): its rounded read-back of a write is the
    /// write, not an outside move. 0 for displays macOS controls.
    public var step = 0.0
    /// The light floor in force: `floorLight` by default, eased towards `deepestFloorLight` when
    /// the user's Dimmest setting goes past the recommended night (their consent to a dimmer
    /// screen). Set by the controller on every change; not saved (a relaunch sets it again).
    public var lightFloor = Self.floorLight

    /// Light is never taken below this fraction of the display's maximum (about 40 cd/m² on a
    /// 500-nit panel: comfortable for sustained smartphone reading in low room light, Na & Suk
    /// 2015; evening viewers preferred 21–75 cd/m² under 13–62 lx, Zhou et al. 2021).
    /// See docs/science.md.
    public static let floorLight = 0.08
    /// How low the floor goes at the deepest Dimmest setting (~15 cd/m² on a 500-nit panel):
    /// below the comfortable range, which is why only an explicit setting past the recommended
    /// night reaches it.
    public static let deepestFloorLight = 0.03
    /// Readings this close to what was written are Gloam's own write, not an outside move
    /// (relative, because a key step near the bottom of the range moves the light very little).
    public func same(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= max(0.004, step, 0.03 * max(a, b)) }

    public init(baseline: Double, step: Double = 0) {
        self.baseline = baseline
        self.step = step
    }

    public var isDimming: Bool { written != nil }

    /// Feed every reading of the backlight. Undimmed, the baseline simply follows the system.
    /// Dimmed, a reading away from what was written is an outside move, adopted. On the curve
    /// it scales the baseline by the move's ratio, so the fraction now applies to the new level;
    /// against the floor it moves the floor instead (`heldFloor`), and the baseline only grows to
    /// meet it, unless the move went below the curve itself: then the curve follows it down,
    /// or the next write would put back the light the user just took away.
    public mutating func observe(light: Double) {
        guard light.isFinite, light >= 0 else { return }
        guard let w = written else { return baseline = light }
        guard !same(light, w) else { return }
        let atFloor = w > baseline * fraction * 1.001 + 1e-9  // the curve wanted less than was written
        if atFloor && light >= baseline * fraction {
            heldFloor = light
            baseline = max(baseline, light)
        } else if atFloor {
            baseline = light / fraction  // fraction > 0: the curve wanted less than the floor
            heldFloor = light < lightFloor ? light : nil
        } else {
            baseline = w > 0 ? baseline * light / w : fraction > 0 ? light / fraction : light
            heldFloor = light < lightFloor ? light : nil
        }
        baselineLevel = nil
        written = light
    }

    /// The light floor, moved to where the user put the light themselves.
    private var floor: Double { heldFloor ?? lightFloor }

    /// The light to write for `fraction` (1 = undimmed, 0.27 = about a quarter of the light),
    /// or nil when the backlight already shows it. `fraction` 1 restores the baseline and
    /// releases the backlight; below 1 it is held at or above the light floor, and never raised
    /// above the light found. Call it again if the write fails: nothing is recorded until it succeeds.
    ///
    /// `written` is only ever what the panel shows. Recording a skipped step as written let a
    /// slow ramp of small steps never reach the panel, and the morning restore be skipped.
    public func light(for fraction: Double) -> Double? {
        let f = (0.0...1.0).clamp(fraction)
        if f >= 1 { return written == nil ? nil : min(1, baseline) }
        let target = target(for: f)
        return same(target, written ?? baseline) ? nil : target
    }

    /// The light `fraction` asks for, whether or not the panel shows it already.
    public func target(for fraction: Double) -> Double {
        let f = (0.0...1.0).clamp(fraction)
        return f >= 1 ? min(1, baseline) : min(1, baseline, max(floor, baseline * f))
    }

    /// For a display that takes whole steps (`step` > 0) a few times a second: the next light to
    /// write toward `fraction`, one step from what it shows, and rounded up, so the signal only
    /// ever has to dim the rest (a jump of several steps showed as a jolt), though never above
    /// the light found. nil when it's there. `fraction` is what to record with it (`wrote`): the
    /// step's own place on the curve, so `observe` scales the baseline after an outside move,
    /// except where the floor holds it, and 1 for the write that ends a release.
    /// Without a step, `light(for:)` in one go.
    public func nextStep(for fraction: Double) -> (light: Double, fraction: Double)? {
        guard step > 0 else { return light(for: fraction).map { ($0, fraction) } }
        let release = fraction >= 1
        if release && written == nil { return nil }
        let target = target(for: fraction)
        let goal = release ? target : min(1, baseline, (target / step - 1e-6).rounded(.up) * step)
        let from = written ?? min(1, baseline)
        let gap = abs(goal - from)
        if gap <= step / 2 { return release ? (goal, 1) : nil }  // a release is recorded even there
        let next = gap <= step * 1.5 ? goal : from + (goal > from ? step : -step)
        if next == goal && release { return (next, 1) }
        if next == goal && fraction < lowestFraction { return (next, fraction) }
        return (next, min(0.999, next / max(baseline, next)))
    }

    /// Records a write of `light(for:)` that reached the panel.
    public mutating func wrote(_ light: Double, for fraction: Double) {
        let done = fraction >= 1
        written = done ? nil : light
        self.fraction = done ? 1 : fraction
        if done { heldFloor = nil }
    }

    // Saved for crash recovery without `lightFloor`, which follows the settings, not the panel.
    private enum CodingKeys: String, CodingKey { case baseline, written, fraction, baselineLevel, heldFloor, step }

    /// The lowest fraction this display can be dimmed to before the light floor holds it.
    public var lowestFraction: Double {
        baseline > 0 ? min(1, floor / baseline) : 1
    }
}
