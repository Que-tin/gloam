// Colour temperature → per-channel display gains.
//
// Why not the Tanner Helland fit most screen tinters use: it is a curve fit to 8-bit sRGB
// samples and drifts noticeably below ~2000K. We instead take the Planckian locus in CIE 1960
// (Krystek 1985, valid 1000–15000K), convert to the display's linear RGB, white-balance
// against 6500K so "daylight" is an exact identity, then encode with the display gamma.
// In sRGB the result tracks Ingo Thies' measured blackbody table (2013) within a few percent.
//
// The conversion is per display (`LinearRGB`): below ~2000K the warm white lies outside sRGB,
// and clamping it there removes blue entirely. Sent to a P3 panel (every recent Mac) those
// sRGB numbers show a deeper, purer red than the Kelvin asked for, and white text turns into
// soft red strokes. In the panel's own space the same white keeps some blue and more green.

import Foundation

/// What the screen should look like right now: a white point and a brightness multiplier.
public struct Tint: Equatable, Sendable, Codable {
    public var kelvin: Double
    /// 0…1 multiplier on the output signal; 1 is untouched.
    public var brightness: Double

    public init(kelvin: Double, brightness: Double = 1) {
        self.kelvin = Kelvin.range.clamp(kelvin)
        self.brightness = (0.0...1.0).clamp(brightness)
    }

    public static let neutral = Tint(kelvin: Kelvin.daylight, brightness: 1)

    public var isNeutral: Bool { abs(kelvin - Kelvin.daylight) < 1 && brightness > 0.999 }

    /// Interpolates in mireds (1e6/K), where equal steps look equally large; a straight Kelvin
    /// lerp lingers near daylight and then rushes through the warm end.
    public static func mix(_ a: Tint, _ b: Tint, _ t: Double) -> Tint {
        if t <= 0 { return a }
        if t >= 1 { return b }
        let mired = Kelvin.mired(a.kelvin) + (Kelvin.mired(b.kelvin) - Kelvin.mired(a.kelvin)) * t
        return Tint(kelvin: 1e6 / mired, brightness: a.brightness + (b.brightness - a.brightness) * t)
    }
}

public struct RGB: Equatable, Sendable {
    public var red: Double, green: Double, blue: Double
    public init(_ red: Double, _ green: Double, _ blue: Double) {
        (self.red, self.green, self.blue) = (red, green, blue)
    }
    public static let white = RGB(1, 1, 1)
}

/// CIE XYZ, Y = 1.
public struct XYZ: Sendable {
    public var x, y, z: Double
    public init(x: Double, y: Double, z: Double) { (self.x, self.y, self.z) = (x, y, z) }
}

/// Turns XYZ into a display's linear RGB.
public typealias LinearRGB = @Sendable (XYZ) -> RGB

public enum Kelvin {
    public static let daylight = 6500.0
    public static let range = 1000.0...6500.0

    public static func mired(_ kelvin: Double) -> Double { 1e6 / kelvin }

    /// Linear-light channel gains, brightest channel = 1. 6500K → (1, 1, 1).
    public static func linearGain(_ kelvin: Double, in space: LinearRGB = sRGB) -> RGB {
        let k = min(range.upperBound, max(range.lowerBound, kelvin))
        let target = space(xyz(k)), reference = space(xyz(daylight))
        let r = max(0, target.red / reference.red)
        let g = max(0, target.green / reference.green)
        let b = max(0, target.blue / reference.blue)
        let peak = max(r, g, b)
        return RGB(r / peak, g / peak, b / peak)
    }

    /// Gains in display-encoded space (what a gamma table multiplies), scaled by brightness.
    public static func displayGain(_ tint: Tint, in space: LinearRGB = sRGB) -> RGB {
        let lin = linearGain(tint.kelvin, in: space)
        let encode = { (v: Double) in pow(v, 1 / 2.2) * min(1, max(0, tint.brightness)) }
        return RGB(encode(lin.red), encode(lin.green), encode(lin.blue))
    }

    /// The colour a white surface takes on at this temperature; used to paint the UI.
    public static func swatch(_ kelvin: Double) -> RGB { displayGain(Tint(kelvin: kelvin)) }

    /// Krystek's rational approximation of the Planckian locus in CIE 1960 (u, v), as XYZ.
    public static func xyz(_ t: Double) -> XYZ {
        let u = (0.860117757 + 1.54118254e-4 * t + 1.28641212e-7 * t * t)
            / (1 + 8.42420235e-4 * t + 7.08145163e-7 * t * t)
        let v = (0.317398726 + 4.22806245e-5 * t + 4.20481691e-8 * t * t)
            / (1 - 2.89741816e-5 * t + 1.61456053e-7 * t * t)
        let d = 2 * u - 8 * v + 4
        let x = 3 * u / d, y = 2 * v / d
        return XYZ(x: x / y, y: 1, z: (1 - x - y) / y)
    }

    /// The XYZ → linear RGB conversion for a display whose primaries (each at full output)
    /// measure `red`, `green` and `blue`: the inverse of the matrix they form. Built from the
    /// primaries because asking ColorSync to convert XYZ straight to the display clips at 1,
    /// and the red of every warm white lies above 1 at Y = 1: the tint came out far too weak.
    public static func linearRGB(red: XYZ, green: XYZ, blue: XYZ) -> LinearRGB? {
        let (a, b, c) = (red.x, green.x, blue.x)
        let (d, e, f) = (red.y, green.y, blue.y)
        let (g, h, i) = (red.z, green.z, blue.z)
        let det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
        guard abs(det) > 1e-9, det.isFinite else { return nil }
        let m = [(e * i - f * h), -(b * i - c * h), (b * f - c * e),
                 -(d * i - f * g), (a * i - c * g), -(a * f - c * d),
                 (d * h - e * g), -(a * h - b * g), (a * e - b * d)].map { $0 / det }
        return { v in
            RGB(m[0] * v.x + m[1] * v.y + m[2] * v.z,
                m[3] * v.x + m[4] * v.y + m[5] * v.z,
                m[6] * v.x + m[7] * v.y + m[8] * v.z)
        }
    }

    /// Linear sRGB (IEC 61966-2-1): the UI's colours, the overlay, and any display whose
    /// colour space can't be read.
    public static let sRGB: LinearRGB = { c in
        RGB(3.2406 * c.x - 1.5372 * c.y - 0.4986 * c.z,
            -0.9689 * c.x + 1.8758 * c.y + 0.0415 * c.z,
            0.0557 * c.x - 0.2040 * c.y + 1.0570 * c.z)
    }
}
