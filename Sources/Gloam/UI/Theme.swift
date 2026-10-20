// Shared look: colours derived from colour temperature, so the UI is a live preview of what
// the app is doing to the screen; names for stages and for light; formatting.

import GloamCore
import SwiftUI

extension Color {
    init(_ rgb: RGB) {
        self.init(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    init(rgb hex: UInt32) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }

    /// The tint a white page takes at this temperature.
    static func kelvin(_ k: Double) -> Color { Color(Kelvin.swatch(k)) }

    /// The swatch mixed toward white, for a lamp's hot core without the hue drift that
    /// scaling channels past 1 causes (1900K would turn yellow-green).
    static func kelvin(_ k: Double, whiten t: Double) -> Color {
        let c = Kelvin.swatch(k)
        let f = { (v: Double) in v + (1 - v) * t }
        return Color(.sRGB, red: f(c.red), green: f(c.green), blue: f(c.blue))
    }

    /// The swatch scaled toward black (<1) or white-hot (>1), for depth inside the orb.
    static func kelvin(_ k: Double, scale: Double) -> Color {
        let c = Kelvin.swatch(k)
        let f = { (v: Double) in min(1, v * scale) }
        return Color(.sRGB, red: f(c.red), green: f(c.green), blue: f(c.blue))
    }
}

extension StageKind {
    var title: String {
        switch self {
        case .day: String(localized: "Day", comment: "stage (\"Daylight\" is a light colour on the dial)")
        case .sunset: String(localized: "Sunset", comment: "stage")
        case .windDown: String(localized: "Wind-down", comment: "stage")
        case .night: String(localized: "Night", comment: "stage")
        }
    }
}

enum Light {
    /// A name for a colour temperature, so the dial speaks in feelings before numbers.
    static func name(_ kelvin: Double) -> String {
        // Named by the value shown beside it (100 K steps), so "Lamplight · 2400 K" never reads
        // "Candlelight · 2400 K" at a band's edge.
        switch (kelvin / 100).rounded() * 100 {
        case 5500...: String(localized: "Daylight", comment: "light colour")
        case 4200..<5500: String(localized: "Cool white", comment: "light colour (\"soft white\" bulbs are ~2700 K in US shops)")
        case 3200..<4200: String(localized: "Halogen", comment: "light colour")
        case 2400..<3200: String(localized: "Lamplight", comment: "light colour")
        case 1700..<2400: String(localized: "Candlelight", comment: "light colour")
        default: String(localized: "Ember", comment: "light colour")
        }
    }

    /// Warmth as a position on a fixed scale, 0 (daylight) … 1 (ember), even in mired, where
    /// equal steps are equal visible steps. The graph and the popover's dial both use it; each
    /// screen shows as much of it as its smear limit allows.
    static func warmth(_ kelvin: Double) -> Double {
        let (cool, warm) = (Kelvin.mired(Stage.kelvinRange.upperBound), Kelvin.mired(Stage.kelvinRange.lowerBound))
        return min(1, max(0, (Kelvin.mired(kelvin) - cool) / (warm - cool)))
    }

    static func kelvin(warmth w: Double) -> Double {
        let (cool, warm) = (Kelvin.mired(Stage.kelvinRange.upperBound), Kelvin.mired(Stage.kelvinRange.lowerBound))
        return 1e6 / (cool + (warm - cool) * min(1, max(0, w)))
    }

    /// Dimming as a position, 0 (full brightness) … 1 (the deepest there is), on the schedule's
    /// scale: the graph's and the ladder's alike. Each screen takes it the same share of the way to
    /// its own darkest (`DisplayController.adjusted`), so the scale never moves when the user's
    /// brightness changes (a key press moves the ladder by the press alone).
    static func dimming(_ brightness: Double) -> Double {
        let darkest = Stage.brightnessRange.lowerBound
        return min(1, max(0, (1 - brightness) / (1 - darkest)))
    }

    static func brightness(dimming d: Double) -> Double {
        1 - min(1, max(0, d)) * (1 - Stage.brightnessRange.lowerBound)
    }
}

/// Numbers in the user's own format ("54%" here, "54 %" in a German region).
enum Format {
    static func kelvin(_ k: Double) -> String {
        // To the nearest 100 K, as bulb labels give it (EU 2019/2020); finer reads as false precision.
        "\(((k / 100).rounded() * 100).formatted(.number.grouping(.never)))\u{00A0}K"  // never split
    }
    static func percent(_ v: Double) -> String { v.formatted(.percent.precision(.fractionLength(0))) }
    static func time(_ d: Date?) -> String { d?.formatted(date: .omitted, time: .shortened) ?? "—" }
    /// A clock time (bedtime, wake) in the user's 12/24-hour style.
    static func time(_ t: ClockTime) -> String {
        // On a fixed day without a clock change: on a spring-forward day 02:30 doesn't exist and
        // would read as 03:30.
        let calendar = Calendar.current
        let day = calendar.date(from: DateComponents(year: 2001, month: 1, day: 1))!
        return time(calendar.date(bySettingHour: t.hour, minute: t.minute, second: 0, of: day))
    }
}

extension Schedule.Evening {
    /// Tonight's steps, as one whole sentence (Welcome and Settings). Whole sentences rather than
    /// joined fragments, so a translation can reorder them. The order is fixed: wind-down and
    /// night never start before sunset, and come and go together.
    var plan: String {
        switch (sunset, windDown, night) {
        case let (.some, windDown?, night?):
            String(localized: "Warmer from sunset, dimmer from \(Format.time(windDown)), deepest around \(Format.time(night)).")
        case let (nil, windDown?, night?):
            String(localized: "Dimmer from \(Format.time(windDown)), deepest around \(Format.time(night)).")
        case (.some, _, _):
            String(localized: "Warmer from sunset.")
        default:
            ""
        }
    }
}
