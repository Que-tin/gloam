// The room's light, from the MacBook's ambient light sensor, as one optional input to the
// schedule (`Schedule.roomFactor`): a bright room eases the dimming.
//
// macOS has no public API for the sensor. This reads it through IOKit's private HID event
// system (the path Chromium and Hammerspoon use), loaded with dlsym so a future macOS that
// removes a symbol simply yields no reading. No reading is always safe: Gloam then dims as
// scheduled. With the lid closed the sensor is covered and reports 0 lux, which would read as
// a dark room, so a closed lid also yields nil. Apple Silicon only; Intel Macs and desktops
// (no sensor) get nil.

import Foundation
import IOKit

final class RoomLight {
    private typealias CreateClient = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatching = @convention(c) (AnyObject, CFDictionary) -> Void
    private typealias CopyServices = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyEvent = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias GetFloat = @convention(c) (AnyObject, Int32) -> Double

    private static let ambientLightEvent: Int64 = 12  // kIOHIDEventTypeAmbientLightSensor
    /// Kept for the reader's lifetime: the service stops answering once its client is released.
    private let client: AnyObject?
    private let service: AnyObject?
    private let copyEvent: CopyEvent?
    private let getFloat: GetFloat?

    var isAvailable: Bool { service != nil }

    init() {
        guard let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let create = dlsym(iokit, "IOHIDEventSystemClientCreate"),
              let match = dlsym(iokit, "IOHIDEventSystemClientSetMatching"),
              let copy = dlsym(iokit, "IOHIDEventSystemClientCopyServices"),
              let event = dlsym(iokit, "IOHIDServiceClientCopyEvent"),
              let float = dlsym(iokit, "IOHIDEventGetFloatValue"),
              let client = unsafeBitCast(create, to: CreateClient.self)(kCFAllocatorDefault)?.takeRetainedValue()
        else {
            (client, service, copyEvent, getFloat) = (nil, nil, nil, nil)
            return
        }
        self.client = client
        // Usage page 0xFF00, usage 4: Apple's ambient light sensor.
        unsafeBitCast(match, to: SetMatching.self)(client, ["PrimaryUsagePage": 0xFF00, "PrimaryUsage": 4] as CFDictionary)
        let services = unsafeBitCast(copy, to: CopyServices.self)(client)?.takeRetainedValue() as? [AnyObject]
        service = services?.first
        copyEvent = unsafeBitCast(event, to: CopyEvent.self)
        getFloat = unsafeBitCast(float, to: GetFloat.self)
    }

    /// Lux now, or nil when the sensor can't see the room.
    func read() -> Double? {
        guard let service, let copyEvent, let getFloat, !Self.lidClosed,
              let event = copyEvent(service, Self.ambientLightEvent, 0, 0)?.takeRetainedValue() else { return nil }
        let lux = getFloat(event, Int32(Self.ambientLightEvent << 16))
        return lux.isFinite && lux >= 0 ? lux : nil
    }

    /// The power manager, looked up once (it lives as long as the system); asked every read.
    private static let powerRoot = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))

    private static var lidClosed: Bool {
        guard powerRoot != 0 else { return false }
        let state = IORegistryEntryCreateCFProperty(powerRoot, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return (state?.takeRetainedValue() as? Bool) ?? false
    }
}
