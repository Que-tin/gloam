// BacklightDim: what is written to a backlight, and how outside moves are adopted. Every bug
// here leaves a real screen too dim or too bright, often until the next morning.

import Foundation
import Testing
@testable import GloamCore

@Suite struct BacklightDimTests {
    /// One push, as the controller does it: the light to write, recorded as written (the write
    /// succeeds); nothing to write, the fraction is recorded anyway (`settle`).
    @discardableResult static func push(_ d: inout BacklightDim, _ fraction: Double) -> Double? {
        guard let light = d.light(for: fraction) else { d.settle(at: fraction); return nil }
        d.wrote(light, for: fraction)
        return light
    }

    /// The fraction the controller asks of this backlight for a schedule brightness (a position).
    static func asked(_ d: BacklightDim, _ brightness: Double) -> Double { d.asked(brightness) }

    // The schedule's scale onto a screen's own: untouched stays untouched, the deepest is that
    // screen's darkest, and the steps between keep their order.
    @Test func positionsMapOntoTheScreensRange() {
        #expect(Stage.brightness(1, darkest: 0.6) == 1)
        #expect(abs(Stage.brightness(Stage.brightnessRange.lowerBound, darkest: 0.6) - 0.6) < 1e-12)
        #expect(abs(Stage.brightness(0.55, darkest: Stage.brightnessRange.lowerBound) - 0.55) < 1e-12)
        let steps = stride(from: 1.0, through: 0.3, by: -0.05).map { Stage.brightness($0, darkest: 0.6) }
        #expect(zip(steps, steps.dropFirst()).allSatisfy { $0 > $1 })
    }

    // At full brightness the night lands about where the schedule says (its floor is near the
    // scale's end); a dimmer screen is dimmed less, never pinned to its floor by the night.
    @Test func aDimmerScreenIsDimmedLess() {
        let full = BacklightDim(baseline: 1), half = BacklightDim(baseline: 0.5), low = BacklightDim(baseline: 0.15)
        #expect(abs(Stage.brightness(0.55, darkest: full.darkest) - 0.55) < 0.02)
        let share = { (d: BacklightDim) in d.target(for: Self.asked(d, 0.55)) / d.baseline }
        #expect(share(half) > share(full) && share(low) > share(half))
        #expect(low.target(for: Self.asked(low, 0.55)) > BacklightDim.floorLight)
        #expect(abs(low.target(for: Self.asked(low, 0.3)) - BacklightDim.floorLight) < 1e-9)  // 100 %: its floor
    }

    // Tonight's range is measured from where the evening began: a press above the day level moves
    // the light, not the scale, so the next push doesn't dim it back.
    @Test func aPressAboveTheDayLevelKeepsTheRange() {
        var d = BacklightDim(baseline: 0.5)
        Self.push(&d, Self.asked(d, 0.55))
        let darkest = d.darkest
        d.observe(light: 0.6)
        #expect(d.darkest == darkest)
        #expect(Self.push(&d, Self.asked(d, 0.55)) == nil)
        #expect(Self.push(&d, 1) == 0.6 && d.eveningLevel == nil)  // the morning: the press, then a fresh range
    }

    @Test func dimsRelativeToTheBaselineAndRestoresIt() {
        var d = BacklightDim(baseline: 0.5)
        #expect(Self.push(&d, 0.27) == 0.135)
        #expect(d.isDimming)
        #expect(Self.push(&d, 0.27) == nil)  // already there: no write
        #expect(Self.push(&d, 1) == 0.5 && !d.isDimming)
        #expect(Self.push(&d, 1) == nil)
    }

    // Steps under the write threshold must add up: each is measured from what the panel shows,
    // not from the last step asked for, or a slow evening ramp never reaches the panel. The
    // backlight is read between ticks, as the app does, and Gloam's own level is no outside move.
    @Test func aSlowRampReachesItsTargetAndTheMorningRestores() {
        var d = BacklightDim(baseline: 0.8)
        var panel = 0.8
        for i in 1...540 {
            if let light = Self.push(&d, pow(1 - 0.45 * Double(i) / 540, 2.2)) { panel = light } else { d.observe(light: panel) }
        }
        #expect(abs(panel - 0.8 * pow(0.55, 2.2)) < 0.01)
        #expect(d.baseline == 0.8)
        panel = Self.push(&d, 1) ?? panel
        #expect(panel == 0.8)
    }

    // The morning always writes the baseline back, however close the last step got to it.
    @Test func aFadeBackRestoresExactly() {
        var d = BacklightDim(baseline: 0.5)
        var panel = Self.push(&d, 0.27)!
        for i in 1...120 {
            if let light = Self.push(&d, 0.27 + 0.73 * Double(i) / 120) { panel = light }
        }
        #expect(panel == 0.5 && !d.isDimming)
    }

    // A write that fails records nothing, so the next push tries again.
    @Test func aFailedWriteIsRetried() {
        let d = BacklightDim(baseline: 0.5)
        #expect(d.light(for: 0.5) == 0.25)  // not recorded: the write failed
        #expect(!d.isDimming && d.light(for: 0.5) == 0.25)
    }

    // A key press or auto-brightness moving the backlight is adopted, not fought: tonight's
    // curve goes through it, and the morning restores the day level (exactly, by its slider).
    @Test func outsideMovesAreAdopted() {
        var d = BacklightDim(baseline: 0.5)
        Self.push(&d, 0.5)                        // writes 0.25
        d.observe(light: 0.25)                    // own write echoed: nothing changes
        #expect(d.baseline == 0.5)
        d.baselineLevel = 0.5
        d.observe(light: 0.125)                   // user halved it
        #expect(Self.push(&d, 0.5) == nil)
        let deeper = Self.push(&d, 0.4)!                                  // deeper: from the press, toward the floor
        #expect(deeper < 0.125 && deeper > BacklightDim.floorLight)
        #expect(d.baseline == 0.5 && d.baselineLevel == 0.5 && Self.push(&d, 1) == 0.5)
    }

    // At the light floor a key press up used to be written straight back down, and each press
    // grew the morning level. Now the end moves to where the user put it; the morning doesn't.
    @Test func aKeyPressAtTheFloorHolds() {
        var d = BacklightDim(baseline: 0.2)
        #expect(Self.push(&d, 0.3) == BacklightDim.floorLight)
        var panel = 0.08
        for _ in 0..<5 {
            panel += 0.02
            d.observe(light: panel)
            #expect(Self.push(&d, 0.3) == nil)
        }
        // At the ladder's end the press is the end tonight: nothing deeper writes it back.
        #expect(Self.push(&d, 0.25) == nil)
        #expect(d.baseline == 0.2)
        #expect(Self.push(&d, 1) == 0.2)
    }

    // The morning ease-out never shows more light than the user had: neither the level they
    // chose tonight nor their day level. (Anchoring at the requested fraction peaked near full.)
    @Test func theEaseOutNeverOvershoots() {
        var d = BacklightDim(baseline: 0.5)
        #expect(Self.push(&d, 0.05) == BacklightDim.floorLight)
        d.observe(light: 0.10)
        var peak = 0.0
        for i in 0...100 {
            if let light = Self.push(&d, 0.05 + 0.95 * Double(i) / 100) { peak = max(peak, light) }
        }
        #expect(peak <= 0.5 + 1e-9 && !d.isDimming)
    }

    // Held at the floor above the curve, a press down below even the curve is kept, not
    // pushed back up to the curve's level on the next write.
    @Test func aPressBelowTheCurveAtTheFloorHolds() {
        var d = BacklightDim(baseline: 0.5)
        #expect(Self.push(&d, 0.1) == BacklightDim.floorLight)  // the curve wants 0.05
        d.observe(light: 0.03)
        #expect(Self.push(&d, 0.1) == nil)
        #expect(Self.push(&d, 0.08) == nil)       // a deeper step keeps the user's level too
    }

    // Down below the curve at the floor and back up: the press back holds, and the morning is
    // no brighter than the day level (scaled by the press back, it came back 60 % brighter).
    @Test func aPressDownAndBackUpAtTheFloorKeepsTheMorning() {
        var d = BacklightDim(baseline: 0.5)
        Self.push(&d, 0.1)                        // the floor, 0.08; the curve wants 0.05
        d.observe(light: 0.04)
        #expect(Self.push(&d, 0.1) == nil)
        d.observe(light: 0.08)
        #expect(Self.push(&d, 0.1) == nil && d.target(for: 1) == 0.5)
    }

    // On the curve above the floor, down below it and back: the day level comes back too.
    @Test func aPressDownPastTheFloorAndBackKeepsTheMorning() {
        var d = BacklightDim(baseline: 0.5)
        Self.push(&d, 0.2)                        // 0.1, on the curve
        d.observe(light: 0.05)
        #expect(Self.push(&d, 0.2) == nil)
        d.observe(light: 0.1)
        #expect(Self.push(&d, 0.2) == nil && d.target(for: 1) == 0.5)
    }

    // A slow evening ramp stops writing just above the floor (each step under `same`), on the
    // curve of an earlier fraction: a press up there is still a press at the floor.
    @Test func aPressUpAfterASlowRampIntoTheFloorKeepsTheMorning() {
        var d = BacklightDim(baseline: 0.5)
        var f = 1.0
        while f > 0.1 { f -= 0.0005; Self.push(&d, f) }
        d.observe(light: 0.15)
        #expect(Self.push(&d, 0.1) == nil)
        d.observe(light: 0.25)
        #expect(Self.push(&d, 0.1) == nil && d.target(for: 1) == 0.5)
    }

    // At the floor, pressed up and up: the floor follows, the morning stays the day level.
    @Test func pressesUpAtTheFloorDontRaiseTheMorning() {
        var d = BacklightDim(baseline: 0.5)
        Self.push(&d, 0.1)                        // 0.08
        d.observe(light: 0.2)
        #expect(Self.push(&d, 0.1) == nil)        // held, not written back down
        d.observe(light: 0.3)
        #expect(Self.push(&d, 0.1) == nil && d.target(for: 1) == 0.5)
    }

    // Brighter than the day level at night: the morning keeps it rather than dimming.
    @Test func aPressAboveTheDayLevelBecomesIt() {
        var d = BacklightDim(baseline: 0.2)
        Self.push(&d, 0.3)                        // floor 0.08
        d.observe(light: 0.5)
        #expect(Self.push(&d, 0.3) == nil && d.baseline == 0.5)
    }

    // Below the floor is the user's call too: kept, and the ladder's last steps go deeper still.
    @Test func aKeyPressBelowTheFloorHolds() {
        var d = BacklightDim(baseline: 0.5)
        Self.push(&d, 0.3)                        // 0.15
        d.observe(light: 0.05)
        #expect(Self.push(&d, 0.3) == nil)
        let deeper = Self.push(&d, 0.25)!
        #expect(deeper < 0.05 && deeper > 0)
    }

    // Turned all the way down and back up: the fraction survives, so the press isn't halved.
    @Test func adoptionThroughZeroKeepsTheFraction() {
        var d = BacklightDim(baseline: 0.5)
        Self.push(&d, 0.5)
        d.observe(light: 0)
        d.observe(light: 0.3)
        #expect(Self.push(&d, 0.5) == nil)
    }

    @Test func fullBrightnessAtNightIsLeftAlone() {
        var d = BacklightDim(baseline: 0.6)
        Self.push(&d, 0.3)
        d.observe(light: 1)                       // user went to maximum
        #expect(Self.push(&d, 0.3) == nil)        // not dimmed again
        let later = Self.push(&d, 0.15)!          // a later stage dims from it, toward the floor
        #expect(later < 1 && later > BacklightDim.floorLight)
        #expect(Self.push(&d, 1) == 1)            // morning: the top, not more
    }

    @Test func neverBelowTheLightFloorNorAboveTheBaseline() {
        var d = BacklightDim(baseline: 0.2)
        #expect(Self.push(&d, 0.3) == BacklightDim.floorLight)  // 0.06 wanted, floor 0.08 holds
        #expect(abs(pow(d.darkest, Kelvin.displayGamma) - 0.4) < 1e-9)  // the ladder's end: the floor
        var low = BacklightDim(baseline: 0.05)
        #expect(Self.push(&low, 0.3) == nil && low.darkest == 1)  // already under the floor: untouched
        var u = BacklightDim(baseline: 0.5)
        Self.push(&u, 0.5)
        #expect(Self.push(&u, 0.9) == 0.45)
    }

    // A DDC monitor reads back on its own 1/100 scale: its rounding is the write, not a move.
    @Test func aMonitorsRoundingIsNoOutsideMove() {
        var d = BacklightDim(baseline: 0.5, step: 0.01)
        for i in 0..<200 {
            let f = 0.2 + 0.02 * Double(i % 5)
            if let light = Self.push(&d, f) { d.observe(light: (light * 100).rounded() / 100) }
        }
        #expect(d.baseline == 0.5)
        #expect(Self.push(&d, 1) == 0.5)
    }

    @Test func undimmedBaselineFollowsTheSystem() {
        var d = BacklightDim(baseline: 0.5)
        d.observe(light: 0.9)
        #expect(d.baseline == 0.9 && !d.isDimming)
        d.observe(light: .nan)
        #expect(d.baseline == 0.9)
    }

    // Saved while dimming, so a launch after a crash can restore the morning level.
    @Test func survivesBeingSaved() throws {
        var d = BacklightDim(baseline: 0.6)
        Self.push(&d, 0.3)
        d.observe(light: 0.1)
        let back = try JSONDecoder().decode(BacklightDim.self, from: JSONEncoder().encode(d))
        #expect(back == d)
    }

    // Past the recommended night the floor eases: the same ask goes deeper, and the lowest
    // fraction follows (the popover's ladder ends there).
    @Test func aLowerFloorGoesDeeper() {
        var d = BacklightDim(baseline: 0.5)
        #expect(Self.push(&d, 0.1) == BacklightDim.floorLight)   // 0.05 asked, 0.08 holds
        d.lightFloor = BacklightDim.deepestFloorLight
        #expect(abs(Self.push(&d, 0.1)! - 0.05) < 1e-9)         // now reached
        #expect(abs(pow(d.darkest, Kelvin.displayGamma) - 0.06) < 1e-9)  // the ladder's end follows
    }

    // The floor follows the settings, not the panel: never saved.
    @Test func lightFloorIsNotSaved() throws {
        var d = BacklightDim(baseline: 0.5)
        d.lightFloor = 0.03
        Self.push(&d, 0.5)
        let back = try JSONDecoder().decode(BacklightDim.self, from: JSONEncoder().encode(d))
        #expect(back.lightFloor == BacklightDim.floorLight && back.written == d.written)
    }

    // A monitor with 50 steps walks one step per write, rounded up (the signal dims the rest),
    // and records each step as dimming until the release lands on the baseline.
    @Test func aMonitorWalksOneStepAtATime() {
        var d = BacklightDim(baseline: 12.0 / 50, step: 1.0 / 50)
        var lights: [Int] = []
        while let (light, fraction) = d.nextStep(for: 0.3) {
            lights.append(Int((light * 50).rounded()))
            d.wrote(light, for: fraction)
        }
        #expect(lights == [11, 10, 9, 8, 7, 6, 5, 4])   // 0.3 × 12 = 3.6 is under the light floor (4 of 50)
        #expect(d.isDimming)
        var back: [Int] = []
        while let (light, fraction) = d.nextStep(for: 1) {
            back.append(Int((light * 50).rounded()))
            d.wrote(light, for: fraction)
        }
        #expect(back == [5, 6, 7, 8, 9, 10, 11, 12] && !d.isDimming)
    }

    // Rounded up onto the curve, the last step is recorded there: a press on the monitor's own
    // buttons afterwards is kept, and the ladder's end is still the floor.
    @Test func aRoundedStepStaysOnTheCurve() {
        var d = BacklightDim(baseline: 0.24, step: 0.02)
        while let (light, fraction) = d.nextStep(for: 0.55) { d.wrote(light, for: fraction) }
        #expect(abs(d.written! - 0.14) < 1e-9)          // 0.132 asked, up to 7 of 50
        d.observe(light: 0.20)
        #expect(abs(d.target(for: pow(d.darkest, Kelvin.displayGamma)) - BacklightDim.floorLight) < 1e-9)
        #expect(d.nextStep(for: 0.55) == nil)            // and the press is kept, not undone
    }

    // A baseline off the step grid (scaled by an outside move) is never exceeded.
    @Test func roundingNeverGoesAboveTheLightFound() {
        var d = BacklightDim(baseline: 0.245, step: 0.02), highest = 0.0
        for asked in [0.8, 0.99] {
            while let (light, fraction) = d.nextStep(for: asked) {
                highest = max(highest, light)
                d.wrote(light, for: fraction)
            }
        }
        #expect(d.isDimming && highest <= 0.245)
    }

    // One press on a monitor's own buttons is the user's, on 0–50 and 0–100 scales alike, at
    // the floor and high up; Gloam's own write read back (rounded by half a step) is not.
    @Test func aOneStepPressIsAdopted() {
        for (steps, written) in [(50, 4), (100, 80)] {
            let step = 1.0 / Double(steps)
            var d = BacklightDim(baseline: 0.9, step: step)
            d.wrote(Double(written) * step, for: 0.5)
            #expect(d.same(d.written!, d.written! + step * 0.4))
            d.observe(light: d.written! + step)
            #expect(abs(d.written! - Double(written + 1) * step) < 1e-9, "\(steps): adopted")
        }
    }

    // After a crash mid-fade the panel sits on tonight's curve, above or below what was saved:
    // still Gloam's (the morning restores the baseline). At the baseline, brighter, or under the
    // floor, it's the user's.
    @Test func aCrashMidFadeStillResumes() {
        var d = BacklightDim(baseline: 0.6)
        d.wrote(0.2, for: 1.0 / 3)
        #expect(d.resumes(at: 0.2) && d.resumes(at: 0.35))
        #expect(d.resumes(at: 0.1))                // a fade down saved before it ended: still on the curve
        #expect(!d.resumes(at: 0.6) && !d.resumes(at: 0.9) && !d.resumes(at: 0.05))
        #expect(!BacklightDim(baseline: 0.6).resumes(at: 0.3))  // not dimming: nothing to resume
    }

    // Pressed up mid-ladder, every step still dims: deeper steps go from the press to the floor,
    // the ladder's end is still the floor, and lighter ones climb to the day level.
    @Test func aPressUpLeavesTheLadderWorking() {
        var d = BacklightDim(baseline: 0.5)
        Self.push(&d, 0.3)                        // 0.15
        d.observe(light: 0.3)
        #expect(Self.push(&d, 0.3) == nil)
        let end = pow(d.darkest, Kelvin.displayGamma)
        let lights = stride(from: 1.0, through: end, by: -(1 - end) / 20).map { d.target(for: $0) }
        #expect(zip(lights, lights.dropFirst()).allSatisfy { $0 > $1 })
        #expect(abs(d.target(for: end) - BacklightDim.floorLight) < 1e-9)
    }

    // Pressed up at the ladder's end, the press is the end tonight: it isn't written back, and
    // the ladder above it still climbs to the day level.
    @Test func aPressUpAtTheEndBecomesTheEnd() {
        var d = BacklightDim(baseline: 0.5)
        let end = pow(d.darkest, Kelvin.displayGamma)
        Self.push(&d, end)                        // the floor, 0.08
        d.observe(light: 0.2)
        #expect(Self.push(&d, end) == nil)
        let mid = Self.push(&d, (1 + end) / 2)!
        #expect(mid > 0.2 && mid < 0.5)
        #expect(Self.push(&d, 1) == 0.5)
    }

    // A screen at or under the floor never needs a write, so it never started dimming; a key
    // press up then became its baseline and the next push dimmed it straight back.
    // The controller asks such a screen just under 1 (its range is empty), which starts the
    // evening; a press is then its level, kept all night and in the morning.
    @Test func aPressOnAScreenAtTheFloorIsKept() {
        var d = BacklightDim(baseline: 0.08)
        let asked = Self.asked(d, 0.55)
        #expect(d.darkest == 1 && asked < 1 && Self.push(&d, asked) == nil && d.isDimming)
        d.observe(light: 0.12)
        #expect(Self.push(&d, asked) == nil && Self.push(&d, Self.asked(d, 0.3)) == nil)
        #expect(Self.push(&d, 1) == 0.12)          // the morning keeps it
    }

    // Pressed down mid-evening, the morning climbs back to the day level along the curve: no
    // single tick of the 20-minute ease jumps (the multiplied curve snapped 2× at the release).
    @Test func theMorningAfterAPressDownHasNoJump() {
        var d = BacklightDim(baseline: 0.5)
        var panel = Self.push(&d, Self.asked(d, 0.55))!
        panel /= 2
        d.observe(light: panel, asked: Self.asked(d, 0.55))
        var largest = 1.0
        for i in 1...240 {
            let t = Double(i) / 240, b = 0.55 + 0.45 * t * t * (3 - 2 * t)
            if let light = Self.push(&d, Self.asked(d, b)) { largest = max(largest, light / panel); panel = light }
        }
        #expect(panel == 0.5 && !d.isDimming && largest < 1.1)
    }

    // The blue-light reading counts the light the user chose: halving it at night halves the level.
    @Test func aPressMovesTheChosenLevel() {
        var d = BacklightDim(baseline: 0.5)
        let asked = Self.asked(d, 0.55)
        let light = Self.push(&d, asked)!
        #expect(abs(d.chosenLevel - 0.5) < 1e-9)
        d.observe(light: light / 2, asked: asked)
        #expect(abs(d.chosenLevel - 0.25) < 1e-6)
    }

    // A crash at the end of a fade down: the panel sits below the last saved light, still on
    // tonight's curve, so the morning still restores the day level.
    @Test func aCrashAfterAFadeDownResumes() throws {
        var d = BacklightDim(baseline: 0.75)
        Self.push(&d, Self.asked(d, 0.7))                          // saved here
        let saved = try JSONDecoder().decode(BacklightDim.self, from: JSONEncoder().encode(d))
        let panel = d.target(for: Self.asked(d, 0.55))             // the fade went on, unsaved
        var left = saved
        #expect(left.resumes(at: panel))
        left.resume(at: panel)
        #expect(Self.push(&left, Self.asked(left, 0.55)) == nil && Self.push(&left, 1) == 0.75)
    }

    // Consent's deepest floor is reachable from a bright screen: its darkest isn't held to the
    // signal's own 30 %.
    @Test func theDeepestFloorIsReachableFromABrightScreen() {
        var d = BacklightDim(baseline: 1)
        d.lightFloor = BacklightDim.deepestFloorLight
        #expect(d.darkest < Stage.brightnessRange.lowerBound)
        #expect(abs(d.target(for: Self.asked(d, Stage.brightnessRange.lowerBound)) - BacklightDim.deepestFloorLight) < 1e-9)
    }

    // Random evenings (fixed seed), driven as the controller drives them: with key presses up
    // and down at any point, the morning is the day level or the highest press above it, and
    // the next tick never writes a press back. (A wider version of this ran 150,000 evenings.)
    @Test func randomEveningsKeepTheMorningAndThePresses() {
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func random() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        for _ in 0..<300 {
            let day = 0.05 + 0.95 * random(), end = 0.03 + 0.9 * random(), n = 200 + Int(random() * 1500)
            var d = BacklightDim(baseline: day), panel = day, highest = 0.0
            func ask(_ i: Int) -> Double {
                i < n ? 1 - (1 - end) * Double(i + 1) / Double(n) : end + (1 - end) * Double(i - n + 1) / 300
            }
            for i in 0..<(n + 300) {
                let f = ask(i), drift = abs(f - ask(i - 1)) / f  // the schedule's own move this tick
                var pressed: Double?
                if random() < 0.01, d.isDimming {
                    let next = pow(min(1, max(0, pow(panel, 1 / 2.2) + (random() < 0.5 ? -2 : 2) / 16.0)), 2.2)
                    if !d.same(next, panel) { panel = next; pressed = next; highest = max(highest, next) }
                }
                let before = d.target(for: f)   // where the curve would have taken it without the press
                d.observe(light: panel, asked: f)  // as the controller reads: after setting what it asks
                if let light = Self.push(&d, f) { panel = light }
                // Not written back: the next write stays with the press (the schedule's own move
                // this tick aside), well away from where the old curve was. Not while the morning
                // climbs: it rises to the day level from wherever the user left the light.
                if let p = pressed, f < 1, f <= ask(i - 1), !d.same(before, p) {
                    #expect(abs(panel - p) <= 0.25 * abs(before - p) + p * (4 * drift + 0.011) + 1e-9)
                }
            }
            for _ in 0..<2 { d.observe(light: panel); if let light = Self.push(&d, 1) { panel = light } }
            #expect(panel >= min(1, day) - 1e-9 && panel <= max(min(1, day), highest) + 1e-9)
        }
    }
}
