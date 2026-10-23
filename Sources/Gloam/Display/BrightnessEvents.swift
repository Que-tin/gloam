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
// The room light the sensor measures for auto-brightness (`AggregatedLux`, for `RoomLight`) is
// watched on the built-in display and never read while watched: any client's read sends every
// watcher a report, so reading on a report looped (~10,000 a second, unchanged; Gloam and
// corebrightnessd at 60 % and 120 % CPU). Reports come in bursts while the sensor works, often
// unchanged: each is only stored where it arrives, for the clock's tick to take. A flood all the
// same (another app looping) stops the watch, and the light is read on the tick instead.
//
// The block takes (key, display, value): three objects crashed (the display is a plain integer).
// One client, one kind of block: a property block registered too took every report from it.

import CoreGraphics
import Foundation
import GloamCore
import ObjectiveC
import os

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
    private typealias Copy = @convention(c) (AnyObject, Selector, AnyObject) -> Unmanaged<AnyObject>?
    private typealias CopyFor = @convention(c) (AnyObject, Selector, AnyObject, UInt64) -> Unmanaged<AnyObject>?
    private static let keys = ["DisplayServicesUserBrightness", "DisplayServicesBrightness", "CBDisplayBrightnessState"]
    private static var handler: ((CGDirectDisplayID, Event, Date) -> Void)?
    private static var watched: Set<CGDirectDisplayID> = []
    /// The display the room light is watched on (the built-in's sensor).
    private static var luxDisplay: CGDirectDisplayID?
    /// Lux as last reported (or read before watching; -1: none), and this second's count of reports.
    private nonisolated static let luxGate = OSAllocatedUnfairLock(initialState: (last: -1.0, second: 0.0, count: 0))
    /// More lux reports than this in a second is a loop, not a sensor (it bursts ~2 a second).
    private nonisolated static let luxFlood = 50

    /// The method's implementation, only while its argument types are still the ones measured: a
    /// macOS that changed them gets no call (the screens are dimmed by signal) rather than a crash.
    private static let encodings = [
        "registerDisplayNotificationCallbackBlock:": "v24@0:8@?16", "registerNotificationForKeys:andDisplay:": "v32@0:8@16Q24",
        "copyPropertyForKey:": "@24@0:8@16", "copyPropertyForKey:andDisplay:": "@32@0:8@16Q24",
        "unregisterNotificationForKeys:andDisplay:": "v32@0:8@16Q24",
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
                if key as? String == "AggregatedLux" { return luxReported(value) }
                guard let event = event(key as? String, value) else { return }
                let at = Date()
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { handler?(CGDirectDisplayID(truncatingIfNeeded: display), event, at) }
                }
            }
            register(client, sel, block as AnyObject)
        }
        // The room light, on the built-in: read once now, then only as reported.
        if luxDisplay == nil, !watched.contains(id), CGDisplayIsBuiltin(id) != 0, let lux = readLux() {
            luxGate.withLock { $0.last = lux }
            luxDisplay = id
        }
        watch(client, watchSel, keys(for: id) as NSArray, UInt64(id))
        watched.insert(id)
        return true
    }

    private static func keys(for id: CGDirectDisplayID) -> [String] { id == luxDisplay ? keys + ["AggregatedLux"] : keys }

    /// Registers every watched display again: other apps found the reports gone quiet after a
    /// sleep on some Macs until registered anew. The room is read once: it may have changed while
    /// no report could come (a single read only sends the one report it causes).
    static func rewatch() {
        guard let client, let (sel, watch) = method("registerNotificationForKeys:andDisplay:", as: Watch.self) else { return }
        for id in watched { watch(client, sel, keys(for: id) as NSArray, UInt64(id)) }
        if luxDisplay != nil, let lux = readLux() { luxGate.withLock { $0.last = lux } }
    }

    /// The room light the sensor measures now (lux), or nil where macOS has none (no sensor, no
    /// reports on this macOS): as last reported where watched, else read.
    static var roomLux: Double? {
        guard luxDisplay != nil else { return readLux() }
        let lux = luxGate.withLock { $0.last }
        return lux >= 0 ? lux : nil
    }

    /// Whether macOS brightens and dims `id` for the room itself, or nil where it doesn't say.
    static func autoBrightness(_ id: CGDirectDisplayID) -> Bool? {
        guard let client, let (sel, copy) = method("copyPropertyForKey:andDisplay:", as: CopyFor.self) else { return nil }
        return (copy(client, sel, "CBAutoBrightnessEnabled" as NSString, UInt64(id))?.takeRetainedValue() as? NSNumber)?.boolValue
    }

    /// Never on a lux report while watched: the read itself sends one (a single read, on wake, is fine).
    private static func readLux() -> Double? {
        guard let client, let (sel, copy) = method("copyPropertyForKey:", as: Copy.self),
              let lux = (copy(client, sel, "AggregatedLux" as NSString)?.takeRetainedValue() as? NSNumber)?.doubleValue,
              lux.isFinite, lux >= 0 else { return nil }
        return lux
    }

    /// A lux report, on CoreBrightness's queue: kept for `roomLux`; a flood stops the watch.
    private nonisolated static func luxReported(_ value: AnyObject?) {
        guard let lux = (value as? NSNumber)?.doubleValue, lux.isFinite, lux >= 0 else { return }
        let now = Date().timeIntervalSinceReferenceDate
        let flooded = luxGate.withLock { gate in
            if now - gate.second >= 1 { gate.second = now; gate.count = 0 }
            gate.count += 1
            gate.last = lux
            return gate.count == luxFlood
        }
        if flooded { DispatchQueue.main.async { MainActor.assumeIsolated { stopLux() } } }
    }

    /// The lux watch stops for good, and the light is read on the tick. The display's other keys
    /// are registered again, in case unregistering one took them all.
    private static func stopLux() {
        guard let id = luxDisplay, let client,
              let (sel, unwatch) = method("unregisterNotificationForKeys:andDisplay:", as: Watch.self) else { return }
        unwatch(client, sel, ["AggregatedLux"] as NSArray, UInt64(id))
        luxDisplay = nil
        if let (sel, watch) = method("registerNotificationForKeys:andDisplay:", as: Watch.self) {
            watch(client, sel, keys as NSArray, UInt64(id))
        }
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
