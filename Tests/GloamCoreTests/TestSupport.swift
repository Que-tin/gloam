// Places, calendars and helpers the suites share.

import Foundation
@testable import GloamCore

let berlin = Coordinate(latitude: 52.52, longitude: 13.40)
let reykjavik = Coordinate(latitude: 64.15, longitude: -21.94)
let tromso = Coordinate(latitude: 69.65, longitude: 18.96)
let sydney = Coordinate(latitude: -33.87, longitude: 151.21)

func calendar(_ zone: String) -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: zone)!
    return c
}

/// Berlin's wall clock, daylight saving included.
var berlinCalendar: Calendar { calendar("Europe/Berlin") }

/// Standard sunrise and sunset (−0.833°: refraction plus the solar disc) for the calendar day
/// of `date`, as an almanac gives them.
func riseAndSet(on date: Date, _ c: Coordinate, calendar: Calendar = .current) -> (rise: Date?, set: Date?) {
    let day = calendar.dateInterval(of: .day, for: date)!
    return (Sun.crossing(-0.833, rising: true, in: day, c), Sun.crossing(-0.833, rising: false, in: day, c))
}
