// BacklightDim and Shift: what is written to a backlight, and how the user's own moves are kept.
// Every bug here leaves a real screen too dim or too bright, often until the next morning.

import Foundation
import Testing
@testable import GloamCore

@Suite struct BacklightDimTests {
    /// One push, as the controller does it: the light to write, recorded as written (the write
    /// succeeds); nothing to write, dimming starts all the same (`settle`).
    /// `release`: the plan itself is back at 0 (else position 0 stays engaged, at the day level).
    @discardableResult static func push(_ d: inout BacklightDim, _ position: Double, release: Bool = true) -> Double? {
        guard let light = d.light(for: position, release: release) else { d.settle(at: position); return nil }
        d.wrote(light, release: position <= 0 && release)
        return light
    }

    /// An evening, and when its morning ends (far off: a whole evening of ticks fits before it).
    static let evening = Date(timeIntervalSinceReferenceDate: 0)
    static let until = evening.addingTimeInterval(10 * 3600)

    /// A user's move as the controller takes it: the reading, then the screen's new shift. The day
    /// level in the evening's first minutes (plan and what shows under the threshold, not in the
    /// morning).
    static func press(_ d: inout BacklightDim, _ light: Double, plan: Double, shift: inout Shift?, now: Date = evening) {
        let early = max(plan, shown(plan, shift, now: now)) < Shift.threshold && Shift.weight(now, until: until) >= 1
        switch d.observe(light: light, plan: plan, setsDayLevel: early) {
        case .none: break
        case .shift(let to): shift = Shift(to: to, at: plan, now: now, until: until)
        case .dayLevel: shift = nil
        }
    }

    static func shown(_ plan: Double, _ shift: Shift?, now: Date = evening) -> Double {
        min(2, max(0, shift?.position(plan: plan, now: now) ?? plan))
    }

    // macOS's own move (auto-brightness) is the room's level: the evening dims from it at once,
    // as from any day level, and the morning restores it.
    @Test func macOSSetsTheDayLevel() {
        var d = BacklightDim(baseline: 0.3)
        Self.push(&d, 0.5)
        d.macOSSet(0.6)
        #expect(d.isDimming && d.written == 0.6 && d.baseline == 0.6)
        #expect(d.light(at: 0.5) == BacklightDim(baseline: 0.6).light(at: 0.5))
        #expect(d.light(for: 0) == 0.6)
        var day = BacklightDim(baseline: 0.3)
        day.macOSSet(0.5)
        #expect(!day.isDimming && day.baseline == 0.5)
    }

    // A move macOS says is the user's counts however small: near the bottom a key step moves the
    // light less than `same` lets through, and was lost.
    @Test func aReportedPressIsTakenHoweverSmall() {
        var d = BacklightDim(baseline: 0.3)
        let w = Self.push(&d, 0.9)!
        var guessed = d
        #expect(guessed.observe(light: w * 1.02, plan: 0.9, setsDayLevel: false) == .none)
        #expect(d.moved(to: w * 1.02, plan: 0.9, setsDayLevel: false) != .none)
    }

    // Positions map onto the screen's own range: 0 the day level, 1 the floor, 2 black, and back.
    @Test func positionsMapOntoTheScreensRange() {
        let d = BacklightDim(baseline: 0.5)
        #expect(d.light(at: 0) == 0.5)
        #expect(abs(d.light(at: 1) - BacklightDim.floorLight) < 1e-12)
        #expect(d.light(at: 2) == 0)
        let lights = stride(from: 0.0, through: 2, by: 0.05).map(d.light(at:))
        #expect(zip(lights, lights.dropFirst()).allSatisfy { $0 > $1 })
        for q in stride(from: 0.0, through: 2, by: 0.1) {
            #expect(abs(d.position(of: d.light(at: q)) - q) < 1e-9, "\(q)")
        }
    }

    // A dimmer screen is dimmed less, never pinned to its floor by the night.
    @Test func aDimmerScreenIsDimmedLess() {
        let full = BacklightDim(baseline: 1), low = BacklightDim(baseline: 0.25)
        let night = 0.64
        #expect(low.light(at: night) / 0.25 > full.light(at: night) / 1)
        #expect(low.light(at: night) > BacklightDim.floorLight)
    }

    @Test func dimsRelativeToTheBaselineAndRestoresIt() {
        var d = BacklightDim(baseline: 0.5)
        let light = Self.push(&d, 0.5)!
        #expect(light < 0.5 && light > BacklightDim.floorLight && d.isDimming)
        #expect(Self.push(&d, 0) == 0.5 && !d.isDimming)
        #expect(Self.push(&d, 0) == nil)
    }

    // Steps under the write threshold add up: each is measured from what the panel shows, so a
    // slow ramp reaches the panel, and Gloam's own level read back is no outside move.
    @Test func aSlowRampReachesItsTargetAndTheMorningRestores() {
        var d = BacklightDim(baseline: 0.6), shift: Shift?
        for i in 1...600 {
            let plan = 0.64 * Double(i) / 600
            Self.push(&d, plan)
            Self.press(&d, d.written ?? d.baseline, plan: plan, shift: &shift)
        }
        #expect(shift == nil && abs(d.written! - d.light(at: 0.64)) / d.light(at: 0.64) < 0.006)
        #expect(Self.push(&d, 0) == 0.6)
    }

    // A write that fails records nothing, so the next push tries again.
    @Test func aFailedWriteIsRetried() {
        let d = BacklightDim(baseline: 0.5)
        let first = d.light(for: 0.5)
        #expect(first != nil && d.light(for: 0.5) == first)
    }

    // Rules 1 and 2: a move while dimming becomes the screen's shift; at the plan it was made at it
    // is exactly the move (nothing written back), and the evening carries on from it.
    @Test func aPressBecomesAShiftThatRidesAlong() {
        var d = BacklightDim(baseline: 0.6), shift: Shift?
        Self.push(&d, 0.4)
        let pressed = d.light(at: 0.4) * 1.5
        Self.press(&d, pressed, plan: 0.4, shift: &shift)
        #expect(Self.push(&d, Self.shown(0.4, shift)) == nil)           // the press stays
        let later = Self.push(&d, Self.shown(0.6, shift))!
        #expect(later < pressed)                                         // deeper with the evening
        #expect(abs(d.position(of: later) - (0.6 + d.position(of: pressed) - 0.4)) < 1e-9)  // by as much
    }

    // Rule 4: down and back up ends where it started.
    @Test func downAndBackUpReturns() {
        var d = BacklightDim(baseline: 0.6), shift: Shift?
        Self.push(&d, 0.5)
        let start = d.written!
        Self.press(&d, start * 0.5, plan: 0.5, shift: &shift)
        Self.press(&d, start, plan: 0.5, shift: &shift)
        #expect(abs(Self.shown(0.5, shift) - 0.5) < 1e-9)
        #expect(abs(Self.shown(0.7, shift) - 0.7) < 1e-9)
    }

    // Rule 5: below the floor the keys go on, down to black: kept.
    @Test func aPressBelowTheFloorIsKept() {
        var d = BacklightDim(baseline: 0.5), shift: Shift?
        Self.push(&d, 1)                                                 // at the floor
        Self.press(&d, 0.03, plan: 1, shift: &shift)
        #expect(Self.shown(1, shift) > 1 && Self.push(&d, Self.shown(1, shift)) == nil)
        Self.press(&d, 0, plan: 1, shift: &shift)
        #expect(Self.shown(1, shift) == 2 && d.light(at: 2) == 0)
    }

    // A monitor turned down to 0 stays at 0: no step rounds it back up.
    @Test func aMonitorAtZeroStaysThere() {
        var d = BacklightDim(baseline: 0.5, step: 0.01), shift: Shift?
        d.wrote(0.08, release: false)
        Self.press(&d, 0, plan: 1, shift: &shift)
        #expect(d.nextStep(for: Self.shown(1, shift)) == nil)
    }

    // Rule 6: in the evening's first minutes a move is the day level: the plan then shows it.
    @Test func anEarlyPressSetsTheDayLevel() {
        var d = BacklightDim(baseline: 0.6), shift: Shift?
        Self.push(&d, 0.05)
        Self.press(&d, 0.3, plan: 0.05, shift: &shift)
        #expect(shift == nil && d.baseline < 0.6 && d.baseline > 0.3)
        #expect(abs(d.light(at: 0.05) - 0.3) < 1e-6)
        #expect(Self.push(&d, 0.05) == nil)
    }

    // Early, but brighter than the plan shows even from full brightness: full is the day level, and
    // the rest a shift, so nothing is written back.
    @Test func anEarlyPressPastFullBrightnessIsKept() {
        var d = BacklightDim(baseline: 0.9), shift: Shift?
        Self.push(&d, 0.08)
        Self.press(&d, 0.99, plan: 0.08, shift: &shift)
        #expect(d.baseline == 1 && abs(d.light(at: Self.shown(0.08, shift)) - 0.99) < 1e-9)
    }

    // Rule 7: brighter than the day level at night: that's the day level, the screen held there.
    @Test func aPressAboveTheDayLevelBecomesIt() {
        var d = BacklightDim(baseline: 0.4), shift: Shift?
        Self.push(&d, 0.5)
        Self.press(&d, 0.7, plan: 0.5, shift: &shift)
        #expect(d.baseline == 0.7 && Self.shown(0.5, shift) == 0)
        #expect(d.light(at: Self.shown(0.5, shift)) == 0.7)               // not written back
        #expect(Self.push(&d, Self.shown(0.7, shift))! < 0.7)             // the evening goes on
        #expect(Self.push(&d, 0) == 0.7)                                 // the morning keeps it
    }

    // Brought back to the day level by hand while the plan dims, the backlight stays engaged: the
    // next press is a shift, not a new day level (which the morning then restored).
    @Test func positionZeroMidEveningStaysEngaged() {
        var d = BacklightDim(baseline: 0.6), shift: Shift?
        Self.push(&d, 0.5)
        Self.press(&d, 0.6, plan: 0.5, shift: &shift)                      // up to the day level
        Self.push(&d, Self.shown(0.5, shift), release: false)
        #expect(d.isDimming)
        Self.press(&d, 0.3, plan: 0.5, shift: &shift)                      // and down again
        #expect(d.baseline == 0.6 && shift != nil)
    }

    // A crash after a fade below the floor (a shift there): anything down to black still resumes.
    @Test func aCrashBelowTheFloorResumes() {
        var d = BacklightDim(baseline: 0.6)
        Self.push(&d, 1.6)
        #expect(d.resumes(at: d.written! * 0.5) && d.resumes(at: 0))
    }

    // A screen at or under its floor when the evening starts has nothing to dim, but the evening
    // starts all the same: turned up, it's dimmed with the evening from there.
    @Test func aDarkScreenTurnedUpIsDimmedAfterwards() {
        var d = BacklightDim(baseline: 0.05), shift: Shift?
        #expect(Self.push(&d, 0.5) == nil && d.isDimming)
        Self.press(&d, 0.3, plan: 0.5, shift: &shift)
        #expect(d.baseline == 0.3 && d.light(at: Self.shown(0.5, shift)) == 0.3)
        #expect(Self.push(&d, Self.shown(0.7, shift))! < 0.3)
    }

    // Rule 8: the morning shrinks the shift by the clock, over its ramp and the fade-out after the
    // plan is back at 0; no 5 s tick jumps, and the release lands on the day level. Down by hand,
    // up by hand, below the floor, to black; pressed at night or late in the morning: the same.
    @Test func theMorningHasNoJump() {
        let planEnds = Self.until.addingTimeInterval(-Shift.fadeOut)
        let rampStart = planEnds.addingTimeInterval(-Shift.morningRamp)
        let night = 0.64
        let plan = { (t: Date) in night * min(1, max(0, planEnds.timeIntervalSince(t) / Shift.morningRamp)) }
        for factor in [0.3, 1.6, 0.05, 0] {
            for pressedAt in [rampStart.addingTimeInterval(-3600), rampStart.addingTimeInterval(900), planEnds.addingTimeInterval(-30)] {
                var d = BacklightDim(baseline: 0.6), shift: Shift?
                for i in 0...540 { Self.push(&d, Self.shown(night * Double(i) / 540, shift)) }  // 45 min of 5 s ticks
                Self.push(&d, Self.shown(plan(pressedAt), shift, now: pressedAt))
                Self.press(&d, d.written! * factor, plan: plan(pressedAt), shift: &shift, now: pressedAt)
                var last = d.written!, biggest = 1.0
                let day = max(0.6, d.baseline), end = shift?.until ?? Self.until
                var t = pressedAt
                while t <= end {
                    t = t.addingTimeInterval(5)
                    let q = Self.shown(plan(t), shift, now: t)
                    guard let light = Self.push(&d, q, release: plan(t) == 0) else { continue }
                    // Relative steps; below the deepest floor (3 %), what shows is the change in light
                    // itself, a few thousandths of full brightness a tick there.
                    biggest = max(biggest, max(light, last) / max(min(light, last), BacklightDim.deepestFloorLight))
                    last = light
                }
                #expect(!d.isDimming && last == min(1, day), "\(factor) \(pressedAt)")
                #expect(biggest < 1.04, "\(factor) \(pressedAt): \(biggest)")
            }
        }
    }

    @Test func undimmedBaselineFollowsTheSystem() {
        var d = BacklightDim(baseline: 0.5)
        _ = d.observe(light: 0.9, plan: 0, setsDayLevel: true)
        #expect(d.baseline == 0.9 && !d.isDimming)
        _ = d.observe(light: .nan, plan: 0, setsDayLevel: true)
        #expect(d.baseline == 0.9)
    }

    // A DDC monitor reads back on its own 1/100 scale: its rounding is the write, not a move.
    @Test func aMonitorsRoundingIsNoOutsideMove() {
        var d = BacklightDim(baseline: 0.5, step: 0.01)
        for i in 0..<200 {
            let q = 0.3 + 0.05 * Double(i % 5)
            if let (light, release) = d.nextStep(for: q) {
                d.wrote(light, release: release)
                #expect(d.observe(light: (light * 100).rounded() / 100, plan: q, setsDayLevel: false) == .none)
            }
        }
        #expect(d.baseline == 0.5)
    }

    // One press on a monitor's own buttons is the user's, on 0–50 and 0–100 scales alike; Gloam's
    // own write read back (rounded by half a step) is not.
    @Test func aOneStepPressIsAdopted() {
        for (steps, written) in [(50, 4), (100, 30)] {
            let step = 1.0 / Double(steps)
            var d = BacklightDim(baseline: 0.9, step: step)
            d.wrote(Double(written) * step, release: false)
            #expect(d.same(d.written!, d.written! + step * 0.4))
            #expect(d.observe(light: d.written! + step, plan: 0.5, setsDayLevel: false) != .none, "\(steps)")
        }
    }

    // A monitor walks one step per write, rounded up (the signal dims the rest), never above the
    // day level, and the release lands on it.
    @Test func aMonitorWalksOneStepAtATime() {
        var d = BacklightDim(baseline: 12.0 / 50, step: 1.0 / 50)
        var lights: [Int] = []
        while let (light, release) = d.nextStep(for: 1) {
            lights.append(Int((light * 50).rounded()))
            d.wrote(light, release: release)
        }
        #expect(lights == [11, 10, 9, 8, 7, 6, 5, 4])   // the floor, 0.08: 4 of 50
        var back: [Int] = []
        while let (light, release) = d.nextStep(for: 0) {
            back.append(Int((light * 50).rounded()))
            d.wrote(light, release: release)
        }
        #expect(back == [5, 6, 7, 8, 9, 10, 11, 12] && !d.isDimming)
    }

    // After a crash mid-fade the panel sits between what was saved (or the floor) and the day
    // level: still Gloam's. At the day level or brighter it's the user's.
    @Test func aCrashMidFadeStillResumes() {
        var d = BacklightDim(baseline: 0.6)
        Self.push(&d, 0.5)
        #expect(d.resumes(at: d.written!) && d.resumes(at: d.written! * 1.3) && d.resumes(at: 0.09))
        #expect(!d.resumes(at: 0.6) && !d.resumes(at: 0.7))
    }

    // Saved while dimming, so a launch after a crash can restore the morning level; the floor
    // follows the settings, not the panel, and isn't saved.
    @Test func survivesBeingSaved() throws {
        var d = BacklightDim(baseline: 0.6)
        d.lightFloor = 0.03
        Self.push(&d, 0.3)
        let back = try JSONDecoder().decode(BacklightDim.self, from: JSONEncoder().encode(d))
        #expect(back.written == d.written && back.baseline == d.baseline && back.lightFloor == BacklightDim.floorLight)
    }

    // A hand-edited or corrupt save reads its odd fields as absent.
    @Test func decodingIsTolerant() throws {
        let json = #"{"baseline":0.5,"written":7,"baselineLevel":-1}"#
        let d = try JSONDecoder().decode(BacklightDim.self, from: Data(json.utf8))
        #expect(d.written == nil && d.baselineLevel == nil && d.step == 0)
    }

    // Past the recommended night the floor eases: the ladder's end goes deeper, even on a bright screen.
    @Test func aLowerFloorGoesDeeper() {
        var d = BacklightDim(baseline: 1)
        d.lightFloor = BacklightDim.deepestFloorLight
        #expect(abs(d.light(at: 1) - BacklightDim.deepestFloorLight) < 1e-12)
    }
}

@Suite struct ShiftTests {
    static let now = BacklightDimTests.evening, until = BacklightDimTests.until

    // Exactly the chosen position at the plan it was chosen at; then the same distance from the
    // plan all evening, whichever way the plan moves (room light lowers it too).
    @Test func ridesAlongWithThePlan() {
        let s = Shift(to: 0.7, at: 0.4, now: Self.now, until: Self.until)
        #expect(s.position(plan: 0.4, now: Self.now) == 0.7)
        #expect(abs(s.position(plan: 0.6, now: Self.now) - 0.9) < 1e-12)
        #expect(abs(s.position(plan: 0.2, now: Self.now) - 0.5) < 1e-12)   // a dip: by as much, not more
    }

    // The plan alone never takes a screen past the floor; a shift chosen below it rides down to it.
    @Test func neverPastTheFloorUnlessChosenThere() {
        let up = Shift(to: 0.9, at: 0.3, now: Self.now, until: Self.until)
        #expect(up.position(plan: 1, now: Self.now) == 1)
        let below = Shift(to: 1.5, at: 0.6, now: Self.now, until: Self.until)
        #expect(below.position(plan: 1, now: Self.now) == 1.5 && abs(below.position(plan: 0.4, now: Self.now) - 1.3) < 1e-9)
    }

    // The morning: by the clock, over the ramp and the fade-out, to nothing at `until`; then gone.
    @Test func shrinksToNothingByTheMorningsEnd() {
        for s in [Shift(to: 0.9, at: 0.4, now: Self.now, until: Self.until), Shift(to: 0.1, at: 0.4, now: Self.now, until: Self.until),
                  Shift(to: 1.8, at: 0.6, now: Self.now, until: Self.until)] {
            #expect(s.position(plan: 0, now: s.until) == 0 && s.expired(s.until))
            // Far from the plan, it starts and ends later (`perUnit`), the same small steps.
            let span = max(Shift.morningRamp + Shift.fadeOut, abs(s.to - s.at) * Shift.perUnit)
            #expect(s.until == Self.until.addingTimeInterval(span - Shift.morningRamp - Shift.fadeOut))
            let start = s.until.addingTimeInterval(-span)
            #expect(abs(s.position(plan: 0.5, now: start) - (0.5 + s.to - s.at)) < 1e-9)
            let offsets = stride(from: 0.0, through: span, by: 5)
                .map { s.offset(plan: 0, now: start.addingTimeInterval($0)) }
            #expect(zip(offsets, offsets.dropFirst()).allSatisfy { abs($0 - $1) < 0.01 })
        }
    }

    // Chosen late in the morning, still exactly what was chosen then, and 0 by its end, which
    // comes later for a deep one (`Shift.perUnit`), so no 5 s tick shows a step.
    @Test func aLateChoiceIsKeptAndStillEnds() {
        let late = Self.until.addingTimeInterval(-Shift.fadeOut - 60)
        let s = Shift(to: 0.9, at: 0.05, now: late, until: Self.until)
        #expect(abs(s.position(plan: 0.05, now: late) - 0.9) < 1e-12 && s.position(plan: 0, now: s.until) == 0)
        #expect(s.until > Self.until)   // deep and late: it takes longer than the evening's end
    }

    // Before the plan gets going a darker shift is held as chosen, then rides along as if taken
    // where the plan passed the threshold, whatever the plan did meanwhile (a launch mid-evening
    // jumps it); one that never gets going still eases away in the morning.
    @Test func heldUntilThePlanGetsGoing() {
        let held = Shift(to: 0.5, at: 0, now: Self.now, until: Self.until)
        #expect(held.isHeld && held.position(plan: 0.05, now: Self.now) == 0.5)
        #expect(held.position(plan: Shift.threshold, now: Self.now) == 0.5)
        #expect(abs(held.position(plan: 0.3, now: Self.now) - 0.7) < 1e-12)
        #expect(held.position(plan: 0.7, now: Self.now) == 1)   // the floor, wherever it was seen from
        let morning = Self.until.addingTimeInterval(-Shift.fadeOut)
        #expect(held.position(plan: 0, now: morning) < 0.5 && held.position(plan: 0, now: Self.until) == 0)
    }

    // Moved onto the plan, nothing is kept: no "Manual", no fast clock for a shift of nothing.
    @Test func aShiftOntoThePlanIsNone() {
        #expect(Shift.make(to: 0, at: 0, now: Self.now, until: Self.until) == nil)
        #expect(Shift.make(to: 0.4, at: 0.4, now: Self.now, until: Self.until) == nil)
        #expect(Shift.make(to: 0.5, at: 0.4, now: Self.now, until: Self.until) != nil)
    }

    // The morning, with the plan easing out as the schedule does (20 minutes, a smoothstep): a
    // screen made brighter (to its day level) never dims on the way; one the floor held darker
    // comes back in small, steady steps rather than at its full distance once the plan falls clear.
    @Test func theMorningNeverDipsOrJumps() {
        let start = Self.until.addingTimeInterval(-Shift.morningRamp - Shift.fadeOut)
        let plan = { (t: Double, from: Double) in from * (1 - smoothstepForTests(min(1, t / Shift.morningRamp))) }
        let lighter = Shift(to: 0, at: 0.64, now: Self.now, until: Self.until)
        let darker = Shift(to: 1, at: 0.4, now: Self.now, until: Self.until)   // held at the floor overnight
        var last = 1.0
        for t in stride(from: 0.0, through: Shift.morningRamp + Shift.fadeOut, by: 5) {
            let now = start.addingTimeInterval(t)
            #expect(lighter.position(plan: plan(t, 0.64), now: now) < 1e-9)
            let q = darker.position(plan: plan(t, 1), now: now)
            #expect(q <= last + 1e-12 && last - q < 0.02)
            last = q
        }
        #expect(last == 0)
    }

    // A lower floor moves a shift below it by the difference: same distance, same morning.
    @Test func movedKeepsItsDistanceAndEnd() {
        let s = Shift(to: 1.4, at: 0.6, now: Self.now, until: Self.until), m = s.moved(by: 0.2)
        #expect(m.until == s.until && abs(m.position(plan: 0.5, now: Self.now) - (s.position(plan: 0.5, now: Self.now) + 0.2)) < 1e-12)
    }

    // Bedtime or wake moved tonight: tonight's shifts end with the new morning, others stay.
    @Test func retimedOnlyTonight() {
        let s = Shift(to: 0.8, at: 0.5, now: Self.now, until: Self.until)
        #expect(s.retimed(from: Self.until, to: Self.until.addingTimeInterval(3600), now: Self.now).until == Self.until.addingTimeInterval(3600))
        // The coming evening's (its morning a day later), and one whose morning has begun.
        #expect(s.retimed(from: Self.until.addingTimeInterval(-86_400), to: Self.until, now: Self.now) == s)
        #expect(s.retimed(from: Self.until, to: Self.until.addingTimeInterval(3600), now: Self.until.addingTimeInterval(60)) == s)
    }

    // Lighter than the plan, a shift rides from anywhere.
    @Test func aLighterShiftRidesFromAnywhere() {
        let s = Shift(to: 0.02, at: 0.06, now: Self.now, until: Self.until)
        #expect(!s.isHeld && abs(s.position(plan: 0.06, now: Self.now) - 0.02) < 1e-12)
    }

    @Test func survivesBeingSaved() throws {
        let s = Shift(to: 1.2, at: 0.5, now: Self.now, until: Self.until)
        #expect(try JSONDecoder().decode(Shift.self, from: JSONEncoder().encode(s)) == s)
    }

    // A shift belongs to the evening it is chosen in, and ends with that evening's morning; once
    // the morning's plan is done, a move belongs to the coming evening.
    @Test func eachShiftBelongsToOneEvening() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let berlin = Coordinate(latitude: 52.52, longitude: 13.40)
        let schedule = Schedule()
        let at = { (h: Int, m: Int, day: Int) in cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: h, minute: m))! }
        let end = { (e: Schedule.Evening) in schedule.morningEnd(of: e, berlin, warmth: false, calendar: cal) }
        let night = schedule.shiftClocks(at: at(23, 0, 20), berlin, ends: [end], calendar: cal).clocks[0]
        #expect(!night.planDone && night.until > at(23, 0, 20) && night.until <= at(7, 10, 21))
        let fading = schedule.shiftClocks(at: night.until.addingTimeInterval(-60), berlin, ends: [end], calendar: cal).clocks[0]
        #expect(fading.planDone && fading.until > at(20, 0, 21))   // the coming evening's
        let noon = schedule.shiftClocks(at: at(12, 0, 21), berlin, ends: [end], calendar: cal).clocks[0]
        #expect(!noon.planDone && noon.until == fading.until)
        #expect(end(schedule.evening(around: at(23, 0, 20), berlin, calendar: cal)) <= at(7, 0, 21))
    }

    // Just after the morning's plan, on any day: the clocks going back (a 25 h day) or forward
    // included, it is done (a calendar day back, not 24 h).
    @Test func theMorningIsDoneAcrossClockChanges() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let berlin = Coordinate(latitude: 52.52, longitude: 13.40)
        let schedule = Schedule()
        let end = { (e: Schedule.Evening) in schedule.morningEnd(of: e, berlin, warmth: false, calendar: cal) }
        let missed = [(10, 23), (10, 24), (10, 25), (10, 26), (3, 28), (3, 29), (3, 30)].filter { month, day in
            let night = cal.date(from: DateComponents(year: 2026, month: month, day: day, hour: 3))!
            let done = end(schedule.evening(around: night, berlin, calendar: cal)).addingTimeInterval(180)
            return !schedule.shiftClocks(at: done, berlin, ends: [end], calendar: cal).clocks[0].planDone
        }.map { "\($0.0)-\($0.1)" }
        #expect(missed.isEmpty, "\(missed)")
    }

    // The midnight sun: the plan never leaves the day, so its morning "ends" at wake. A polar night
    // dims, and its morning ends by wake.
    @Test func polarMorningsEndByWake() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Oslo")!
        let tromso = Coordinate(latitude: 69.65, longitude: 18.96)
        let schedule = Schedule()
        for month in [6, 12] {
            let night = cal.date(from: DateComponents(year: 2026, month: month, day: 21, hour: 23))!
            let e = schedule.evening(around: night, tromso, calendar: cal)
            let end = schedule.morningEnd(of: e, tromso, warmth: false, calendar: cal)
            #expect(end <= e.wake && end > e.bedtime)
            if month == 6 { #expect(end == e.wake) }
        }
    }
}

/// The schedule's ease (`smoothstep` in GloamCore is internal).
func smoothstepForTests(_ t: Double) -> Double { t * t * (3 - 2 * t) }
