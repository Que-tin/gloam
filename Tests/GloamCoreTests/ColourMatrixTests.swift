import Foundation
import Testing
@testable import GloamCore

@Suite struct ColourMatrixTests {
    // Neutral is the identity; a warm tint keeps red and takes blue first, on the diagonal only.
    @Test func aTintIsLinearGainsOnTheDiagonal() {
        #expect(ColourMatrix.same(ColourMatrix.shown(.neutral, in: Kelvin.sRGB), ColourMatrix.identity))
        let warm = ColourMatrix.shown(Tint(kelvin: 1900), in: Kelvin.sRGB)
        let gain = Kelvin.linearGain(1900)
        #expect(abs(warm[0] - Float(gain.red)) < 1e-6 && abs(warm[4] - Float(gain.green)) < 1e-6 && abs(warm[8] - Float(gain.blue)) < 1e-6)
        #expect(warm[0] > warm[4] && warm[4] > warm[8] && [1, 2, 3, 5, 6, 7].allSatisfy { warm[$0] == 0 })
    }

    // The layer scales light, so a signal at 0.5 leaves 0.5^2.2 of it: as the gamma table showed it.
    @Test func brightnessIsTheLightItLeaves() {
        let half = ColourMatrix.shown(Tint(kelvin: 6500, brightness: 0.5), in: Kelvin.sRGB)
        #expect(abs(Double(half[0]) - pow(0.5, 2.2)) < 1e-6 && half[0] == half[4] && half[4] == half[8])
    }

    // The system filter comes first: each of its rows scaled by the tint's gain for that channel.
    @Test func theSystemFilterIsCarriedIn() {
        let grey: [Float] = [0.3, 0.59, 0.11, 0.3, 0.59, 0.11, 0.3, 0.59, 0.11]
        #expect(ColourMatrix.same(ColourMatrix.shown(.neutral, in: Kelvin.sRGB, after: grey), grey))
        let warm = ColourMatrix.shown(Tint(kelvin: 3400), in: Kelvin.sRGB, after: grey)
        let gain = Kelvin.linearGain(3400)
        #expect(abs(warm[4] - 0.59 * Float(gain.green)) < 1e-6 && abs(warm[7] - 0.59 * Float(gain.blue)) < 1e-6)
    }
}
