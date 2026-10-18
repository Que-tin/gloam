// Keeps a built-in LCD out of the range where light text on a dark background smears.
//
// Seen on a mini-LED laptop panel at a bright backlight: with the whole signal scaled to 55%,
// white-on-black text leaves trails as it scrolls; at 80% it doesn't. A warm tint does the
// same thing to the panel as a dim one. Red stays at full drive, but green and blue carry
// about three quarters of the light, so the white the panel has to draw is a dim white either
// way: at 1900K it is down to 47% of daylight white before any dimming, under the 61% that was
// clean. What the measured threshold constrains is therefore the luminance of the tinted
// white, not the brightness setting alone (a floor on brightness, tried first, left every warm
// stage in the band that smeared).
//
// Held to the floor, dimming is given up before warmth: of all tints at a given luminance the
// warmest has the least melanopic light, so this keeps the most of what the evening is for.
// What is measured and what is still a claim: docs/science.md.

import Foundation

public enum Smear {
    /// Luminance of the tinted white relative to untouched white, in linear light (1 = unchanged),
    /// in the display's own colour space.
    public static func luminance(_ tint: Tint, in space: LinearRGB = Kelvin.sRGB) -> Double {
        let g = Kelvin.linearGain(tint.kelvin, in: space), w = Kelvin.luminanceWeights(of: space)
        return (w.red * g.red + w.green * g.green + w.blue * g.blue) * pow(tint.brightness, Kelvin.displayGamma)
    }

    /// `tint` held to at least `floor` (relative luminance of its white): the brightness is raised
    /// first, and when full brightness is still too dim the warmth is eased until it isn't.
    public static func limited(_ tint: Tint, floor: Double, in space: LinearRGB = Kelvin.sRGB) -> Tint {
        guard floor > 0 else { return tint }
        let full = luminance(Tint(kelvin: tint.kelvin), in: space)
        if full >= floor {
            return Tint(kelvin: tint.kelvin, brightness: max(tint.brightness, pow(floor / full, 1 / Kelvin.displayGamma)))
        }
        return Tint(kelvin: warmest(brightness: 1, floor: floor, in: space), brightness: 1)
    }

    /// The lowest brightness at this warmth that stays on the floor; 1 when even that is too dim.
    public static func brightnessFloor(kelvin: Double, floor: Double, in space: LinearRGB = Kelvin.sRGB) -> Double {
        let full = luminance(Tint(kelvin: kelvin), in: space)
        return full > floor ? pow(floor / full, 1 / Kelvin.displayGamma) : 1
    }

    /// The warmest temperature that stays on the floor at this brightness; daylight when none does.
    public static func warmest(brightness: Double, floor: Double, in space: LinearRGB = Kelvin.sRGB) -> Double {
        func fits(_ mired: Double) -> Bool { luminance(Tint(kelvin: 1e6 / mired, brightness: brightness), in: space) >= floor }
        var cool = Kelvin.mired(Kelvin.daylight), warm = Kelvin.mired(Kelvin.range.lowerBound)
        guard fits(cool) else { return Kelvin.daylight }
        guard !fits(warm) else { return Kelvin.range.lowerBound }
        // The white loses light steadily as it warms, so bisect in mireds (to a tenth of one).
        while warm - cool > 0.1 {
            let mid = (cool + warm) / 2
            if fits(mid) { cool = mid } else { warm = mid }
        }
        return 1e6 / cool
    }
}
