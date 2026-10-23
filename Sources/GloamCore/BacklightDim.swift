// Dims a display by its backlight instead of its signal, relative to whatever brightness the
// user (or auto-brightness) had set: the "baseline", their day level.
//
// Why the backlight: a dimmed signal keeps the backlight at full power and drives the liquid
// crystal into its slow dark range (light text on dark backgrounds smears), crushes shadows
// below ~30%, and on some chips gamma tables no longer work at all. The backlight is the lever
// the brightness keys use: no smearing, no banding, less power, and it reaches the ~25 cd/m²
// a dark room asks for. Dedicated brightness tools dim this way for the same reasons.
//
// Why a baseline and not a level: the slider belongs to the user and to auto-brightness. Gloam
// shows a position (the ladder's: 0 untouched, 1 the light floor) the same share of the way down
// from the day level as on any screen, and a move made elsewhere (a key press, the monitor's
// buttons) is never fought: it becomes that screen's shift from the plan (`Shift`), or in the
// evening's first minutes and once the morning's plan is done, a new day level. A move macOS
// makes itself (auto-brightness) is always a new day level (`macOSSet`).

import Foundation

public struct BacklightDim: Equatable, Codable, Sendable {
    /// The light (0…1 of the display's maximum, linear) the display shows undimmed: the day level,
    /// and what the morning restores.
    public private(set) var baseline: Double
    /// What Gloam last wrote, while it is dimming; nil when it is leaving the backlight alone.
    public private(set) var written: Double?
    /// The slider value that went with the baseline when dimming began, for an exact restore
    /// (writing the light back lands a step low); dropped when the day level moves.
    public var baselineLevel: Double?
    /// The display's own step (a DDC monitor's 1/100): its rounded read-back of a write is the
    /// write, not an outside move. 0 for displays macOS controls.
    public var step = 0.0
    /// The light floor in force (`floor`), as a fraction of the panel's maximum. Set by the
    /// controller on every change; not saved (a relaunch sets it again).
    public var lightFloor = Self.floorLight

    /// The floor where the panel's luminance is known (macOS reports it for its own panels), in
    /// cd/m² for the room at `lux`: 25 in the dark, where evening viewers tired least at ~21 and
    /// found ~26 comfortable (Zhou et al. 2021), rising as they preferred more in a lit room
    /// (~41 at 20 lx, 50 at 100 lx), at most 60. No reading (no sensor, the lid closed, the room
    /// left out in Settings): 40, about the fraction floor on a 500-nit panel.
    /// See docs/science.md.
    public static func floorNits(lux: Double?) -> Double {
        guard let lux, !lux.isNaN else { return 40 }
        return min(60, 25 + 12.5 * log10(1 + max(0, lux)))
    }
    /// How low the floor goes at the deepest Dimmest setting: the dark-adapted start Na & Suk
    /// (2015) found comfortable, below the comfortable range, which is why only an explicit
    /// setting past the recommended night reaches it.
    public static let deepestFloorNits = 10.0
    /// Where the luminance is unknown (monitors: DDC says nothing of it), the floor is a fraction
    /// of the maximum instead, about 40 and 15 cd/m² on a 500-nit panel.
    public static let floorLight = 0.08, deepestFloorLight = 0.03

    /// The light floor as a fraction of the panel's maximum: `consent` (the user's Dimmest past
    /// the recommended night, 0…1) eases it towards the deepest. `maxNits` nil: unknown. `white`:
    /// the share of daylight white's light the tint leaves (`Smear.luminance`): the floor is on the
    /// white seen, or at 1900 K (about half the light) the screen went to half of it.
    public static func floor(maxNits: Double?, lux: Double?, consent: Double, white: Double = 1) -> Double {
        let white = max(0.05, min(1, white))
        guard let maxNits, maxNits > 0 else { return min(1, (floorLight + (deepestFloorLight - floorLight) * consent) / white) }
        let base = floorNits(lux: lux), nits = base + (deepestFloorNits - base) * consent
        return min(1, nits / maxNits / white)
    }
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

    private var top: Double { min(1, max(0, baseline)) }
    /// Where position 1 lands: the light floor, or the day level when that is lower already.
    private var end: Double { min(lightFloor, top) }

    /// The deepest this display goes on the ladder, as a signal brightness (1: nothing to dim, the
    /// day level at or under the floor).
    public var darkest: Double { top > 0 ? pow(end / top, 1 / Kelvin.displayGamma) : 1 }

    /// The light at `position`: on the ladder (0…1) the same share of the way from the day level to
    /// the floor as a signal brightness, as any screen takes it; past 1 (a press below the floor)
    /// straight on down to black at 2.
    public func light(at position: Double) -> Double {
        guard position > 0 else { return top }
        if position <= 1 { return top * pow(1 - position * (1 - darkest), Kelvin.displayGamma) }
        return end * max(0, 2 - position)
    }

    /// The position showing `light`: 0 at the day level or above, past 1 below the floor.
    public func position(of light: Double) -> Double {
        if light >= top { return 0 }
        if light >= end && end < top {
            return min(1, (1 - pow(light / top, 1 / Kelvin.displayGamma)) / (1 - darkest))
        }
        return end > 0 ? 1 + min(1, max(0, 1 - light / end)) : 2
    }

    /// Whether a display found at `light` is still where this saved dimming left it, after a
    /// crash: at what was written, or anywhere between it (or the floor) and the day level, as a
    /// fade (saved at most once a second, so a fade down ends below what was saved) leaves it;
    /// written below the floor (a shift there), anywhere down to black. Then the baseline still
    /// holds for the morning; any other level, or the baseline itself, is the user's own.
    public func resumes(at light: Double) -> Bool {
        guard let w = written else { return false }
        if same(light, w) { return true }
        let lowest = w < end ? 0 : min(w, end)
        return light >= lowest && light < max(w, baseline) && !same(light, baseline)
    }

    /// What a reading means (`observe`).
    public enum Move: Equatable, Sendable {
        /// Gloam's own write, or nothing to tell: undimmed, the day level just follows the system.
        case none
        /// The user moved the light while Gloam dims: this position is theirs (`Shift`).
        case shift(to: Double)
        /// The user moved the light before Gloam's dimming got going: the day level moved instead.
        case dayLevel
    }

    /// Feed every reading of the backlight, with the plan's position for this screen now. Undimmed,
    /// the day level simply follows the system. Dimmed, a reading away from what was written is the
    /// user's own move, never written back: the position it shows becomes the screen's shift. Where
    /// `setsDayLevel` (the evening's first minutes, the morning's plan done: the caller knows) it is
    /// their day level instead, set so the plan shows exactly that light; and a move above the day
    /// level makes it the day level (a shift to 0 then holds the screen there tonight).
    public mutating func observe(light: Double, plan: Double, setsDayLevel: Bool) -> Move {
        guard light.isFinite, light >= 0 else { return .none }
        guard let w = written else {
            baseline = light
            return .none
        }
        guard !same(light, w) else { return .none }
        return moved(to: light, plan: plan, setsDayLevel: setsDayLevel)
    }

    /// A move macOS reports as the user's (`observe` without its guess): taken even when it is
    /// smaller than `same`, which near the bottom of the range swallowed a key step.
    public mutating func moved(to light: Double, plan: Double, setsDayLevel: Bool) -> Move {
        guard light.isFinite, light >= 0 else { return .none }
        guard let w = written else {
            baseline = light
            return .none
        }
        guard abs(light - w) > 1e-6 else { return .none }
        written = light
        if setsDayLevel {
            baselineLevel = nil
            if let day = dayLevel(showing: light, at: plan) {
                baseline = day
                return .dayLevel
            }
            // Brighter than the plan shows even from full brightness: full is the day level, and the
            // rest of the move a (held) shift, or the next write would take it back.
            baseline = 1
            return .shift(to: position(of: light))
        }
        if light > top {
            baseline = light
            baselineLevel = nil
            return .shift(to: 0)
        }
        return .shift(to: position(of: light))
    }

    /// macOS moved the light itself (auto-brightness): its level for the room, the new day level,
    /// which Gloam dims from as before. Taken as a shift, the evening's dimming was lost until
    /// morning; the panel shows that light now, so dimming resumes from there.
    public mutating func macOSSet(_ light: Double) {
        guard light.isFinite, light > 0 else { return }
        baseline = light
        baselineLevel = nil
        if written != nil { written = light }
    }

    /// The day level at which `plan` shows `light` (the evening's first minutes, where a move sets
    /// it); nil when even full brightness shows less.
    private func dayLevel(showing light: Double, at plan: Double) -> Double? {
        guard plan > 0, light > 0 else { return light }
        var probe = self
        probe.baseline = 1
        guard probe.light(at: plan) >= light else { return nil }
        var (low, high) = (light, 1.0)
        for _ in 0..<40 {
            probe.baseline = (low + high) / 2
            if probe.light(at: plan) < light { low = probe.baseline } else { high = probe.baseline }
        }
        return (low + high) / 2
    }

    /// Nothing to write for `position`: the panel already shows it (a screen at or under its floor,
    /// say). The first position past 0 starts dimming all the same, at the light shown, so a move
    /// from here is a move, not a new day level the next write would dim straight back.
    public mutating func settle(at position: Double) {
        guard position > 0, written == nil else { return }
        written = top
    }

    /// Continues a dimming found mid-fade after a crash: the panel shows `light`.
    public mutating func resume(at light: Double) {
        guard let w = written, !same(light, w) else { return }
        written = light
    }

    /// The light to write for `position`, or nil when the backlight already shows it. Position 0
    /// with `release` restores the day level and releases the backlight; without (a shift took the
    /// screen to its day level while the plan dims), it shows the day level and stays engaged, so
    /// the next press is a shift, not a new day level. Call it again if the write fails: nothing
    /// is recorded until it succeeds.
    ///
    /// `written` is only ever what the panel shows. Recording a skipped step as written let a
    /// slow ramp of small steps never reach the panel, and the morning restore be skipped.
    /// Written once it moves by more than the eye sees (`unseen`), not by `same`'s 3 %: changes
    /// held back that long landed as visible jumps (room light easing, the evening ramp).
    public func light(for position: Double, release: Bool = true) -> Double? {
        if position <= 0 && (release || written == nil) { return written == nil ? nil : top }
        let target = light(at: position)
        return Self.unseen(target, written ?? top) ? nil : target
    }

    /// A change of light too small to see at once (well under the ~1–2 % brightness step the eye
    /// notices): written only when the difference grows past it.
    public static func unseen(_ a: Double, _ b: Double) -> Bool {
        abs(a - b) <= max(0.0005, 0.005 * max(a, b))
    }

    /// For a display that takes whole steps (`step` > 0) a few times a second: the next light to
    /// write toward `position`, one step from what it shows, and rounded up, so the signal only
    /// ever has to dim the rest (a jump of several steps showed as a jolt), though never above
    /// the day level; `release` when this write ends the dimming. nil when it's there.
    /// Without a step, `light(for:)` in one go.
    public func nextStep(for position: Double, release allowed: Bool = true) -> (light: Double, release: Bool)? {
        let release = position <= 0 && (allowed || written == nil)
        guard step > 0 else { return light(for: position, release: allowed).map { ($0, release) } }
        if release && written == nil { return nil }
        let target = light(at: position)
        let goal = release ? target : min(top, (target / step - 1e-6).rounded(.up) * step)
        let from = written ?? top
        let gap = abs(goal - from)
        if gap <= step / 2 { return release ? (goal, true) : nil }  // a release is recorded even there
        let next = gap <= step * 1.5 ? goal : from + (goal > from ? step : -step)
        return (next, release && next == goal)
    }

    /// Records a write that reached the panel; `release` ends the dimming.
    public mutating func wrote(_ light: Double, release: Bool) {
        written = release ? nil : light
    }

    // Saved for crash recovery without `lightFloor`, which follows the settings, not the panel.
    private enum CodingKeys: String, CodingKey { case baseline, written, baselineLevel, step }

    /// Only the baseline is required: a field added later must not make every saved display fail
    /// to load (`SavedDims` drops the lot on one error, and filters a baseline out of range) after
    /// an update and a crash. Other fields out of range (hand-edited, corrupt) read as absent.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let unit = { (v: Double?) in v.flatMap { $0.isFinite && (0...1).contains($0) ? $0 : nil } }
        baseline = try c.decode(Double.self, forKey: .baseline)
        written = unit(try c.decodeIfPresent(Double.self, forKey: .written))
        baselineLevel = unit(try c.decodeIfPresent(Double.self, forKey: .baselineLevel))
        step = unit(try c.decodeIfPresent(Double.self, forKey: .step)) ?? 0
    }
}
