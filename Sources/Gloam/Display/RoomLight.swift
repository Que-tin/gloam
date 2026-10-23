// The room's light, as one optional input to the schedule (`Schedule.roomFactor`): a bright room
// eases the dimming.
//
// It is the light the MacBook's sensor measures for auto-brightness, as macOS's brightness
// service reports it (`BrightnessEvents.roomLux`), in fractions of a lux: read from the sensor's
// HID service instead, a dark room was a whole 0. Watched, so the tick takes the last report and
// asks nothing (`BrightnessEvents` on why it is never read meanwhile). No reading is always safe:
// Gloam then dims as scheduled (no sensor, no reports on this macOS). With the lid closed the
// sensor is covered and reports 0 lux, which would read as a dark room, so a closed lid also
// yields nil.

import Foundation
import IOKit

@MainActor
enum RoomLight {
    /// This Mac has a sensor macOS reports on (Settings offers the room's light only then).
    /// Asked once: Settings asks on every redraw, and unwatched each ask is a read.
    static let isAvailable = BrightnessEvents.roomLux != nil

    /// Lux now, or nil when the sensor can't see the room.
    static func read() -> Double? {
        lidClosed ? nil : BrightnessEvents.roomLux
    }

    /// The power manager, looked up once (it lives as long as the system); asked every read.
    private static let powerRoot = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))

    private static var lidClosed: Bool {
        guard powerRoot != 0 else { return false }
        let state = IORegistryEntryCreateCFProperty(powerRoot, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return (state?.takeRetainedValue() as? Bool) ?? false
    }
}
