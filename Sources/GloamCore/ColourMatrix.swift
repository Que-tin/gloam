// The matrix a display's colour layer shows (the app's `ColourLayer`): Gloam's tint as linear-light
// channel gains, after the system Color Filter. Row-major, out = matrix × in, as macOS takes it.
//
// The layer works on linear light (measured: 0.5 there looked like 0.73 in a gamma table, which
// multiplies encoded values), so the gains go in as `Kelvin.linearGain` gives them and the
// brightness as the light it leaves, brightness^2.2: a signal dimmed to 30 % looks as it did
// through the gamma table. A display's matrix replaces the system filter on it (measured: grayscale
// vanished), so the filter is carried in: applied first, as it corrects what reaches the screen.

import Foundation

public enum ColourMatrix {
    public static let identity: [Float] = [1, 0, 0, 0, 1, 0, 0, 0, 1]

    /// `tint` on `space`'s light, after `filter` (the system Color Filter, `identity` when off).
    public static func shown(_ tint: Tint, in space: LinearRGB, after filter: [Float] = identity) -> [Float] {
        let gain = Kelvin.linearGain(tint.kelvin, in: space)
        let light = pow(min(1, max(0, tint.brightness)), Kelvin.displayGamma)
        let diagonal = [gain.red, gain.green, gain.blue].map { Float($0 * light) }
        return (0..<9).map { diagonal[$0 / 3] * filter[$0] }
    }

    /// Whether two matrices look the same: the room light drifts the target by hair's breadths
    /// every tick, and each write is a WindowServer call.
    public static func same(_ a: [Float], _ b: [Float]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 1.0 / 4096 }
    }
}
