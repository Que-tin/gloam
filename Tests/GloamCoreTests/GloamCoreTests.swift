// The core's main suite: colour temperature, the sun, the schedule's stages and saving,
// colour spaces, clock times, commands, smearing, melanopic light, locations, engine policy.

import Foundation
import Testing
@testable import GloamCore

private func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
/// Display P3, XYZ → linear RGB.
private let p3: LinearRGB = { c in
    RGB(2.4934969 * c.x - 0.9313836 * c.y - 0.4027108 * c.z,
        -0.8294890 * c.x + 1.7626641 * c.y + 0.0236247 * c.z,
        0.0358458 * c.x - 0.0761724 * c.y + 0.9568845 * c.z)
}

@Suite struct ColorTemperatureTests {
    @Test func daylightIsIdentity() {
        let g = Kelvin.displayGain(.neutral)
        #expect(abs(g.red - 1) < 1e-9 && abs(g.green - 1) < 1e-9 && abs(g.blue - 1) < 1e-9)
    }

    @Test func warmerMeansLessBlueThenLessGreen() {
        var last = Kelvin.linearGain(6500)
        for k in stride(from: 6000.0, through: 1000, by: -500) {
            let g = Kelvin.linearGain(k)
            #expect(g.red == 1)
            #expect(g.green < last.green && g.blue <= last.blue)
            #expect(g.blue <= g.green)
            last = g
        }
    }

    @Test func nanIsDaylight() {
        #expect(Kelvin.linearGain(.nan) == Kelvin.linearGain(Kelvin.daylight))
    }

    // Ingo Thies' measured blackbody table (2013, display-encoded) at 3400K is ≈ (1.00, 0.79, 0.59);
    // ours comes out a little lower in blue, within the tolerance.
    @Test func tracksBlackbodyReference() {
        let g = Kelvin.displayGain(Tint(kelvin: 3400))
        #expect(abs(g.green - 0.79) < 0.03)
        #expect(abs(g.blue - 0.56) < 0.06)
    }

    @Test func clampsOutOfRange() {
        #expect(Kelvin.linearGain(200) == Kelvin.linearGain(1000))
        #expect(Kelvin.linearGain(20000) == Kelvin.linearGain(6500))
    }

    @Test func brightnessScalesAllChannels() {
        let g = Kelvin.displayGain(Tint(kelvin: 6500, brightness: 0.5))
        #expect(g == RGB(0.5, 0.5, 0.5))
    }

    @Test func mixIsLinearInMireds() {
        let mid = Tint.mix(Tint(kelvin: 6500), Tint(kelvin: 2000), 0.5)
        #expect(abs(Kelvin.mired(mid.kelvin) - (1e6 / 6500 + 1e6 / 2000) / 2) < 1e-6)
        #expect(mid.kelvin < 4250)  // a Kelvin lerp would have said 4250
    }
}

@Suite struct SunTests {
    @Test func berlinSummerNoonIsHighAndMidnightIsDark() {
        #expect(Sun.elevation(at: date("2026-06-21T11:10:00Z"), berlin) > 59)
        #expect(Sun.elevation(at: date("2026-06-21T23:00:00Z"), berlin) < -10)
    }

    // Published Berlin times for 2026-06-21: sunrise 04:43, sunset 21:33 (CEST).
    @Test func riseAndSetMatchAlmanac() throws {
        let (rise, set) = riseAndSet(on: date("2026-06-21T10:00:00Z"), berlin, calendar: berlinCalendar)
        let r = try #require(rise), s = try #require(set)
        #expect(abs(r.timeIntervalSince(date("2026-06-21T02:43:00Z"))) < 180)
        #expect(abs(s.timeIntervalSince(date("2026-06-21T19:33:00Z"))) < 180)
    }

    @Test func polarNightHasNoSunrise() {
        let (rise, set) = riseAndSet(on: date("2026-12-21T12:00:00Z"), tromso)
        #expect(rise == nil && set == nil)
    }
}

@Suite struct ScheduleTests {
    private func at(_ h: Int, _ m: Int, month: Int = 6, day: Int = 21) -> Date {
        berlinCalendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: h, minute: m))!
    }
    private func tint(_ s: Schedule, _ d: Date) -> Tint { s.tint(at: d, berlin, calendar: berlinCalendar) }
    private func stage(_ s: Schedule, _ d: Date) -> StageKind { s.stage(at: d, berlin, calendar: berlinCalendar) }

    @Test func nightFactorBounds() {
        #expect(Schedule.nightFactor(elevation: 30) == 0)
        #expect(Schedule.nightFactor(elevation: -20) == 1)
        let dusk = Schedule.nightFactor(elevation: -1.5)
        #expect(dusk > 0.4 && dusk < 0.6)
    }

    @Test func stagesFollowTheEvening() {
        let s = Schedule()  // wake 07:00, bed 23:00; Berlin in March: sunset ≈ 18:15
        #expect(tint(s, at(13, 0, month: 3)) == .neutral)
        #expect(stage(s, at(13, 0, month: 3)) == .day)
        #expect(stage(s, at(19, 0, month: 3)) == .sunset)
        #expect(stage(s, at(20, 50, month: 3)) == .windDown)
        #expect(tint(s, at(21, 30, month: 3)).brightness == s.windDown.brightness)
        #expect(stage(s, at(22, 30, month: 3)) == .night)
        #expect(tint(s, at(3, 0, month: 3)) == s.night.tint)
    }

    // Berlin, June: sunset 21:33. A 20:00 wind-down would dim the screen in daylight.
    @Test func neverDimsWhileTheSunIsUp() {
        let s = Schedule()
        let e = s.evening(around: at(16, 0), berlin, calendar: berlinCalendar)
        #expect(e.windDown == e.sunset)  // the timeline says so too
        #expect(tint(s, at(20, 30)).brightness == 1)
        #expect(stage(s, at(20, 30)) == .day)
        #expect(stage(s, at(22, 30)) == .night)  // the sun is well down by then
        #expect(tint(s, at(1, 0)) == s.night.tint)
    }

    @Test func winterSunsetComesBeforeWindDown() {
        let s = Schedule()  // Berlin sunset ≈ 15:55 on 21 Dec
        #expect(stage(s, at(18, 0, month: 12)) == .sunset)
        #expect(tint(s, at(18, 0, month: 12)) == s.sunset.tint)
    }

    @Test func morningIsDaylightAtWakeEvenBeforeSunrise() {
        let s = Schedule()  // Berlin sunrise ≈ 08:15 on 21 Dec
        #expect(tint(s, at(6, 30, month: 12)).kelvin < 3000)
        #expect(tint(s, at(7, 0, month: 12)) == .neutral)
        #expect(tint(s, at(7, 30, month: 12)) == .neutral)
    }

    // Every minute of a winter and a summer day: nothing snaps. The steepest legitimate
    // change is the 20-minute morning ease-out (~28 mired/min); a snap would be ~370.
    @Test(arguments: [6, 12]) func tintIsContinuous(month: Int) {
        var s = Schedule()
        s.wake = ClockTime(11, 0)  // puts the end of the morning hold (16:00) after a winter sunset
        var last = tint(s, at(0, 0, month: month))
        for minute in 1..<1440 {
            let t = tint(s, at(minute / 60, minute % 60, month: month))
            #expect(abs(Kelvin.mired(t.kelvin) - Kelvin.mired(last.kelvin)) < 40, "jump at minute \(minute)")
            #expect(abs(t.brightness - last.brightness) < 0.05, "jump at minute \(minute)")
            last = t
        }
    }

    @Test func nextStageFindsWhatArrivesFirst() {
        var s = Schedule()
        #expect(s.nextStage(after: at(13, 0), berlin, calendar: berlinCalendar)?.kind != .day)
        #expect(s.nextStage(after: at(13, 0, month: 12), berlin, calendar: berlinCalendar)?.kind == .sunset)
        #expect(s.nextStage(after: at(21, 0, month: 3), berlin, calendar: berlinCalendar)?.kind == .night)
        #expect(s.nextStage(after: at(3, 0), berlin, calendar: berlinCalendar)?.kind == .day)
        s.wake = ClockTime(16, 0)  // invalid rhythm, in a midnight-sun June: nothing ever happens
        #expect(s.nextStage(after: at(13, 0), tromso, calendar: berlinCalendar) == nil)
    }

    @Test func eveningBelongsToTheNextWake() {
        let s = Schedule()  // bed 23:00, wake 07:00
        let afternoon = s.evening(around: at(16, 0), berlin, calendar: berlinCalendar)
        #expect(afternoon.wake == at(7, 0, day: 22) && afternoon.bedtime == at(23, 0))
        #expect(afternoon.windDown == afternoon.sunset && afternoon.night == at(22, 0))  // June: dimming waits for sunset
        let march = s.evening(around: at(16, 0, month: 3), berlin, calendar: berlinCalendar)
        #expect(march.windDown == at(20, 0, month: 3) && march.night == at(22, 0, month: 3))
        let s2 = afternoon.sunset.map { berlinCalendar.component(.hour, from: $0) }
        #expect(s2 == 21)  // tonight's June sunset, not tomorrow's
        // At 03:00 the evening is the one still under way.
        let small = s.evening(around: at(3, 0, day: 22), berlin, calendar: berlinCalendar)
        #expect(small.wake == at(7, 0, day: 22) && small.bedtime == at(23, 0))
    }

    @Test(arguments: [(1, 0), (3, 30)]) func eveningsAfterMidnightStayInOrder(bed: (Int, Int)) {
        var s = Schedule()
        s.bedtime = ClockTime(bed.0, bed.1)
        s.wake = ClockTime(11, 0)
        for hour in [16, 23] {
            let e = s.evening(around: at(hour, 0), berlin, calendar: berlinCalendar)
            let order = [e.sunset!, e.windDown!, e.night!, e.bedtime, e.wake]
            #expect(order == order.sorted(), "evening around \(hour):00 is out of order")
            #expect(e.wake > at(hour, 0) && e.wake.timeIntervalSince(at(hour, 0)) <= 86_400)
        }
    }

    // Berlin falls back on 25 Oct 2026 and springs forward on 29 Mar 2026.
    @Test(arguments: [(10, 24), (3, 28)]) func daylightSavingNightsKeepWallClockTimes(date: (Int, Int)) {
        var s = Schedule()
        s.bedtime = ClockTime(0, 0)
        let e = s.evening(around: at(18, 0, month: date.0, day: date.1), berlin, calendar: berlinCalendar)
        let clock = { (d: Date?) in d.map { berlinCalendar.dateComponents([.hour, .minute], from: $0) } }
        #expect(clock(e.windDown) == DateComponents(hour: 21, minute: 0))
        #expect(clock(e.night) == DateComponents(hour: 23, minute: 0))
        #expect(clock(e.bedtime) == DateComponents(hour: 0, minute: 0))
    }

    @Test func lateWakeKeepsSunsetBeforeBed() {
        var s = Schedule()
        s.wake = ClockTime(13, 0)
        s.bedtime = ClockTime(5, 0)
        let e = s.evening(around: at(10, 0), berlin, calendar: berlinCalendar)
        #expect(e.sunset! < e.windDown! && e.windDown! < e.bedtime && e.bedtime < e.wake)
    }

    // Polar night: no sunset to wait for, so wind-down and night come at their clock times.
    @Test func eveningWithoutSunset() {
        let e = Schedule().evening(around: at(12, 0, month: 12), tromso, calendar: berlinCalendar)
        #expect(e.sunset == nil && e.windDown! < e.night! && e.night! < e.bedtime)
    }

    @Test(arguments: [6, 12]) func depthIsContinuousAndOrdered(month: Int) {
        let s = Schedule()
        var last = s.depth(at: at(0, 0, month: month), berlin, calendar: berlinCalendar)
        for minute in 1..<1440 {
            let d = s.depth(at: at(minute / 60, minute % 60, month: month), berlin, calendar: berlinCalendar)
            #expect(abs(d - last) < 0.1, "depth jump at minute \(minute)")
            last = d
        }
        #expect(s.depth(at: at(13, 0, month: month), berlin, calendar: berlinCalendar) == 0)
        #expect(s.depth(at: at(3, 0, month: month), berlin, calendar: berlinCalendar) == 1)
    }

    @Test func windowsCrossMidnightWithEasedEdges() {
        // 22:00 → 07:00
        #expect(Schedule.window(21 * 60 + 59, from: 1320, to: 420) == 0)
        let easing = Schedule.window(22 * 60 + 20, from: 1320, to: 420)
        #expect(easing > 0 && easing < 1)
        #expect(Schedule.window(2 * 60, from: 1320, to: 420) == 1)
        #expect(Schedule.window(7 * 60, from: 1320, to: 420) == 0)
        // A bedtime of 01:00 puts wind-down at 22:00 the previous evening.
        #expect(Schedule.window(23 * 60, from: 60 - 180, to: 420) == 1)
        #expect(Schedule.window(600, from: 420, to: 420) == 0)
    }

    @Test func upcomingListsTheNextChangesInOrder() {
        let s = Schedule()
        let evening = s.upcoming(after: at(21, 15, month: 3), berlin, calendar: berlinCalendar)
        #expect(evening.map(\.kind) == [.night, .day])
        #expect(evening.map(\.at) == [at(22, 0, month: 3), at(7, 0, month: 3, day: 22)])
        let summerDay = s.upcoming(after: at(14, 0), berlin, calendar: berlinCalendar)
        #expect(summerDay.first?.kind == .windDown)  // June: wind-down waits for sunset, no separate sunset step
        let winterDay = s.upcoming(after: at(14, 0, month: 12), berlin, calendar: berlinCalendar)
        #expect(winterDay.map(\.kind) == [.sunset, .windDown])
    }

    // Limits hold the automatic tint back only where it would cross them.
    @Test func limitsOnlyBiteWhereCrossed() {
        var s = Schedule()
        let night = at(3, 0, month: 3), windDown = at(21, 15, month: 3)
        #expect(tint(s, night) == s.night.tint)  // the defaults are the recommended night
        s.darkest = 0.7
        s.warmest = 2700
        #expect(tint(s, night) == Tint(kelvin: 2700, brightness: 0.7))
        #expect(tint(s, windDown) == s.windDown.tint)  // already within both
        s.darkest = 0
        #expect(s.darkest == Schedule.darkestRange.lowerBound)
    }

    // Past the recommended night the settings take the night deeper; earlier stages stay put.
    @Test func deeperThanRecommendedTakesTheNightThere() {
        var s = Schedule()
        s.warmest = 1200
        s.darkest = 0.3
        #expect(tint(s, at(1, 0)) == Tint(kelvin: 1200, brightness: 0.3))
        #expect(tint(s, at(21, 30, month: 3)) == s.windDown.tint)  // wind-down untouched
    }

    @Test func warmthAllowanceMapsTheCapBothWays() {
        var s = Schedule()
        #expect(abs(s.warmthAllowance - 0.548) < 0.001)  // the recommended 1900 K, a little past half
        s.warmthAllowance = 0
        #expect(abs(s.warmest - Kelvin.daylight) < 1e-6)
        s.warmthAllowance = 0.5
        #expect(abs(s.warmthAllowance - 0.5) < 1e-9)
        s.warmthAllowance = 2
        #expect(abs(s.warmest - Stage.kelvinRange.lowerBound) < 1e-6)  // clamped to ember
    }

    @Test func lowBacklightEasesTheSmearFloor() {
        // The measured panel: clean up to 50 %, faint at 60 %, stronger at 80 %.
        #expect(Schedule.backlightFactor(1) == 1 && Schedule.backlightFactor(0.85) == 1)
        #expect(Schedule.backlightFactor(0.5) == 0 && Schedule.backlightFactor(0.2) == 0)
        #expect(Schedule.backlightFactor(0.6) > 0 && Schedule.backlightFactor(0.6) < Schedule.backlightFactor(0.8))
    }

    @Test func roomLightEasesDimmingOnlyInABrightRoom() {
        let s = Schedule()
        let night = at(3, 0, month: 3)
        #expect(Schedule.roomFactor(lux: 0) == 1 && Schedule.roomFactor(lux: 10) == 1)
        #expect(abs(Schedule.roomFactor(lux: 500) - 1.0 / 3) < 1e-9 && Schedule.roomFactor(lux: 5000) == Schedule.roomFactor(lux: 500))
        let bright = s.tint(at: night, berlin, roomLux: 800, calendar: berlinCalendar)
        #expect(abs(bright.brightness - 0.85) < 1e-9 && bright.kelvin == s.night.kelvin)  // 45% dimming → 15%
    }

    @Test func decodingIsTolerant() throws {
        let json = #"{"bedtime":{"hour":1,"minute":30},"darkest":0.8,"warmest":99999}"#
        let s = try JSONDecoder().decode(Schedule.self, from: Data(json.utf8))
        // Out of range is clamped, and the night follows the Warmest and Dimmest settings.
        #expect(s.bedtime == ClockTime(1, 30) && s.night == Stage(kelvin: Kelvin.daylight, brightness: 0.8))
        #expect(s.darkest == 0.8 && s.warmest == Kelvin.daylight)
        let back = try JSONDecoder().decode(Schedule.self, from: JSONEncoder().encode(s))
        #expect(back == s)
        // A hand-edited hour too big to multiply is reduced (to 07:00, held to 03:00), not a crash.
        let huge = #"{"bedtime":{"hour":9223372036854775807,"minute":0}}"#
        #expect(try JSONDecoder().decode(Schedule.self, from: Data(huge.utf8)).bedtime == ClockTime(3, 0))
    }
}

@Suite struct ColourSpaceTests {
    // The matrix built from a display's primaries must be the standard P3 one.
    @Test func primariesGiveTheDisplaysMatrix() throws {
        let built = try #require(Kelvin.linearRGB(
            red: XYZ(x: 0.4865709, y: 0.2289746, z: 0),
            green: XYZ(x: 0.2656677, y: 0.6917385, z: 0.0451134),
            blue: XYZ(x: 0.1982173, y: 0.0792869, z: 1.0439444)))
        for k in [6500.0, 3400, 1900, 1200] {
            let (a, b) = (built(Kelvin.xyz(k)), p3(Kelvin.xyz(k)))
            #expect(abs(a.red - b.red) < 1e-4 && abs(a.green - b.green) < 1e-4 && abs(a.blue - b.blue) < 1e-4)
        }
        #expect(Kelvin.linearRGB(red: XYZ(x: 1, y: 0, z: 0), green: XYZ(x: 2, y: 0, z: 0), blue: XYZ(x: 0, y: 0, z: 1)) == nil)
    }

    // 1900K lies outside sRGB: there blue all but vanishes (a purer red than asked for); a P3
    // panel can show it, so it keeps some blue. Daylight stays an identity in both.
    @Test func wideGamutKeepsTheWarmWhiteOnTheLocus() {
        #expect(Kelvin.linearGain(1900).blue < 0.001)
        #expect(Kelvin.linearGain(1900, in: p3).blue > 0.02)
        let white = Kelvin.displayGain(.neutral, in: p3)
        #expect(abs(white.red - 1) < 1e-9 && abs(white.green - 1) < 1e-9 && abs(white.blue - 1) < 1e-9)
    }
}

@Suite struct ClockTimeTests {
    @Test func wrapsAroundTheDay() {
        #expect(ClockTime(26, 0) == ClockTime(2, 0))
        #expect(ClockTime(0, -15) == ClockTime(23, 45))
    }
}

@Suite struct CommandTests {
    private func cmd(_ s: String) -> Command? { Command(url: URL(string: s)!) }

    @Test func parsesEveryRoute() {
        #expect(cmd("gloam://toggle") == .toggle)
        #expect(cmd("gloam://on") == .on && cmd("gloam://OFF") == .off)
        #expect(cmd("gloam://open") == .open)
        #expect(cmd("GLOAM://toggle") == .toggle)  // schemes are case-insensitive
        #expect(cmd("gloam://explode") == nil && cmd("other://toggle") == nil)
    }
}

@Suite struct SmearTests {
    @Test func luminanceWeightsComeFromTheSpace() {
        let s = Kelvin.luminanceWeights(of: Kelvin.sRGB)
        #expect(abs(s.red - 0.2126) < 0.002 && abs(s.green - 0.7152) < 0.002 && abs(s.blue - 0.0722) < 0.002)
        let p = Kelvin.luminanceWeights(of: p3)
        #expect(abs(p.red - 0.2290) < 0.002 && abs(p.green - 0.6917) < 0.002 && abs(p.blue - 0.0793) < 0.002)
    }

    // The night stage's white has under half of daylight white's light before any dimming:
    // the same band as the 55% neutral dim (27%) that smeared, not the 80% (61%) that didn't.
    @Test func aWarmWhiteIsADimWhite() {
        #expect(abs(Smear.luminance(.neutral, in: p3) - 1) < 1e-9)
        #expect(abs(Smear.luminance(Tint(kelvin: 1900), in: p3) - 0.45) < 0.02)
        #expect(abs(Smear.luminance(Tint(kelvin: 6500, brightness: 0.8), in: p3) - pow(0.8, 2.2)) < 1e-9)
    }

    @Test func floorGivesUpDimmingBeforeWarmth() {
        let floor = pow(0.8, 2.2)
        let sunset = Tint(kelvin: 3400)
        #expect(Smear.limited(sunset, floor: floor, in: p3) == sunset)
        let dusk = Smear.limited(Tint(kelvin: 3000, brightness: 0.7), floor: floor, in: p3)
        #expect(dusk.kelvin == 3000 && dusk.brightness > 0.9 && dusk.brightness < 1)
        let night = Smear.limited(Tint(kelvin: 1900, brightness: 0.55), floor: floor, in: p3)
        #expect(night.brightness == 1 && night.kelvin > 2700 && night.kelvin < 2900)  // ≈ 2600 K on the XDR's own profile
        #expect(abs(Smear.luminance(night, in: p3) - floor) < 1e-3)
        #expect(Smear.limited(Tint(kelvin: 1200, brightness: 0.3), floor: 0, in: p3) == Tint(kelvin: 1200, brightness: 0.3))
    }

    // `warmest` is where the limit eases warmth to when full brightness is too dim.
    @Test func warmestSitsOnTheFloor() {
        let floor = 0.5
        let warm = Smear.warmest(brightness: 0.9, floor: floor, in: p3)
        #expect(abs(Smear.luminance(Tint(kelvin: warm, brightness: 0.9), in: p3) - floor) < 1e-3)
        #expect(Smear.warmest(brightness: 1, floor: 0, in: p3) == Kelvin.range.lowerBound)
        #expect(Smear.warmest(brightness: 0.5, floor: floor, in: p3) == Kelvin.daylight)
    }
}

@Suite struct MelanopicTests {
    @Test func whiteIsOne() {
        #expect(abs(Melanopic.relative(.neutral) - 1) < 1e-9)
    }

    // In the default (sRGB) space; docs/science.md gives a P3 LCD's, a little higher.
    @Test func warmthAloneRoughlyHalves() {
        #expect(abs(Melanopic.relative(Tint(kelvin: 3400)) - 0.45) < 0.08)
        #expect(abs(Melanopic.relative(Tint(kelvin: 1900)) - 0.18) < 0.06)
    }

    @Test func dimmingIsCountedInLinearLight() {
        // Half the signal is about a fifth of the light (0.5^2.2).
        #expect(abs(Melanopic.relative(Tint(kelvin: 6500, brightness: 0.5)) - 0.218) < 0.01)
    }

    @Test func defaultBedtimeIsUnderATenth() {
        #expect(Melanopic.relative(Schedule().night.tint) < 0.06)
    }
}

@Suite struct LocationTests {
    @Test func parsesBothCoordinateForms() {
        let a = Place.parseISO6709("+5230+01322")!
        #expect(abs(a.latitude - 52.5) < 1e-9 && abs(a.longitude - 13.3667) < 1e-3)
        let b = Place.parseISO6709("+404251-0740023")!
        #expect(abs(b.latitude - 40.7142) < 1e-3 && abs(b.longitude + 74.0064) < 1e-3)
        #expect(Place.parseISO6709("garbage") == nil)
    }

    @Test func findsZoneInTable() {
        let table = "# comment\nDE\t+5230+01322\tEurope/Berlin\tmost of Germany\nUS\t+404251-0740023\tAmerica/New_York\n"
        #expect(Place.parse(zoneTab: table, zone: TimeZone(identifier: "America/New_York")!)?.name == "New York")
        #expect(Place.parse(zoneTab: table, zone: TimeZone(identifier: "Asia/Tokyo")!) == nil)
    }

    @Test func systemTableResolvesCurrentZone() {
        #expect(Place.forTimeZone(TimeZone(identifier: "Europe/Berlin")!)?.name == "Berlin")
    }

    /// Names macOS still reports that the table has renamed: not Greenwich, which is light at 22:00.
    @Test func oldZoneNamesFindTheirNewRow() {
        #expect(Place.forTimeZone(TimeZone(identifier: "Asia/Calcutta")!)?.name == "Kolkata")
        #expect(Place.forTimeZone(TimeZone(identifier: "Europe/Kiev")!)?.name == "Kyiv")
        #expect(Place.forTimeZone(TimeZone(identifier: "Asia/Rangoon")!)?.name == "Yangon")
        // Toronto's rules are also Nassau's: the Mac's country decides.
        #expect(Place.forTimeZone(TimeZone(identifier: "America/Montreal")!, region: "CA")?.name == "Toronto")
    }
}

@Suite struct EnginePolicyTests {
    @Test func autoPicksOverlayOnlyForKnownBrokenChips() {
        #expect(EnginePolicy.resolve(.auto, chip: "Apple M5 Max", osMajor: 26) == .overlay)
        #expect(EnginePolicy.resolve(.auto, chip: "Apple M5 Max", osMajor: 15) == .gamma)
        #expect(EnginePolicy.resolve(.auto, chip: "Apple M2", osMajor: 27) == .gamma)
        #expect(EnginePolicy.resolve(.gamma, chip: "Apple M5 Max", osMajor: 26) == .gamma)
    }
}
