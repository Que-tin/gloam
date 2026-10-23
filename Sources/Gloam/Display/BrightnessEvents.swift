// What macOS reports about the backlights it controls, as it happens, and who moved them: the
// user (brightness keys, Control Center's or System Settings' slider) or macOS itself
// (auto-brightness). Read through CoreBrightness's `BrightnessSystemClient` (private: no public API
// tells a change, let alone its source), loaded at run time, so a macOS without it yields false
// (the controller then reads a screen without auto-brightness on the tick, else dims by signal).
//
// What macOS sends, measured on an Apple silicon MacBook (macOS 27):
// - the user: `DisplayServicesUserBrightness` and `DisplayServicesBrightness` per step, then, about
//   1.3 s after the last, a commit and `CBDisplayBrightnessState` with reason "User Slider";
// - auto-brightness: `DisplayServicesBrightness` per step, then the state with reason "Ambient";
// - Gloam's own writes (`Backlight.set(light:)`): one `DisplayServicesBrightness` each, no state.
//   They teach auto-brightness nothing: only the user's commits do. (`DisplayServicesSetBrightness`,
//   the slider's call, is reported as the user's.)
// Without this, a reading could only be compared with what Gloam wrote: auto-brightness's ramps
// became the user's shifts (the evening's dimming lost, "Manual" all evening), and a press was
// read every 5 s, waited out while it animated and read again before every write.
//
// The block takes (key, display, value): three objects crashed (the display is a plain integer).
// One client, one kind of block: a property block registered too took every report from it.

import CoreGraphics
import Foundation
import GloamCore
import ObjectiveC

@MainActor
enum BrightnessEvents {
    enum Event: Equatable {
        /// A step of a move under way: the user's, or not (auto-brightness, or Gloam's own write).
        case step(byUser: Bool)
        /// A move is done: the user's, auto-brightness's, or nil for another reason (a thermal cap,
        /// battery dimming: nothing to adopt).
        case settled(BacklightReports.Source?)
    }

    private static let client: NSObject? = {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW) != nil,
              let type = NSClassFromString("BrightnessSystemClient") as? NSObject.Type else { return nil }
        return type.init()
    }()
    private typealias Register = @convention(c) (AnyObject, Selector, AnyObject) -> Void
    private typealias Watch = @convention(c) (AnyObject, Selector, AnyObject, UInt64) -> Void
    private typealias CopyFor = @convention(c) (AnyObject, Selector, AnyObject, UInt64) -> Unmanaged<AnyObject>?
    private static let keys = ["DisplayServicesUserBrightness", "DisplayServicesBrightness", "CBDisplayBrightnessState"]
    private static var handler: ((CGDirectDisplayID, Event, Date) -> Void)?
    private static var watched: Set<CGDirectDisplayID> = []
    /// The method's implementation, only while its argument types are still the ones measured: a
    /// macOS that changed them gets no call (the screens are dimmed by signal) rather than a crash.
    private static let encodings = [
        "registerDisplayNotificationCallbackBlock:": "v24@0:8@?16", "registerNotificationForKeys:andDisplay:": "v32@0:8@16Q24",
        "copyPropertyForKey:andDisplay:": "@32@0:8@16Q24",
    ]
    private static func method<T>(_ name: String, as type: T.Type) -> (Selector, T)? {
        let sel = NSSelectorFromString(name)
        guard let client, let m = class_getInstanceMethod(object_getClass(client), sel),
              let types = method_getTypeEncoding(m), String(cString: types) == encodings[name] else { return nil }
        return (sel, unsafeBitCast(method_getImplementation(m), to: type))
    }

    /// Reports for `id` from now on, to `handle`, with when macOS sent each (one handler for all
    /// displays: the last set wins). Registered again if it was: reports that went quiet may come
    /// back. False where this macOS doesn't offer them.
    static func watch(_ id: CGDirectDisplayID, _ handle: @escaping (CGDirectDisplayID, Event, Date) -> Void) -> Bool {
        handler = handle
        guard let client, let (watchSel, watch) = method("registerNotificationForKeys:andDisplay:", as: Watch.self) else { return false }
        if watched.isEmpty {
            guard let (sel, register) = method("registerDisplayNotificationCallbackBlock:", as: Register.self) else { return false }
            // Called on CoreBrightness's own queue.
            let block: @convention(block) @Sendable (AnyObject?, UInt64, AnyObject?) -> Void = { key, display, value in
                guard let event = event(key as? String, value) else { return }
                let at = Date()
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { handler?(CGDirectDisplayID(truncatingIfNeeded: display), event, at) }
                }
            }
            register(client, sel, block as AnyObject)
        }
        watch(client, watchSel, keys as NSArray, UInt64(id))
        watched.insert(id)
        return true
    }

    /// Registers every watched display again: other apps found the reports gone quiet after a
    /// sleep on some Macs until registered anew.
    static func rewatch() {
        guard let client, let (sel, watch) = method("registerNotificationForKeys:andDisplay:", as: Watch.self) else { return }
        for id in watched { watch(client, sel, keys as NSArray, UInt64(id)) }
    }

    /// Whether macOS brightens and dims `id` for the room itself, or nil where it doesn't say.
    static func autoBrightness(_ id: CGDirectDisplayID) -> Bool? {
        guard let client, let (sel, copy) = method("copyPropertyForKey:andDisplay:", as: CopyFor.self) else { return nil }
        return (copy(client, sel, "CBAutoBrightnessEnabled" as NSString, UInt64(id))?.takeRetainedValue() as? NSNumber)?.boolValue
    }

    private nonisolated static func event(_ key: String?, _ value: AnyObject?) -> Event? {
        switch key {
        case "DisplayServicesUserBrightness": .step(byUser: true)
        case "DisplayServicesBrightness": .step(byUser: false)
        // Exact reasons: CoreBrightness also has "Ambient User Offset", "Dynamic Slider", "Auto Dim",
        // "Thermal Brightness"..., none of them a move to adopt as made.
        case "CBDisplayBrightnessState":
            ((value as? NSDictionary)?["CBReasonForBrightnessChange"] as? String).map {
                .settled(["User Slider", "User change"].contains($0) ? .user : $0 == "Ambient" ? .macOS : nil)
            }
        default: nil
        }
    }
}
