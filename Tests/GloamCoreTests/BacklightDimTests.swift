// BacklightDim: what is written to a backlight, and how outside moves are adopted. Every bug
// here leaves a real screen too dim or too bright, often until the next morning.

import Foundation
import Testing
@testable import GloamCore

@Suite struct BacklightDimTests {
    /// One push: the light to write, recorded as written (the write succeeds).
    @discardableResult static func push(_ d: inout BacklightDim, _ fraction: Double) -> Double? {
        guard let light = d.light(for: fraction) else { return nil }
        d.wrote(light, for: fraction)
        return light
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

    // A key press or auto-brightness moving the backlight is adopted, not fought: the fraction
    // now applies to the new level, and the morning restores the moved level.
    @Test func outsideMovesAreAdopted() {
        var d = BacklightDim(baseline: 0.5)
        Self.push(&d, 0.5)                        // writes 0.25
        d.observe(light: 0.25)                    // own write echoed: nothing changes
        #expect(d.baseline == 0.5)
        d.baselineLevel = 0.5
        d.observe(light: 0.125)                   // user halved it
        #expect(abs(d.baseline - 0.25) < 1e-9 && Self.push(&d, 0.5) == nil && d.baselineLevel == nil)
        #expect(abs(Self.push(&d, 1)! - 0.25) < 1e-9)
    }

    // At the light floor a key press up used to be written straight back down, and each press
    // grew the morning level. Now the floor moves to where the user put it; the morning doesn't.
    @Test func aKeyPressAtTheFloorHolds() {
        var d = BacklightDim(baseline: 0.2)
        #expect(Self.push(&d, 0.3) == BacklightDim.floorLight)
        var panel = 0.08
        for _ in 0..<5 {
            panel += 0.02
            d.observe(light: panel)
            #expect(Self.push(&d, 0.3) == nil)
        }
        #expect(Self.push(&d, 0.25) == nil)       // a deeper stage keeps the level chosen
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

    // Brighter than the day level at night: the morning keeps it rather than dimming.
    @Test func aPressAboveTheDayLevelBecomesIt() {
        var d = BacklightDim(baseline: 0.2)
        Self.push(&d, 0.3)                        // floor 0.08
        d.observe(light: 0.5)
        #expect(Self.push(&d, 0.3) == nil && d.baseline == 0.5)
    }

    // Below the floor is the user's call too.
    @Test func aKeyPressBelowTheFloorHolds() {
        var d = BacklightDim(baseline: 0.5)
        Self.push(&d, 0.3)                        // 0.15
        d.observe(light: 0.05)
        #expect(Self.push(&d, 0.3) == nil && Self.push(&d, 0.25) == nil)
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
        #expect(abs(Self.push(&d, 0.15)! - 0.5) < 1e-9)  // a later stage scales from the adopted level
        #expect(Self.push(&d, 1) == 1)            // morning: the top, not more
    }

    @Test func neverBelowTheLightFloorNorAboveTheBaseline() {
        var d = BacklightDim(baseline: 0.2)
        #expect(Self.push(&d, 0.3) == BacklightDim.floorLight)  // 0.06 wanted, floor 0.08 holds
        #expect(abs(d.lowestFraction - 0.4) < 1e-9)
        var low = BacklightDim(baseline: 0.05)
        #expect(Self.push(&low, 0.3) == nil && low.lowestFraction == 1)  // already under the floor: untouched
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
        #expect(abs(d.lowestFraction - 0.06) < 1e-9)
    }

    // The floor follows the settings, not the panel: never saved, and states saved before it
    // existed still load.
    @Test func lightFloorIsNotSaved() throws {
        var d = BacklightDim(baseline: 0.5)
        d.lightFloor = 0.03
        Self.push(&d, 0.5)
        let back = try JSONDecoder().decode(BacklightDim.self, from: JSONEncoder().encode(d))
        #expect(back.lightFloor == BacklightDim.floorLight && back.written == d.written)
        let old = #"{"baseline":0.5,"written":0.25,"fraction":0.5,"step":0}"#
        #expect(try JSONDecoder().decode(BacklightDim.self, from: Data(old.utf8)).written == 0.25)
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
    // buttons afterwards scales the baseline, and doesn't read as raising the floor.
    @Test func aRoundedStepStaysOnTheCurve() {
        var d = BacklightDim(baseline: 0.24, step: 0.02)
        while let (light, fraction) = d.nextStep(for: 0.55) { d.wrote(light, for: fraction) }
        #expect(abs(d.written! - 0.14) < 1e-9)          // 0.132 asked, up to 7 of 50
        d.observe(light: 0.20)
        #expect(d.lowestFraction < 0.5)                  // not held at 0.20
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
}
