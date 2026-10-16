// An estimate of how much body-clock (melanopic, CIE S 026) light the screen gives off at a
// tint, relative to untouched white. This is the number that matters for evening light,
// so the UI shows it instead of only a colour temperature.
//
// Per-channel weights are modelled, not measured: typical LCD/OLED primary spectra weighted
// by the CIE S 026 melanopic action spectrum and balanced to D65 (see docs/science.md).
// Green carries over half the signal, which is why blue-only filters do so little.

import Foundation

public enum Melanopic {
    /// Share of white's melanopic output carried by the red, green and blue channels.
    static let weights = RGB(0.005, 0.57, 0.425)
    static let displayGamma = 2.2

    /// 1 = untouched white; 0.1 = a tenth of the melanopic light.
    public static func relative(_ tint: Tint) -> Double {
        let gain = Kelvin.displayGain(tint)  // display-encoded, brightness included
        let lin = { (v: Double) in pow(max(0, v), displayGamma) }
        return weights.red * lin(gain.red) + weights.green * lin(gain.green) + weights.blue * lin(gain.blue)
    }
}
