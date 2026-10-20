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
// backlight (a key press, a brighter room) it adopts the move at once rather than fighting it.
//
// Tonight's light is a curve through fixed points, straight in log–log between them (each step
// the same share of the light): the end of the ladder (`bottomFraction`) at the floor, the
// user's last press where it was made, and the day level at 1. A move while dimming becomes
// that middle point, so the next write is the move itself, the schedule and the ladder carry on
// from it, every step still changes the light, and the morning ease climbs to the day level
// without a jump. Earlier designs scaled the baseline (each floor case grew the morning to full
// brightness or lost it), then multiplied the curve (`boost`: after a press up the ladder's top
// half did nothing, after a press down its bottom, and the morning jumped at the release).

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
    /// The user's last move tonight, as a point the curve passes through: the fraction being asked
    /// then, and the light they chose. The morning clears it.
    private var pressFraction: Double?
    private var pressLight: Double?
    /// Where the ladder's end lands tonight when the user moved it (a press at the end, or below
    /// the floor: their own call to go darker); else the light floor.
    private var bottom: Double?
    /// The light when dimming began: tonight's range is measured from it (`darkest`). Held for
    /// the night, so a press changes the light but not the ladder's scale: measured from the
    /// baseline, which a press above it moves, the next push dimmed that press back.
    public private(set) var eveningLevel: Double?
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
    /// Readings this close to what was written are Gloam's own write, not an outside move: within
    /// 3 % on a display macOS controls (a key step near the bottom of the range moves the light very
    /// little), under one step on a monitor, which rounds a write by half a step at most (a full
    /// step, or 3 % of a 0–100 scale, swallowed one-step presses on the monitor's buttons).
    public func same(_ a: Double, _ b: Double) -> Bool {
        step > 0 ? abs(a - b) < 0.75 * step : abs(a - b) <= max(0.004, 0.03 * max(a, b))
    }

    public init(baseline: Double, step: Double = 0) {
        self.baseline = baseline
        self.step = step
    }

    public var isDimming: Bool { written != nil }

    /// Whether a display found at `light` is still where this saved dimming left it, after a
    /// crash: at what was written, or anywhere on tonight's curve between its end and the
    /// baseline, as a fade (saved at most once a second, so a fade down ends below what was
    /// saved) leaves it. Then the baseline still holds for the morning; any other level, or the
    /// baseline itself, is the user's own.
    public func resumes(at light: Double) -> Bool {
        guard let w = written else { return false }
        if same(light, w) { return true }
        return light >= min(w, bottomLight) && light < max(w, baseline) && !same(light, baseline)
    }

    /// Feed every reading of the backlight. Undimmed, the baseline simply follows the system.
    /// Dimmed, a reading away from what was written is an outside move, adopted as tonight's
    /// middle point at the fraction being asked (`settle` keeps that current while nothing is
    /// written), so the next write is the move itself, never the old light. Above the day level
    /// it becomes the day level; below it, the morning still restores the day. At the ladder's
    /// end it becomes the end (the ladder isn't locked above it); below the floor, the end goes
    /// down by as much, so the ladder's last steps still dim. `asked`: the fraction asked right
    /// now, when known (else the last recorded, up to `settle`'s 0.5 % behind: on a steep stretch
    /// of the curve that put the point visibly off the press).
    public mutating func observe(light: Double, asked: Double? = nil) {
        guard light.isFinite, light >= 0 else { return }
        guard let w = written else { return baseline = light }
        guard !same(light, w) else { return }
        if light > baseline {
            baseline = light
            baselineLevel = nil  // the restore writes the new level, not the old slider
        }
        written = light
        let f0 = bottomFraction, f = min(Self.nearlyUndimmed, asked.map { (0.0...1.0).clamp($0) } ?? fraction)
        fraction = f
        // A screen at or under its floor when the evening began has no range tonight: the move is
        // its light until the morning, which climbs from it back to the day level.
        guard f0 < 1 else { (pressFraction, pressLight) = (f, light); return }
        if f <= f0 * (1 + 1e-6) {
            bottom = light
            pressFraction = nil
            pressLight = nil
            return
        }
        let before = target(for: f), end = bottomLight
        if light < end { bottom = max(Self.dark, light * min(1, end / max(before, Self.dark))) }
        pressFraction = f
        pressLight = light
    }

    /// Nothing to write for `fraction`: the panel already shows it. The fraction is recorded all
    /// the same, so a move from here is measured against what is asked now; and the first one
    /// below 1 starts dimming at the light shown. (Left undimmed, a key press became the baseline
    /// and the next push dimmed it straight back: a screen at or under the floor never writes.)
    public mutating func settle(at fraction: Double) {
        let f = (0.0...1.0).clamp(fraction)
        guard f < 1 else { return }
        if written == nil { written = min(1, baseline); eveningLevel = written }
        else if abs(f - self.fraction) <= 0.005 * self.fraction { return }  // not every fade frame: each is a store
        self.fraction = f
    }

    /// Continues a dimming found mid-fade after a crash: the panel at `light` is on the curve.
    public mutating func resume(at light: Double) {
        guard let w = written, !same(light, w), baseline > 0 else { return }
        written = light
        fraction = fraction(showing: light)
    }

    /// Where the ladder's end lands: the light floor, or where the user moved it tonight.
    private var bottomLight: Double { bottom ?? lightFloor }

    /// The fraction the ladder's end asks for (`darkest`, as a light): the floor against the light
    /// the evening began at. 1: this screen began at or under its floor, nothing to dim.
    private var bottomFraction: Double {
        let level = eveningLevel ?? min(1, baseline)
        return level > 0 ? min(1, lightFloor / level) : 1
    }

    /// Lights this low read as dark: the log of 0 has no place on the curve.
    private static let dark = 1e-4
    /// The highest fraction recorded while dimming (1 is the release).
    static let nearlyUndimmed = 1 - 1e-6

    /// Tonight's fixed points, in rising order (each light at least the one before). A screen with
    /// no range tonight (`bottomFraction` 1) has only the day level, and the user's move if any.
    private var points: [(f: Double, light: Double)] {
        let top = min(1, baseline), f0 = bottomFraction, end = min(bottomLight, top)
        if f0 >= 1 {
            guard let pf = pressFraction, let pl = pressLight, pf < 1 else { return [(1, top)] }
            return [(pf, min(top, pl)), (1, top)]
        }
        guard let pf = pressFraction, let pl = pressLight, pf > f0 * (1 + 1e-6), pf < 1 else {
            return [(f0, end), (1, top)]
        }
        return [(f0, end), (pf, min(top, max(end, pl))), (1, top)]
    }

    /// The light on the curve through `points` at fraction `f` (inside their span), straight in log–log.
    private static func curve(_ points: [(f: Double, light: Double)], at f: Double) -> Double {
        guard let i = points.indices.dropFirst().first(where: { f <= points[$0].f }) else { return points.last!.light }
        let (a, b) = (points[i - 1], points[i])
        let t = (log(f) - log(a.f)) / (log(b.f) - log(a.f))
        return exp(log(max(a.light, dark)) + t * (log(max(b.light, dark)) - log(max(a.light, dark))))
    }

    /// The fraction at which tonight's curve shows `light`: where a panel found mid-fade sits,
    /// or a monitor's step lands. Flat stretches (the day level reached) give their low end.
    func fraction(showing light: Double) -> Double {
        let p = points
        guard p[0].f < 1, light > p[0].light else { return p[0].f < 1 ? p[0].f : Self.nearlyUndimmed }
        guard let i = p.indices.dropFirst().first(where: { light <= p[$0].light }) else { return Self.nearlyUndimmed }
        let (a, b) = (p[i - 1], p[i])
        guard b.light > a.light else { return min(Self.nearlyUndimmed, a.f) }
        let t = (log(light) - log(max(a.light, Self.dark))) / (log(b.light) - log(max(a.light, Self.dark)))
        return min(Self.nearlyUndimmed, exp(log(a.f) + t * (log(b.f) - log(a.f))))
    }

    /// The light to write for `fraction` (1 = undimmed, 0.27 = about a quarter of the light),
    /// or nil when the backlight already shows it. `fraction` 1 restores the baseline and
    /// releases the backlight; below 1 it follows tonight's curve (`target`), never under the
    /// ladder's end nor above the day level. Call it again if the write fails: nothing is recorded
    /// until it succeeds.
    ///
    /// `written` is only ever what the panel shows. Recording a skipped step as written let a
    /// slow ramp of small steps never reach the panel, and the morning restore be skipped.
    /// Written once it moves by more than the eye sees (`unseen`), not by `same`'s 3 %: changes
    /// held back that long landed as visible jumps (room light easing, the evening ramp).
    public func light(for fraction: Double) -> Double? {
        let f = (0.0...1.0).clamp(fraction)
        if f >= 1 { return written == nil ? nil : min(1, baseline) }
        let target = target(for: f)
        return Self.unseen(target, written ?? baseline) ? nil : target
    }

    /// A change of light too small to see at once (well under the ~1–2 % brightness step the eye
    /// notices): written only when the difference grows past it.
    static func unseen(_ a: Double, _ b: Double) -> Bool {
        abs(a - b) <= max(0.0005, 0.005 * max(a, b))
    }

    /// The light `fraction` asks for, whether or not the panel shows it already: tonight's curve,
    /// from the ladder's end (at `bottomFraction` and below) up to the day level at 1, which the
    /// morning ease meets with no jump.
    public func target(for fraction: Double) -> Double {
        let f = (0.0...1.0).clamp(fraction), p = points
        guard f < 1, p.count > 1 else { return min(1, baseline) }
        if f <= p[0].f { return p[0].light }
        // Untouched tonight the curve is the plain share of the day level: exact, not via logs.
        if p.count == 2, pressFraction == nil, bottom == nil, p[1].light == (eveningLevel ?? p[1].light) { return max(p[0].light, p[1].light * f) }
        return Self.curve(p, at: f)
    }

    /// The level the user chose tonight, before Gloam's dimming: the day level, moved by their
    /// presses as much as they moved the light from the schedule's (half the light, half the
    /// level). What the blue-light reading counts as the screen's own brightness.
    public var chosenLevel: Double {
        let top = min(1, baseline)
        guard isDimming, bottomFraction < 1, fraction < 1 else { return top }
        let scheduled = Self.curve([(bottomFraction, min(lightFloor, top)), (1, top)], at: max(fraction, bottomFraction))
        return min(top, max(0, top * target(for: fraction) / max(scheduled, Self.dark)))
    }

    /// For a display that takes whole steps (`step` > 0) a few times a second: the next light to
    /// write toward `fraction`, one step from what it shows, and rounded up, so the signal only
    /// ever has to dim the rest (a jump of several steps showed as a jolt), though never above
    /// the light found. nil when it's there. `fraction` is what to record with it (`wrote`): the
    /// step's own place on the curve (an outside move after it is placed there), and 1 for the
    /// write that ends a release.
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
        if next == goal { return (next, release ? 1 : fraction) }
        return (next, self.fraction(showing: next))  // on tonight's curve
    }

    /// Records a write of `light(for:)` that reached the panel.
    public mutating func wrote(_ light: Double, for fraction: Double) {
        let done = fraction >= 1
        if !done && written == nil { eveningLevel = min(1, baseline) }
        written = done ? nil : light
        self.fraction = done ? 1 : fraction
        if done { eveningLevel = nil; pressFraction = nil; pressLight = nil; bottom = nil }
    }

    // Saved for crash recovery without `lightFloor`, which follows the settings, not the panel.
    private enum CodingKeys: String, CodingKey {
        case baseline, written, fraction, baselineLevel, pressFraction, pressLight, bottom, eveningLevel, step
    }

    /// Only the baseline is required: a field added later must not make every saved display fail
    /// to load (`SavedDims` drops the lot on one error) after an update and a crash.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        baseline = try c.decode(Double.self, forKey: .baseline)
        written = try c.decodeIfPresent(Double.self, forKey: .written)
        // Out of range (hand-edited, corrupt) reads as absent: a bottom of 0 could write 0.
        let unit = { (v: Double?) in v.flatMap { $0.isFinite && (0...1).contains($0) ? $0 : nil } }
        fraction = unit(try c.decodeIfPresent(Double.self, forKey: .fraction)) ?? 1
        baselineLevel = unit(try c.decodeIfPresent(Double.self, forKey: .baselineLevel))
        pressFraction = unit(try c.decodeIfPresent(Double.self, forKey: .pressFraction)).flatMap { $0 > 0 ? $0 : nil }
        pressLight = unit(try c.decodeIfPresent(Double.self, forKey: .pressLight))
        if pressFraction == nil || pressLight == nil { (pressFraction, pressLight) = (nil, nil) }
        bottom = unit(try c.decodeIfPresent(Double.self, forKey: .bottom)).flatMap { $0 > 0 ? $0 : nil }
        eveningLevel = unit(try c.decodeIfPresent(Double.self, forKey: .eveningLevel))  // 0: began dark, no range
        step = unit(try c.decodeIfPresent(Double.self, forKey: .step)) ?? 0
    }

    /// The fraction to ask for a schedule brightness (a position: `Stage.brightness`), the same
    /// share of the way to this screen's darkest. Any dimming asked stays under 1, by as much as is
    /// asked: a screen with no range tonight still starts its evening (a press there is kept), and
    /// its morning still climbs from that press to the day level instead of jumping at the release.
    public func asked(_ brightness: Double) -> Double {
        guard brightness < 1 else { return 1 }
        let f = pow(Stage.brightness(brightness, darkest: darkest), Kelvin.displayGamma)
        return min(f, 1 - max(1e-6, (1 - brightness) * 1e-3))
    }

    /// The deepest this display goes tonight, as a signal brightness: its light floor against the
    /// light dimming began at (now, while it hasn't). The ladder's 100 % lands here
    /// (`Stage.brightness(_:darkest:)`), so every position is one the screen can show. Not held
    /// to the signal's own limit (`Stage.brightnessRange`): the deepest consented floor is
    /// reachable from a bright screen too.
    public var darkest: Double { pow(bottomFraction, 1 / Kelvin.displayGamma) }
}
