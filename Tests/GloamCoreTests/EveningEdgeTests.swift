// Evenings at the edges of what can be set: extreme bedtime and wake pairs, polar and
// sub-arctic winters, the night the clocks go back, "until morning", and the graph's span.

import Foundation
import Testing
@testable import GloamCore

private func at(_ cal: Calendar, _ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
    cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

private func schedule(bed: ClockTime, wake: ClockTime) -> Schedule {
    var s = Schedule()
    s.bedtime = bed
    s.wake = wake
    return s
}


@Suite struct EveningEdgeTests {
    static let extremes: [(ClockTime, ClockTime)] = [
        (ClockTime(20, 0), ClockTime(4, 0)), (ClockTime(20, 0), ClockTime(12, 0)),
        (ClockTime(3, 0), ClockTime(4, 0)), (ClockTime(3, 0), ClockTime(12, 0)),
        (ClockTime(23, 0), ClockTime(7, 0)),
    ]

    // Strictly in order and all in the future, whatever the rhythm, in the far north's winter
    // (sunrise long after an early wake) and over the nights the clocks go back.
    @Test(arguments: [
        ("Atlantic/Reykjavik", reykjavik, 2026, 1, 1), ("Europe/Oslo", tromso, 2026, 1, 15),
        ("Europe/Berlin", berlin, 2026, 10, 24), ("Australia/Sydney", sydney, 2026, 4, 4),
    ] as [(String, Coordinate, Int, Int, Int)])
    func upcomingStaysInOrder(zone: String, place: Coordinate, year: Int, month: Int, day: Int) {
        let cal = calendar(zone)
        for (bed, wake) in Self.extremes {
            let s = schedule(bed: bed, wake: wake)
            for hour in stride(from: 0, to: 48, by: 2) {
                let now = at(cal, year, month, day, 0).addingTimeInterval(Double(hour) * 3600)
                var last = now
                for next in s.upcoming(after: now, place, count: 4, calendar: cal) {
                    #expect(next.at > last, "\(zone) bed \(bed.hour) wake \(wake.hour) at +\(hour) h")
                    last = next.at
                }
            }
        }
    }

    // Reykjavik, New Year: wake at 04:00, the hold after waking runs out at 09:00 in the dark,
    // and day comes with the sun at about 11:10, not with tomorrow's wake.
    @Test func dayAfterADarkMorningIsSunrise() {
        let cal = calendar("Atlantic/Reykjavik"), s = schedule(bed: ClockTime(20, 0), wake: ClockTime(4, 0))
        let now = at(cal, 2026, 1, 1, 10, 10)
        let next = s.upcoming(after: now, reykjavik, count: 1, calendar: cal).first!
        #expect(next.kind == .day && next.at < at(cal, 2026, 1, 1, 13))
    }

    // Clocks go back at 03:00: a night under way stays night through the repeated hour.
    @Test(arguments: [
        ("Europe/Berlin", berlin, 2026, 10, 25), ("Australia/Sydney", sydney, 2026, 4, 5),
    ] as [(String, Coordinate, Int, Int, Int)])
    func fallBackKeepsTheNight(zone: String, place: Coordinate, year: Int, month: Int, day: Int) {
        let cal = calendar(zone), s = schedule(bed: ClockTime(3, 0), wake: ClockTime(4, 0))
        let start = at(cal, year, month, day, 1, 50)  // before the change
        for minute in stride(from: 0, through: 120, by: 5) {
            let t = start.addingTimeInterval(Double(minute) * 60)
            let f = s.factors(at: t, place, calendar: cal)
            if minute >= 40 { #expect(s.stage(at: t, place, calendar: cal) == .night, "+\(minute) min") }
            if minute > 0 {
                let before = s.factors(at: t.addingTimeInterval(-300), place, calendar: cal)
                #expect(f.night >= before.night - 1e-9, "night eased back at +\(minute) min")
            }
        }
    }

    // Tromsø at midsummer: nothing ever changes, so "until morning" is the coming wake.
    @Test func nextMorningInPolarDayIsTheComingWake() {
        let cal = calendar("Europe/Oslo")
        let morning = Schedule().nextMorning(after: at(cal, 2026, 6, 21, 23, 10), tromso, calendar: cal)
        #expect(morning == at(cal, 2026, 6, 22, 7))
    }

    @Test func nextMorningIsAheadAndWithinADayAndABit() {
        let cal = calendar("Europe/Berlin")
        for (bed, wake) in Self.extremes {
            let s = schedule(bed: bed, wake: wake)
            for hour in stride(from: 0, to: 24, by: 1) {
                let now = at(cal, 2026, 1, 10, hour)
                let m = s.nextMorning(after: now, berlin, calendar: cal)
                #expect(m > now && m.timeIntervalSince(now) <= 30 * 3600, "bed \(bed.hour) wake \(wake.hour) at \(hour)")
            }
        }
    }

    // The graph never shows more than a day (no clock hour twice) and always both markers,
    // even when a polar winter's "sunset" is at noon and wake is late.
    @Test(arguments: [("Europe/Oslo", tromso, 11, 25), ("Europe/Oslo", tromso, 1, 10),
                      ("Europe/Berlin", berlin, 6, 21), ("Atlantic/Reykjavik", reykjavik, 6, 21)]
          as [(String, Coordinate, Int, Int)])
    func spanStaysWithinADay(zone: String, place: Coordinate, month: Int, day: Int) {
        let cal = calendar(zone)
        for bed in ClockTime.all(in: Schedule.bedtimes) where bed.minute == 0 {
            for wake in ClockTime.all(in: Schedule.wakes) where wake.minute == 0 {
                let e = schedule(bed: bed, wake: wake).evening(around: at(cal, 2026, month, day, 14), place, calendar: cal)
                let span = e.span
                #expect(span.upperBound.timeIntervalSince(span.lowerBound) <= 24 * 3600)
                #expect(span.contains(e.bedtime) && span.contains(e.wake))
            }
        }
    }

    @Test func extremePairsSurviveSaving() throws {
        for (bed, wake) in Self.extremes {
            let s = schedule(bed: bed, wake: wake)
            let back = try JSONDecoder().decode(Schedule.self, from: JSONEncoder().encode(s))
            #expect(back.bedtime == bed && back.wake == wake)
        }
        let odd = try JSONDecoder().decode(Schedule.self, from: Data(#"{"wake":{"hour":-3,"minute":0}}"#.utf8))
        #expect(odd.wake == ClockTime(4, 0))  // 21:00, nearer the start of 04:00–12:00
        // Saved by a build without them: the defaults.
        let old = try JSONDecoder().decode(Schedule.self, from: Data(#"{"warmest":1900,"darkest":0.55}"#.utf8))
        #expect(old.bedtime == ClockTime(23, 0) && old.wake == ClockTime(7, 0))
    }

    // "At least 8 h awake" holds for every pair the graph can set.
    @Test func everySettablePairIsARhythm() {
        for bed in ClockTime.all(in: Schedule.bedtimes) {
            for wake in ClockTime.all(in: Schedule.wakes) {
                let s = schedule(bed: bed, wake: wake)
                let awake = (bed.minutesOfDay - wake.minutesOfDay + 1440) % 1440
                #expect(s.isRhythmValid && awake >= 8 * 60)
            }
        }
    }
}
