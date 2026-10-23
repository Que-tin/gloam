// A hand-set move away from Gloam's plan for tonight: the brightness keys and a monitor's buttons
// (that screen), the popover's ladder (the screen it is open on) and dial (warmth, every screen).
// Positions are on the controls' fixed scales: 0 untouched, 1 as far as the screen goes; dimming
// runs on past 1 for a press below the floor (down to 2, the backlight off).
//
// The plan keeps going and the shift rides along with it, by the same distance all evening, so a
// screen made brighter by hand still deepens with the evening. Only the morning takes it away:
// over the morning's last 20 minutes and a few after the plan is back at 0 (`fadeOut`), by the
// clock, not by the plan, which also falls when room light rises or Dimmest is lightened (a
// shrink tied to the plan's fall amplified presses made then, down to black). Each shift belongs
// to one evening and is gone after its morning (`until`), whether or not Gloam saw it.
//
// Earlier designs held a press until morning (the evening stopped for that screen) or bent the
// night's curve through it (anchored points, held floors, a morning cap): each fix opened new
// edge cases. One offset, faded by the clock, has none of theirs. A held shift is settled by
// arithmetic, not by an event (`position`): settled when Gloam saw the plan pass, it depended
// on whether it did.

import Foundation

public struct Shift: Codable, Equatable, Sendable {
    /// Read back from storage: on the scales, and ending within two days (a hand-edited or corrupt
    /// one could otherwise hold a screen dark, the backlight off, every evening for years).
    public func isPlausible(at now: Date) -> Bool {
        [to, at].allSatisfy { $0.isFinite && (0...2).contains($0) } && (distance?.isFinite ?? true)
            && chosenWeight > 0 && chosenWeight <= 1 && span > 0 && until.timeIntervalSince(now) < 2 * 86_400
    }

    /// The position chosen, and the plan's position when it was.
    public let to: Double
    public let at: Double
    /// How far from the plan it sits (`to − at`); nil while held (`threshold`).
    let distance: Double?
    /// The morning's weight when it was chosen (1 in the evening): it shrinks from there, so it
    /// shows exactly `to` when chosen, also mid-morning. Divided into the distance instead, a
    /// late choice rode on at more than it was, past the floor.
    let chosenWeight: Double
    /// The end of its evening's morning, fade-out included: by then it is 0, and it goes. Chosen
    /// late in the morning, or far from the plan, later still (`perUnit`).
    public let until: Date
    /// How long before `until` it starts to shrink: the morning's ramp and fade-out, longer for a
    /// shift far from the plan (`perUnit`), so its steps stay small near the floor.
    let span: TimeInterval

    /// Below this the plan has barely begun (by day, the evening's first minutes): a darker shift
    /// taken there is held as chosen, and rides along as if taken when the plan passed this
    /// (`to − threshold` from it), whether or not Gloam saw it pass (a launch mid-evening, a screen
    /// switched back on). Riding from so near 0, a ladder at 100 % by day became 1.9 at night.
    public static let threshold = 0.1
    /// How long after the plan is back at 0 a shift still fades: a press made late in the morning
    /// (or one to black) glides back over these minutes rather than in visible steps.
    public static let fadeOut: TimeInterval = 10 * 60
    /// The morning's own ease (`Schedule.easeOut`), over which a shift starts to shrink.
    public static let morningRamp: TimeInterval = 20 * 60
    /// The least time a shift takes to fade, per unit of the ladder it sits from the plan: near the
    /// floor a unit is a large change of light, and a 5 s tick (the plan falling too) must not show
    /// as a step (~4 %). A shift to black from the plan's start then fades for an hour, the extra
    /// after the plan is done; one chosen late in the morning gets it from then. At least
    /// `leastFade`, or a tiny late change had almost no time.
    public static let perUnit: TimeInterval = 30 * 60
    static let leastFade: TimeInterval = 3 * 60

    /// A shift chosen now, or nil where it would sit on the plan: nothing to remember (the ladder
    /// dragged back onto the plan, a move by day to 0). Kept, a shift of nothing still showed
    /// "Manual" and kept the clock ticking fast all day.
    public static func make(to: Double, at plan: Double, now: Date, until: Date) -> Shift? {
        abs(to - max(0, plan)) < 1e-6 ? nil : Shift(to: to, at: plan, now: now, until: until)
    }

    /// `until`: when the evening this belongs to ends (`Schedule.shiftClock`), `now` on the same
    /// clock. A riding shift shows `to` at once: what was chosen is never written back.
    public init(to: Double, at plan: Double, now: Date, until: Date) {
        self.to = to
        self.at = max(0, plan)
        let fade = max(Self.leastFade, abs(to - max(0, plan)) * Self.perUnit)
        span = max(Self.morningRamp + Self.fadeOut, fade)
        self.until = max(until.addingTimeInterval(span - Self.morningRamp - Self.fadeOut), now.addingTimeInterval(fade))
        let w = Self.weight(now, until: self.until, span: span)
        chosenWeight = max(w, 1e-9)
        distance = w >= 1 && self.at < Self.threshold && to > self.at ? nil : to - self.at
    }

    private init(to: Double, at: Double, distance: Double?, chosenWeight: Double, until: Date, span: TimeInterval) {
        self.to = to
        self.at = at
        self.distance = distance
        self.chosenWeight = chosenWeight
        self.until = until
        self.span = span
    }

    public var isHeld: Bool { distance == nil }

    /// 1 all evening, easing to 0 over the morning's ramp and the fade-out after it. Eased like
    /// the plan's own morning (a smoothstep, over longer): a shift that made the screen brighter
    /// never shrinks faster than the plan falls, or the screen dimmed in the morning before
    /// coming back up.
    static func weight(_ now: Date, until: Date, span: TimeInterval = morningRamp + fadeOut) -> Double {
        let x = min(1, max(0, until.timeIntervalSince(now) / span))
        return x * x * (3 - 2 * x)
    }
    private func weight(_ now: Date) -> Double { Self.weight(now, until: until, span: span) }

    /// The position to show for `plan` at `now`: the plan plus the distance, shrinking only in the
    /// morning. Never past the floor unless the shift itself went there: a darker shift the floor
    /// holds blends from there towards the plan as the morning shrinks it, rather than coming back
    /// at full distance once the plan falls clear of the floor (morning steps of 5–7 %). A lighter
    /// one shrinks straight towards the plan, held at 0.
    public func position(plan: Double, now: Date) -> Double {
        let w = min(1, weight(now) / chosenWeight), p = max(0, plan), cap = max(1, to)
        let full = distance.map { p + $0 } ?? max(to, p + to - Self.threshold)
        let off = full - p
        if off < 0 { return max(0, p + w * off) }
        return min(cap, p + w * min(off, max(0, cap - p)))
    }

    /// How far it moves what the screen shows now, on the controls' scale (for "Manual").
    public func offset(plan: Double, now: Date) -> Double { position(plan: plan, now: now) - max(0, plan) }

    public func expired(_ now: Date) -> Bool { now >= until }

    /// Its morning has begun: it shrinks with the clock now, whatever the plan does.
    public func isShrinking(_ now: Date) -> Bool { weight(now) < 1 }

    /// The same shift, moved by `delta` on the ladder (a lower floor: a shift below it keeps the
    /// light it shows).
    public func moved(by delta: Double) -> Shift {
        Shift(to: to + delta, at: at, distance: distance.map { $0 + delta }, chosenWeight: chosenWeight, until: until, span: span)
    }

    /// Bedtime or wake changed tonight, so its morning's end moved from `old` to `new`: a shift of
    /// that evening ends with it; any other (the coming evening's, or one whose morning is under
    /// way) stays as it is. Its own end can be up to half an hour after the morning (`perUnit`).
    public func retimed(from old: Date, to new: Date, now: Date) -> Shift {
        guard old > now, until >= old, until < old.addingTimeInterval(3600) else { return self }
        return Shift(to: to, at: at, distance: distance, chosenWeight: chosenWeight,
                     until: until.addingTimeInterval(new.timeIntervalSince(old)), span: span)
    }
}

/// When shifts end, from the schedule (`Shift.until`): what a move made now belongs to.
public struct ShiftClock: Equatable, Sendable {
    public var now: Date
    /// The end, fade-out included, of the morning a shift chosen now belongs to.
    public var until: Date
    /// This morning's plan is back at 0 (and its fade-out may still run): a key press is the
    /// user's day level, and a ladder move belongs to the coming evening.
    public var planDone: Bool

    public init(now: Date, until: Date, planDone: Bool) {
        self.now = now
        self.until = until
        self.planDone = planDone
    }

    /// Before any schedule is known: nothing ends, nothing is done.
    public static let idle = ShiftClock(now: Date(), until: .distantFuture, planDone: false)

    /// The morning's ease has begun for shifts ending at `until` (`Shift.weight` below 1).
    public var inMorning: Bool { Shift.weight(now, until: until) < 1 }
}

extension Schedule {
    /// When this evening's plan is back at the day level for good in the morning, room light
    /// aside: its dimming, or its warmth (sunrise can end either before wake). The night's wake
    /// when it never left the day (polar day, a Dimmest of nothing).
    public func morningEnd(of e: Evening, _ c: Coordinate, warmth: Bool, calendar: Calendar = .current) -> Date {
        let away = { (d: Date) in
            let t = self.tint(at: d, c, calendar: calendar)
            return warmth ? t.kelvin < Stage.kelvinRange.upperBound - 0.5 : t.brightness < 0.9995
        }
        var d = e.wake
        let earliest = e.bedtime.addingTimeInterval(-4 * 3600)
        while d > earliest {
            let before = d.addingTimeInterval(-60)
            if away(before) { return d }
            d = before
        }
        return e.wake
    }


    /// What a shift chosen at `date` belongs to (`ShiftClock`), one per morning end (`morningEnd`,
    /// dimming's and warmth's, which the caller caches), from the same evenings: each
    /// `evening(around:)` is a sun scan, worked out once a tick rather than once per clock.
    /// `tonight` is the evening around `date`.
    public func shiftClocks(at date: Date, _ c: Coordinate, ends: [(Evening) -> Date],
                            calendar: Calendar = .current) -> (clocks: [ShiftClock], tonight: Evening) {
        let tonight = evening(around: date, c, calendar: calendar)
        // A calendar day back, not 24 h: the day before the clocks go back is 25 h long, and 24 h
        // back landed in tonight's own evening (no morning done, for ten minutes once a year).
        let dayBefore = calendar.date(byAdding: .day, value: -1, to: tonight.wake) ?? tonight.wake.addingTimeInterval(-86400)
        let last = evening(around: dayBefore.addingTimeInterval(-60), c, calendar: calendar)
        var next: Evening?
        let clocks = ends.map { end -> ShiftClock in
            let lastEnd = end(last), tonightEnd = end(tonight)
            if date < tonightEnd {
                return ShiftClock(now: date, until: tonightEnd.addingTimeInterval(Shift.fadeOut),
                                  planDone: last.wake < tonight.wake && date < lastEnd.addingTimeInterval(Shift.fadeOut))
            }
            let following = next ?? evening(around: tonight.wake.addingTimeInterval(60), c, calendar: calendar)
            next = following
            return ShiftClock(now: date, until: end(following).addingTimeInterval(Shift.fadeOut), planDone: true)
        }
        return (clocks, tonight)
    }
}
