// Shared look: colours derived from colour temperature, so the UI is a live preview of what
// the app is doing to the screen; names for stages and for light; formatting.

import GloamCore
import SwiftUI

extension Color {
    init(_ rgb: RGB) {
        self.init(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    init(rgb hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
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
        case .day: "Daylight"
        case .sunset: "Sunset"
        case .windDown: "Wind-down"
        case .night: "Night"
        }
    }
}

enum Light {
    /// A name for a colour temperature, so the dial speaks in feelings before numbers.
    static func name(_ kelvin: Double) -> String {
        switch kelvin {
        case 5500...: "Daylight"
        case 4200..<5500: "Soft white"
        case 3200..<4200: "Halogen"
        case 2400..<3200: "Lamplight"
        case 1700..<2400: "Candlelight"
        default: "Ember"
        }
    }
}

enum Format {
    static func kelvin(_ k: Double) -> String { "\(Int((k / 50).rounded() * 50))K" }
    static func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
    static func time(_ d: Date?) -> String { d?.formatted(date: .omitted, time: .shortened) ?? "—" }

}
