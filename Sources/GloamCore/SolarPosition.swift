// Sun elevation from date and coordinates (low-precision NOAA / Astronomical Almanac formulae,
// good to ~0.5°, far finer than a schedule needs). Computed locally: no network, no location
// permission.

import Foundation

public struct Coordinate: Equatable, Sendable, Codable {
    public var latitude: Double
    public var longitude: Double
    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

public enum Sun {
    /// Elevation of the sun's centre above the horizon, in degrees.
    public static func elevation(at date: Date, _ c: Coordinate) -> Double {
        let n = date.timeIntervalSince1970 / 86400 + 2440587.5 - 2451545.0  // days since J2000
        let L = degrees(280.460 + 0.9856474 * n)
        let g = radians(357.528 + 0.9856003 * n)
        let lambda = radians(L + 1.915 * sin(g) + 0.020 * sin(2 * g))
        let epsilon = radians(23.439 - 0.0000004 * n)
        let ra = atan2(cos(epsilon) * sin(lambda), cos(lambda))
        let dec = asin(sin(epsilon) * sin(lambda))
        let gmst = 280.46061837 + 360.98564736629 * n
        let hourAngle = radians(gmst + c.longitude) - ra
        let lat = radians(c.latitude)
        return asin(sin(lat) * sin(dec) + cos(lat) * cos(dec) * cos(hourAngle)) * 180 / .pi
    }

    /// First time in `interval` the sun crosses `threshold` (rising or setting), refined to
    /// a few seconds. Nil during polar day/night.
    public static func crossing(
        _ threshold: Double, rising: Bool, in interval: DateInterval, _ c: Coordinate
    ) -> Date? {
        let step: TimeInterval = 600
        var t0 = interval.start
        var e0 = elevation(at: t0, c) - threshold
        while t0 < interval.end {
            let t1 = min(t0 + step, interval.end)
            let e1 = elevation(at: t1, c) - threshold
            if rising ? (e0 < 0 && e1 >= 0) : (e0 >= 0 && e1 < 0) {
                var (lo, hi) = (t0, t1)
                for _ in 0..<12 {
                    let mid = lo + hi.timeIntervalSince(lo) / 2
                    let above = elevation(at: mid, c) >= threshold
                    if above == rising { hi = mid } else { lo = mid }
                }
                return hi
            }
            (t0, e0) = (t1, e1)
        }
        return nil
    }

    /// Standard sunrise/sunset (−0.833°: refraction plus the solar disc) for the calendar day of `date`.
    public static func riseAndSet(on date: Date, _ c: Coordinate, calendar: Calendar = .current)
        -> (rise: Date?, set: Date?)
    {
        let day = calendar.dateInterval(of: .day, for: date)!
        return (crossing(-0.833, rising: true, in: day, c), crossing(-0.833, rising: false, in: day, c))
    }

    private static func degrees(_ v: Double) -> Double { v.truncatingRemainder(dividingBy: 360) }
    private static func radians(_ deg: Double) -> Double { deg * .pi / 180 }
}
