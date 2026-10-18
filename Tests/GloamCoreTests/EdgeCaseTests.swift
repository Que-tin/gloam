// Edges the everyday suites don't reach: times just past a stage's clock time, sunsets after
// midnight, invalid numbers and odd input from outside.

import Foundation
import Testing
@testable import GloamCore


@Suite struct UpcomingTests {
    // Between a stage's clock time and its ease crossing halfway (~20 min), the nominal time is
    // already past: a hand setting held until then ended on the next tick.
    @Test(arguments: [(6, 21), (12, 21)])
    func neverInThePast(month: Int, day: Int) {
        let cal = calendar("Europe/Berlin"), s = Schedule()
        let midnight = cal.date(from: DateComponents(year: 2026, month: month, day: day))!
        for minute in stride(from: 0, to: 24 * 60, by: 2) {
            let t = midnight.addingTimeInterval(Double(minute) * 60)
            for next in s.upcoming(after: t, berlin, calendar: cal) {
                #expect(next.at > t, "at \(minute / 60):\(minute % 60)")
            }
        }
    }

    @Test func nominalTimeWhileStillAhead() {
        let cal = calendar("Europe/Berlin")
        let t = cal.date(from: DateComponents(year: 2026, month: 12, day: 21, hour: 21, minute: 0))!
        let next = Schedule().upcoming(after: t, berlin, count: 1, calendar: cal).first!
        #expect(next.kind == .night && cal.component(.hour, from: next.at) == 22 && cal.component(.minute, from: next.at) == 0)
    }
}

@Suite struct SunsetAfterMidnightTests {
    // Reykjavik in late June: the sun sets after midnight, so the calendar day's only sunset
    // is the previous night's, at 00:03.
    @Test func eveningUsesTonightsSunset() {
        let cal = calendar("Atlantic/Reykjavik")
        let afternoon = cal.date(from: DateComponents(year: 2026, month: 6, day: 21, hour: 18))!
        let e = Schedule().evening(around: afternoon, reykjavik, calendar: cal)
        let sunset = try! #require(e.sunset)
        #expect(sunset > afternoon && sunset < e.wake)
        #expect(e.windDown! >= sunset && e.night! >= sunset)
    }
}

@Suite struct InvalidNumberTests {
    @Test func nanLeavesTheScreenAlone() {
        #expect(Tint(kelvin: .nan, brightness: .nan) == .neutral)
        let warm = Tint(kelvin: 2700, brightness: 0.7)
        #expect(Tint.mix(warm, .neutral, .nan) == warm)
    }
}

@Suite struct InputTests {
    @Test func nonASCIIDigitsAreRejected() {
        #expect(Place.parseISO6709("+5²30+01322") == nil)
        #expect(Place.parseISO6709("+٥٢30+01322") == nil)
    }
}

@Suite struct AllowanceTests {
    @Test func dimmingAllowanceRoundTrips() {
        var s = Schedule()
        #expect(abs(s.dimmingAllowance - 1) < 1e-9)
        for a in [0.0, 0.25, 0.5, 1] {
            s.dimmingAllowance = a
            #expect(abs(s.dimmingAllowance - a) < 1e-9)
        }
        s.dimmingAllowance = 0
        #expect(s.darkest == 1)
        s.dimmingAllowance = 7
        #expect(s.darkest == Schedule.darkestRange.lowerBound)
    }
}
