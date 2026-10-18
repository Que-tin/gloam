// The backlight of the displays macOS can dim itself: built-in panels and Apple displays, the
// ones whose brightness keys work. Read as the slider level (for the smear floor) and as
// linear light, written as linear light: Gloam dims these displays by backlight
// (`BacklightDim`), relative to the level it finds, instead of by signal.
//
// There is no public API. This uses DisplayServices' calls, loaded with dlsym: if a future
// macOS removes one, nothing is read and the display is dimmed by signal like any monitor.
// The linear scale is used for writing because the slider's curve is steep and uneven (one
// key step near the middle removes about an eighth of the light); a fraction of light is
// what the schedule means.

import CoreGraphics
import Foundation

enum Backlight {
    private typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias Can = @convention(c) (CGDirectDisplayID) -> Bool

    private static let framework = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let framework, let symbol = dlsym(framework, name) else { return nil }
        return unsafeBitCast(symbol, to: type)
    }
    private static let getLevel = symbol("DisplayServicesGetBrightness", as: Get.self)
    private static let getLight = symbol("DisplayServicesGetLinearBrightness", as: Get.self)
    private static let setLight = symbol("DisplayServicesSetLinearBrightness", as: Set.self)
    private static let setLevel = symbol("DisplayServicesSetBrightness", as: Set.self)
    private static let canChange = symbol("DisplayServicesCanChangeBrightness", as: Can.self)

    /// The brightness slider, 0…1; nil for a display macOS doesn't control.
    static func level(_ id: CGDirectDisplayID) -> Double? { read(getLevel, id) }

    /// Light as a fraction of the display's maximum, linear; nil for a display macOS doesn't control.
    static func light(_ id: CGDirectDisplayID) -> Double? { read(getLight, id) }

    /// Whether macOS can set this display's brightness at all (its keys would work).
    static func canDim(_ id: CGDirectDisplayID) -> Bool { canChange?(id) ?? false }

    @discardableResult
    static func set(light: Double, on id: CGDirectDisplayID) -> Bool {
        guard let setLight, light.isFinite else { return false }
        return setLight(id, Float(min(1, max(0, light)))) == 0
    }

    /// Restores a slider value read earlier: exact, where writing the light back lands a step low.
    @discardableResult
    static func set(level: Double, on id: CGDirectDisplayID) -> Bool {
        guard let setLevel, level.isFinite else { return false }
        return setLevel(id, Float(min(1, max(0, level)))) == 0
    }

    private static func read(_ get: Get?, _ id: CGDirectDisplayID) -> Double? {
        guard let get else { return nil }
        var value: Float = -1
        guard get(id, &value) == 0, value.isFinite, (0...1).contains(value) else { return nil }
        return Double(value)
    }
}
