// The built-in display's backlight level (its brightness slider, 0…1), as one optional input:
// a backlight that is already low eases Gloam's dimming on that display
// (`Schedule.backlightFactor`), so auto-brightness in a dark room and Gloam never stack into
// a screen that is too dark.
//
// There is no public API. This uses DisplayServices' getter, loaded with dlsym: if a future
// macOS removes it, there is no reading and Gloam dims as scheduled. External displays have
// no readable backlight here and always get nil. Read-only: Gloam never moves the slider,
// which would fight auto-brightness.

import CoreGraphics
import Foundation

enum Backlight {
    private typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32

    private static let get: Get? = {
        guard let framework = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW),
              let symbol = dlsym(framework, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(symbol, to: Get.self)
    }()

    static func level(_ id: CGDirectDisplayID) -> Double? {
        guard CGDisplayIsBuiltin(id) != 0, let get else { return nil }
        var value: Float = -1
        guard get(id, &value) == 0, value.isFinite, (0...1).contains(value) else { return nil }
        return Double(value)
    }
}
