// The schedule: turns (time, place, settings) into a Tint.
//
// Sunset leads; bedtime deepens it (see docs/science.md):
// - Sunset warms as the sun goes down, so dusk is as long as it really is where you are.
// - Wind-down (from 3 h before bedtime, the window the 2022 consensus sets a ≤10 lx
//   melanopic ceiling for) and Night (from 1 h before) also dim, because intensity ×
//   spectrum is what counts and warmth alone removes only about half.
// - Neither dims before the sun is setting (the gate eases in from 3° above the horizon):
//   dimming a screen in daylight reads as broken and anyone who wants it can lower
//   brightness by hand. In summer they follow sunset instead.
// Bedtime defaults to 23:00 (it fits ~60% of adults within an hour) and wake to 07:00; both
// can be moved in Settings, never asked in onboarding. They are held to a night-time sleep
// (`bedtimes`, `wakes`), which also keeps at least 8 h awake, so wind-down always fits after
// waking and "never before sunset" stays meaningful. ("Bedtime" always means the clock time,
// never a stage.) Everything is back to daylight by wake time.
//
// The stages are fixed, evidence-based values. The personal settings, `warmest` and `darkest`,
// are where the night goes (by default the recommended night); no earlier stage goes past them,
// so "not so dark at night" never means taking over by hand, and "deeper" is the same setting. (Per-stage values and
// global strengths were both tried and cut: they made "back to automatic" unclear.) Optionally
// room light, where a sensor can see it, eases the dimming in a bright room (`roomFactor`).
//
// Decoding tolerates missing keys and clamps out-of-range values, so adding a setting or a
// hand-edited preference never wipes or breaks a user's schedule.

import Foundation

public struct ClockTime: Codable, Hashable, Sendable {
    public var hour: Int
    public var minute: Int

    public init(_ hour: Int, _ minute: Int) {
        let m = ((hour * 60 + minute) % 1440 + 1440) % 1440
        (self.hour, self.minute) = (m / 60, m % 60)
    }

    public init(minutesOfDay m: Int) { self.init(0, m) }
    public var minutesOfDay: Int { hour * 60 + minute }

    /// Rounded to the settings' quarter hour and held inside `window` (minutes of the day, may
    /// wrap past midnight); outside it, the nearer end.
    public func held(to window: (from: Int, to: Int)) -> ClockTime {
        let step = Schedule.timeStep
        let m = (minutesOfDay + step / 2) / step * step % 1440
        let into = (m - window.from + 1440) % 1440, length = (window.to - window.from + 1440) % 1440
        if into <= length { return ClockTime(minutesOfDay: m) }
        let pastEnd = into - length, beforeStart = 1440 - into
        return ClockTime(minutesOfDay: pastEnd <= beforeStart ? window.to : window.from)
    }

    /// The settable time a point in time lands on when dragged along one night: `window` starts
    /// on `day` (the night's evening for bedtime, its morning for wake). Clamped along that
    /// timeline, so past either end it stays at that end; `held(to:)` picks the end nearer around
    /// the clock, which flipped a far drag to the opposite end.
    public static func along(_ window: (from: Int, to: Int), startingOn day: Date, at date: Date,
                             calendar: Calendar = .current) -> ClockTime? {
        guard let start = calendar.date(bySettingHour: window.from / 60, minute: window.from % 60, second: 0, of: day)
        else { return nil }
        let length = Double((window.to - window.from + 1440) % 1440), step = Double(Schedule.timeStep)
        let minutes = (min(length, max(0, date.timeIntervalSince(start) / 60)) / step).rounded() * step
        return ClockTime(minutesOfDay: window.from + Int(minutes))
    }

    /// Every settable time in `window`, in order (the graph's keyboard and VoiceOver steps).
    public static func all(in window: (from: Int, to: Int)) -> [ClockTime] {
        let length = (window.to - window.from + 1440) % 1440
        return stride(from: 0, through: length, by: Schedule.timeStep).map { ClockTime(minutesOfDay: window.from + $0) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(try c.decodeIfPresent(Int.self, forKey: .hour) ?? 0,
                  try c.decodeIfPresent(Int.self, forKey: .minute) ?? 0)
    }
}

public struct Stage: Equatable, Sendable {
    public let kelvin: Double
    public let brightness: Double

    public static let kelvinRange = 1200.0...6500.0
    /// Below ~30% gamma dimming crushes shadows and bands; the hardware backlight should go first.
    public static let brightnessRange = 0.3...1.0

    public init(kelvin: Double, brightness: Double) {
        self.kelvin = Self.kelvinRange.clamp(kelvin)
        self.brightness = Self.brightnessRange.clamp(brightness)
    }

    public var tint: Tint { Tint(kelvin: kelvin, brightness: brightness) }
}

public enum StageKind: Sendable {
    case day, sunset, windDown, night
}

public struct Schedule: Codable, Equatable, Sendable {
    public var wake = ClockTime(7, 0)
    public var bedtime = ClockTime(23, 0)
    /// The settable times, as minutes of the day (bedtime wraps past midnight): what Settings
    /// offers and what a saved schedule is held to. Any pair from these leaves at least 8 h awake
    /// (20:00 bed, 12:00 wake) and at most 16 h asleep. Set directly (tests), anything goes.
    public static let bedtimes = (from: 20 * 60, to: 3 * 60), wakes = (from: 4 * 60, to: 12 * 60)
    /// Settings step through the times in quarter hours.
    public static let timeStep = 15
    public let sunset = Stage(kelvin: 3400, brightness: 1)
    public let windDown = Stage(kelvin: 2700, brightness: 0.7)
    /// The night the evidence recommends (docs/science.md), and the default of the settings.
    public static let recommendedNight = Stage(kelvin: 1900, brightness: 0.55)
    /// Night goes to the Warmest and Dimmest settings, and no earlier stage goes past them: one
    /// rule, so "automatic" stays clear. Lighter than recommended they hold the evening back;
    /// deeper (to ember, to 30 %) is for sensitive people in dark rooms, past a warning.
    public var night: Stage { Stage(kelvin: warmest, brightness: darkest) }
    public var warmest = recommendedNight.kelvin { didSet { warmest = Self.warmestRange.clamp(warmest) } }
    public var darkest = recommendedNight.brightness { didSet { darkest = Self.darkestRange.clamp(darkest) } }
    public static let warmestRange = Stage.kelvinRange
    public static let darkestRange = Stage.brightnessRange

    /// How far past the recommended night the settings go, 0 (at it or lighter) … 1 (ember,
    /// 30 %), each linear on its own scale (warmth in mired). Past it is the user's consent to
    /// what deeper costs: the smear floor and the backlight's light floor ease off with it, so
    /// the setting does what it says instead of stopping where the recommended night would.
    public var pastRecommended: (warmth: Double, dimming: Double) {
        let r = Self.recommendedNight
        let warmth = (Kelvin.mired(warmest) - Kelvin.mired(r.kelvin)) / (Self.mired.warm - Kelvin.mired(r.kelvin))
        let dimming = (r.brightness - darkest) / (r.brightness - Stage.brightnessRange.lowerBound)
        return ((0.0...1.0).clamp(warmth), (0.0...1.0).clamp(dimming))
    }

    /// Warmest as a slider, 0 (daylight) … 1 (ember), mired-even like the popover's dial; the
    /// recommended night sits a little past half.
    public var warmthAllowance: Double {
        get { (Kelvin.mired(warmest) - Self.mired.cool) / (Self.mired.warm - Self.mired.cool) }
        set { warmest = 1e6 / (Self.mired.cool + (0.0...1.0).clamp(newValue) * (Self.mired.warm - Self.mired.cool)) }
    }
    private static let mired = (cool: Kelvin.mired(Stage.kelvinRange.upperBound), warm: Kelvin.mired(Stage.kelvinRange.lowerBound))

    /// Dimmest as a slider, 0 (full brightness) … 1 (30 %, the deepest there is), linear in
    /// brightness; the recommended night is 64 %.
    public var dimmingAllowance: Double {
        get { (1 - darkest) / (1 - Stage.brightnessRange.lowerBound) }
        set { darkest = 1 - (0.0...1.0).clamp(newValue) * (1 - Stage.brightnessRange.lowerBound) }
    }

    public init() {}

    // MARK: Timing constants

    /// Sun elevations bounding the dusk ramp: full day above, full sunset tint below.
    public static let dayElevation = 3.0
    public static let nightElevation = -6.0  // end of civil twilight
    public static let windDownLead = 180, nightLead = 60  // minutes before bedtime each stage begins
    static let easeIn = 45.0, easeOut = 20.0             // evening ramps are gentle, mornings brisk
    /// After waking, ignore the sun for this long so a dark winter morning stays bright.
    static let morning = 300.0

    // MARK: Evaluation

    /// Gates the dimming stages: 0 while the sun is up, 1 once it is 3° below the horizon.
    /// Shorter than the sunset ramp so a June bedtime still gets its full night stage.
    static func sundownFactor(elevation: Double) -> Double {
        smoothstep(min(1, max(0, (Self.dayElevation - elevation) / (Self.dayElevation + 3))))
    }

    /// 0 = full day, 1 = full night.
    public static func nightFactor(elevation: Double) -> Double {
        let t = (dayElevation - elevation) / (dayElevation - nightElevation)
        return smoothstep(min(1, max(0, t)))
    }

    public struct Factors: Equatable, Sendable {
        public var sunset = 0.0, windDown = 0.0, night = 0.0
    }

    /// How far into each stage `date` is (0…1).
    public func factors(at date: Date, _ c: Coordinate, calendar: Calendar = .current) -> Factors {
        let now = minutes(date, calendar)
        let wakeMin = Double(wake.minutesOfDay), bedMin = Double(bedtime.minutesOfDay)
        var f = Factors()
        let afterMorning = Self.window(now, from: wakeMin + Self.morning, to: wakeMin)
        if afterMorning > 0 { f.sunset = afterMorning * Self.nightFactor(elevation: Sun.elevation(at: date, c)) }
        // The settable times always leave ≥ 8 h awake, so the 3 h lead fits after wake.
        let afterSundown = Self.sundownFactor(elevation: Sun.elevation(at: date, c))
        f.windDown = afterSundown * Self.window(now, from: bedMin - Double(Self.windDownLead), to: wakeMin)
        f.night = afterSundown * Self.window(now, from: bedMin - Double(Self.nightLead), to: wakeMin)
        return f
    }

    /// `roomLux`: light measured in the room, when a sensor can see it (nil otherwise).
    public func tint(at date: Date, _ c: Coordinate, roomLux: Double? = nil, calendar: Calendar = .current) -> Tint {
        let f = factors(at: date, c, calendar: calendar)
        var t = Tint.neutral
        t = .mix(t, sunset.tint, f.sunset)
        t = .mix(t, windDown.tint, f.windDown)
        t = .mix(t, night.tint, f.night)
        if let roomLux { t.brightness = 1 - (1 - t.brightness) * Self.roomFactor(lux: roomLux) }
        return limited(t)
    }

    /// A tint held to the limits.
    public func limited(_ t: Tint) -> Tint {
        Tint(kelvin: max(t.kelvin, warmest), brightness: max(t.brightness, darkest))
    }

    /// Tonight's night: what a preview of tonight shows.
    public var limitedNight: Tint { night.tint }

    /// How much of the smear floor a built-in display at this backlight level (0…1, the
    /// brightness slider) keeps: none up to 50%, all of it from 85%, smooth between. Measured on
    /// one mini-LED panel at the Night stage with no floor: no trails at 20–50 %, faint at 60 %,
    /// stronger at 80 %, heavy at 100 % (docs/science.md).
    public static func backlightFactor(_ level: Double) -> Double {
        smoothstep(min(1, max(0, (level - 0.5) / 0.35)))
    }

    /// How much of the scheduled dimming to keep for the room's light: all of it in a dim room
    /// (≤ 10 lx, the evening ceiling the 2022 consensus recommends), a third in a bright one
    /// (≥ 500 lx, office lighting), log-linear between. In a bright room the room dominates the
    /// light reaching the eye and a much darker screen mostly costs readability.
    public static func roomFactor(lux: Double) -> Double {
        let t = (log10(max(lux, 1)) - 1) / (log10(500) - 1)
        return 1 - 2.0 / 3 * min(1, max(0, t))
    }

    /// The next `count` changes after `date`, each at its nominal time (the clock time or
    /// sunset it is anchored to, not when its ease crosses halfway). Once that time has passed
    /// but the ease hasn't crossed yet (up to ~20 minutes), the takeover time instead: a change
    /// "at 22:00" said at 22:10 is wrong, and a hand setting held until then would end at once.
    /// The sun can also move a change hours from its nominal time (a dark winter morning that
    /// outlasts the hold after wake brings the sunset tint back at 09:30, and day with sunrise;
    /// a polar summer's day comes with the sun): a nominal time more than 3 h after the takeover,
    /// or one that would put the list out of order, gives way to the takeover time.
    public func upcoming(after date: Date, _ c: Coordinate, count: Int = 2, calendar: Calendar = .current)
        -> [(kind: StageKind, at: Date)]
    {
        var changes: [(kind: StageKind, at: Date)] = []  // one more than asked, to check order against
        var from = date
        while changes.count <= count, let next = nextStage(after: from, c, calendar: calendar) {
            changes.append(next)
            from = next.at
        }
        var result: [(kind: StageKind, at: Date)] = []
        for (i, next) in changes.prefix(count).enumerated() {
            let previous = result.last?.at ?? date, from = i == 0 ? date : changes[i - 1].at
            let following = i + 1 < changes.count ? changes[i + 1].at : .distantFuture
            let nominal = next.kind == .day
                ? evening(around: from, c, calendar: calendar).wake
                : evening(around: next.at, c, calendar: calendar).start(of: next.kind)
            let usable = nominal.flatMap {
                $0 > previous && $0 < following && $0.timeIntervalSince(next.at) < 3 * 3600 ? $0 : nil
            }
            result.append((next.kind, usable ?? next.at))
        }
        return result
    }

    /// When "until morning" ends: the next hand-back to day within a day and a bit (pressed by
    /// day, that is tomorrow's), else the coming wake (polar day, where nothing ever changes).
    public func nextMorning(after date: Date, _ c: Coordinate, calendar: Calendar = .current) -> Date {
        upcoming(after: date, c, count: 4, calendar: calendar)
            .first { $0.kind == .day && $0.at.timeIntervalSince(date) <= 30 * 3600 }?.at
            ?? evening(around: date, c, calendar: calendar).wake
    }

    /// How long a hand setting holds: to the next phase of the day. In the evening and night (the
    /// last boundary passed was sunset or bedtime) until morning, the first of sunrise and wake;
    /// by day (sunrise or wake passed) until evening, the first of sunset and bedtime. A tweak
    /// lasts the evening, or the day, it was made in (the next stage was often under an hour).
    public func manualHold(after date: Date, _ c: Coordinate, calendar: Calendar = .current) -> Date {
        var anchors: [(at: Date, evening: Bool)] = []
        let window = DateInterval(start: date.addingTimeInterval(-24 * 3600), end: date.addingTimeInterval(36 * 3600))
        for rising in [false, true] {
            var from = window.start
            while from < window.end, let t = Sun.crossing(-0.833, rising: rising, in: DateInterval(start: from, end: window.end), c) {
                anchors.append((t, !rising))
                from = t.addingTimeInterval(3600)
            }
        }
        var night = evening(around: window.start, c, calendar: calendar)
        while night.bedtime < window.end {
            anchors += [(night.bedtime, true), (night.wake, false)]
            night = evening(around: night.wake.addingTimeInterval(60), c, calendar: calendar)
        }
        anchors.sort { $0.at < $1.at }
        let inEvening = anchors.last { $0.at <= date }?.evening ?? false
        return anchors.first { $0.at > date.addingTimeInterval(60) && $0.evening != inEvening }?.at
            ?? evening(around: date, c, calendar: calendar).wake
    }

    /// The stage that dominates at `date`.
    public func stage(at date: Date, _ c: Coordinate, calendar: Calendar = .current) -> StageKind {
        let f = factors(at: date, c, calendar: calendar)
        if f.night >= 0.5 { return .night }
        if f.windDown >= 0.5 { return .windDown }
        if f.sunset >= 0.5 { return .sunset }
        return .day
    }

    /// The first stage after `date` that differs from the current one, and roughly when it
    /// takes over (10-minute resolution). In summer wind-down can arrive before sunset does.
    public func nextStage(after date: Date, _ c: Coordinate, calendar: Calendar = .current)
        -> (kind: StageKind, at: Date)?
    {
        let current = stage(at: date, c, calendar: calendar)
        for step in 1...(24 * 6) {
            let t = date.addingTimeInterval(Double(step) * 600)
            let kind = stage(at: t, c, calendar: calendar)
            if kind != current { return (kind, t) }
        }
        return nil
    }

    /// One evening's timeline, as real dates.
    public struct Evening: Equatable, Sendable {
        public var sunset: Date?      // nil in polar day or night
        public var windDown: Date?    // nil when the rhythm is invalid
        public var night: Date?
        public var bedtime: Date
        public var wake: Date

        /// What the Settings graph shows: from a little before the evening starts until after
        /// wake, never more than a day, so no clock hour appears twice (a polar winter's
        /// "sunset" can be at noon).
        public var span: ClosedRange<Date> {
            let first = [sunset, windDown, bedtime].compactMap { $0 }.min()!
            let start = max(first.addingTimeInterval(-75 * 60), wake.addingTimeInterval(-(23 * 3600 + 15 * 60)))
            return start...wake.addingTimeInterval(45 * 60)
        }

        /// Nominal start of a stage (the time the user set, or sunset); day starts at wake.
        public func start(of kind: StageKind) -> Date? {
            switch kind {
            case .day: wake
            case .sunset: sunset
            case .windDown: windDown
            case .night: night
            }
        }
    }

    /// The evening that `date` belongs to: the night ending at the next wake time. After waking
    /// that's tonight; at 03:00 it's the night still under way. Dates are built on the calendar,
    /// not by counting minutes, so a daylight-saving night still shows the wall-clock times set.
    public func evening(around date: Date, _ c: Coordinate, calendar: Calendar = .current) -> Evening {
        let wakeDate = calendar.nextDate(after: date, matching: DateComponents(hour: wake.hour, minute: wake.minute),
                                         matchingPolicy: .nextTime)!
        /// The last time `t` falls before wake (`allowSame`: or exactly at it).
        func before(_ t: ClockTime, allowSame: Bool = false) -> Date {
            let sameDay = calendar.date(bySettingHour: t.hour, minute: t.minute, second: 0, of: wakeDate)!
            if sameDay < wakeDate || (allowSame && sameDay == wakeDate) { return sameDay }
            return calendar.date(byAdding: .day, value: -1, to: sameDay)!
        }
        let bed = before(bedtime, allowSame: true)
        var e = Evening(bedtime: bed, wake: wakeDate)
        // The evening's sunset: the first one from 15 h before bedtime until wake. Not "the sunset
        // of that calendar day": in an Icelandic June the sun sets after midnight, and that day's
        // only sunset is the previous night's, at 00:03.
        let sunset = Sun.crossing(-0.833, rising: false, in: DateInterval(start: bed.addingTimeInterval(-15 * 3600), end: wakeDate), c)
        e.sunset = sunset
        // Dimming waits for the sun to go down, so in summer it starts at sunset.
        let notBeforeSunset = { (d: Date) in sunset.map { max(d, $0) } ?? d }
        e.windDown = notBeforeSunset(before(ClockTime(minutesOfDay: bedtime.minutesOfDay - Self.windDownLead)))
        e.night = notBeforeSunset(before(ClockTime(minutesOfDay: bedtime.minutesOfDay - Self.nightLead)))
        return e
    }

    /// How far into the evening, 0 (day) … 1 (night), continuous through every ease. The
    /// menu-bar glyph fills with it.
    public func depth(at date: Date, _ c: Coordinate, calendar: Calendar = .current) -> Double {
        let f = factors(at: date, c, calendar: calendar)
        return max(f.sunset / 3, 2 * f.windDown / 3, f.night)
    }

    // MARK: Helpers

    /// Minutes past midnight on the wall clock. The hour repeated when the clocks go back stands
    /// still at the moment they went back: the stages are by wall clock, and a night under way
    /// would otherwise go back an hour and ease in a second time.
    private func minutes(_ date: Date, _ calendar: Calendar) -> Double {
        var date = date
        let zone = calendar.timeZone, earlier = date.addingTimeInterval(-7200)
        let back = zone.secondsFromGMT(for: earlier) - zone.secondsFromGMT(for: date)
        if back > 0, let change = zone.nextDaylightSavingTimeTransition(after: earlier),
           change <= date, date < change.addingTimeInterval(Double(back)) {
            date = change.addingTimeInterval(-1)
        }
        let p = calendar.dateComponents([.hour, .minute, .second], from: date)
        return Double(p.hour! * 60 + p.minute!) + Double(p.second!) / 60
    }

    /// 1 inside [from, to) on the 24 h circle, eased in after `from` and out before `to`.
    static func window(_ now: Double, from: Double, to: Double) -> Double {
        let start = (from.truncatingRemainder(dividingBy: 1440) + 1440).truncatingRemainder(dividingBy: 1440)
        let length = (to - start + 1440).truncatingRemainder(dividingBy: 1440)
        let into = (now - start + 1440).truncatingRemainder(dividingBy: 1440)
        guard length > 0, into < length else { return 0 }
        let rampIn = min(easeIn, length / 2), rampOut = min(easeOut, length / 2)
        return smoothstep(min(1, into / rampIn, (length - into) / rampOut))
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // The limits, bedtime and wake are settings; the stages are fixed, and anything an older
        // build saved for them is deliberately ignored so it can't linger invisibly.
        let d = Schedule()
        warmest = Self.warmestRange.clamp(try c.decodeIfPresent(Double.self, forKey: .warmest) ?? d.warmest)
        darkest = Self.darkestRange.clamp(try c.decodeIfPresent(Double.self, forKey: .darkest) ?? d.darkest)
        bedtime = (try c.decodeIfPresent(ClockTime.self, forKey: .bedtime) ?? d.bedtime).held(to: Self.bedtimes)
        wake = (try c.decodeIfPresent(ClockTime.self, forKey: .wake) ?? d.wake).held(to: Self.wakes)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(warmest, forKey: .warmest)
        try c.encode(darkest, forKey: .darkest)
        try c.encode(bedtime, forKey: .bedtime)
        try c.encode(wake, forKey: .wake)
    }

    private enum CodingKeys: String, CodingKey { case warmest, darkest, bedtime, wake }
}

extension ClosedRange where Bound == Double {
    /// Clamps into the range; NaN becomes the lower bound.
    public func clamp(_ v: Double) -> Double { v.isNaN ? lowerBound : Swift.min(upperBound, Swift.max(lowerBound, v)) }
}

func smoothstep(_ t: Double) -> Double { t * t * (3 - 2 * t) }
