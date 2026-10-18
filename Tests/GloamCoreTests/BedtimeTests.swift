// Bedtime and wake as settings: held to a night-time sleep in quarter hours, saved, and moving
// the stages with them (including a bedtime after midnight).

import Foundation
import Testing
@testable import GloamCore

@Suite struct BedtimeTests {
    @Test func heldToTheWindowInQuarterHours() {
        let bed = Schedule.bedtimes
        #expect(ClockTime(23, 7).held(to: bed) == ClockTime(23, 0))
        #expect(ClockTime(23, 8).held(to: bed) == ClockTime(23, 15))
        #expect(ClockTime(15, 0).held(to: bed) == ClockTime(20, 0))   // nearer the start
        #expect(ClockTime(5, 0).held(to: bed) == ClockTime(3, 0))     // nearer the end, past midnight
        #expect(ClockTime(3, 10).held(to: bed) == ClockTime(3, 0))    // rounds out of the window
        #expect(ClockTime(23, 55).held(to: bed) == ClockTime(0, 0))   // rounds across midnight
    }

    @Test func settableTimes() {
        let beds = ClockTime.all(in: Schedule.bedtimes), wakes = ClockTime.all(in: Schedule.wakes)
        #expect(beds.count == 29 && beds.first == ClockTime(20, 0) && beds.last == ClockTime(3, 0))
        #expect(wakes.count == 33 && wakes.first == ClockTime(4, 0) && wakes.last == ClockTime(12, 0))
    }

    // Dragging a marker along one night: clamped to that night's window, never flipped around
    // the clock to the far end.
    @Test func dragAlongTheNight() {
        let cal = berlinCalendar
        func at(_ day: Int, _ h: Int, _ m: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 12, day: day, hour: h, minute: m))! }
        let evening = at(10, 13, 0), morning = at(11, 1, 0)
        #expect(ClockTime.along(Schedule.bedtimes, startingOn: evening, at: at(10, 23, 8), calendar: cal) == ClockTime(23, 15))
        #expect(ClockTime.along(Schedule.bedtimes, startingOn: evening, at: at(11, 1, 53), calendar: cal) == ClockTime(2, 0))
        #expect(ClockTime.along(Schedule.bedtimes, startingOn: evening, at: at(11, 9, 0), calendar: cal) == ClockTime(3, 0))   // far right
        #expect(ClockTime.along(Schedule.bedtimes, startingOn: evening, at: at(10, 15, 0), calendar: cal) == ClockTime(20, 0)) // far left
        #expect(ClockTime.along(Schedule.wakes, startingOn: morning, at: at(10, 21, 0), calendar: cal) == ClockTime(4, 0))   // was 12:00
        #expect(ClockTime.along(Schedule.wakes, startingOn: morning, at: at(11, 13, 30), calendar: cal) == ClockTime(12, 0))
        #expect(ClockTime.along(Schedule.wakes, startingOn: morning, at: at(11, 7, 20), calendar: cal) == ClockTime(7, 15))
    }

    // A 01:00 bedtime in winter: wind-down at 22:00, night at midnight, all within one evening.
    @Test func stagesFollowALateBedtime() {
        var s = Schedule()
        s.bedtime = ClockTime(1, 0)
        s.wake = ClockTime(9, 0)
        let cal = berlinCalendar
        let t = cal.date(from: DateComponents(year: 2026, month: 12, day: 10, hour: 18))!
        let e = s.evening(around: t, berlin, calendar: cal)
        let clock = { (d: Date?) in d.map { cal.dateComponents([.day, .hour, .minute], from: $0) } }
        #expect(clock(e.windDown) == DateComponents(day: 10, hour: 22, minute: 0))
        #expect(clock(e.night) == DateComponents(day: 11, hour: 0, minute: 0))
        #expect(clock(e.wake) == DateComponents(day: 11, hour: 9, minute: 0))
        #expect(s.stage(at: cal.date(from: DateComponents(year: 2026, month: 12, day: 10, hour: 23, minute: 0))!, berlin, calendar: cal) == .windDown)
    }
}
