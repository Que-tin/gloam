// Checks that the private API Gloam relies on is still there on this macOS: the DisplayServices
// calls (`Backlight`), CoreBrightness's client with the exact argument types `BrightnessEvents`
// calls it with, the report keys in the framework's strings, and the colour layer (SkyLight's
// accessibility matrix, MediaAccessibility's system filter and its change notification). Run as
// `swift scripts/check-private-api.swift` (CI runs it on every macOS it can: a removal or a
// changed signature shows there before users find their screens dimmed by signal).
//
// Introspection only: nothing is instantiated (the client connects to corebrightnessd, which a
// VM without a display may not answer) and no display is touched. Whether the reports really
// come, and what they say, needs real hardware: the runtime contract stays a manual check.

import Foundation
import MachO
import ObjectiveC

var failed = false
func check(_ ok: Bool, _ what: String) {
    print(ok ? "ok  " : "FAIL", what)
    if !ok { failed = true }
}

let displayServices = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
check(displayServices != nil, "DisplayServices loads")
for symbol in ["DisplayServicesGetLinearBrightness", "DisplayServicesSetLinearBrightness", "DisplayServicesGetBrightness",
               "DisplayServicesSetBrightness", "DisplayServicesCanChangeBrightness"] {
    check(displayServices.flatMap { dlsym($0, symbol) } != nil, symbol)
}

let coreBrightness = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
check(coreBrightness != nil, "CoreBrightness loads")
let client: AnyClass? = NSClassFromString("BrightnessSystemClient")
check(client != nil, "BrightnessSystemClient")
// The encodings `BrightnessEvents` requires before it calls (its `encodings`: keep the two alike).
for (selector, types) in ["registerDisplayNotificationCallbackBlock:": "v24@0:8@?16",
                          "registerNotificationForKeys:andDisplay:": "v32@0:8@16Q24",
                          "copyPropertyForKey:": "@24@0:8@16", "copyPropertyForKey:andDisplay:": "@32@0:8@16Q24"] {
    let found = client.flatMap { class_getInstanceMethod($0, NSSelectorFromString(selector)) }
        .flatMap { method_getTypeEncoding($0) }.map { String(cString: $0) }
    check(found == types, "\(selector) \(found ?? "missing")")
}

/// A loaded framework's own C strings.
func strings(of framework: String) -> Data {
    let image = (0..<_dyld_image_count()).first { String(cString: _dyld_get_image_name($0)).hasSuffix("/" + framework) }
    var strings = Data()
    if let image, let header = _dyld_get_image_header(image) {
        header.withMemoryRebound(to: mach_header_64.self, capacity: 1) {
            var size: UInt = 0
            if let bytes = getsectiondata($0, "__TEXT", "__cstring", &size) { strings = Data(bytes: bytes, count: Int(size)) }
        }
    }
    return strings
}
/// A whole string, the section's first too (nothing before it to match a 0 against).
func contains(_ strings: Data, _ key: String) -> Bool { (Data([0]) + strings).range(of: Data([0]) + Data(key.utf8) + Data([0])) != nil }

// The report keys.
let reportStrings = strings(of: "CoreBrightness")
for key in ["DisplayServicesUserBrightness", "DisplayServicesBrightness", "CBDisplayBrightnessState",
            "CBReasonForBrightnessChange", "AggregatedLux", "BrightnessControlCapabilities", "MaxNits"] {
    check(contains(reportStrings, key), "key \(key)")
}

// The colour layer: SkyLight's per-display matrix and its keys, the system Color Filter it must
// carry, and the notification of a change to it. C symbols: present, their types unchecked.
let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
check(skyLight != nil, "SkyLight loads")
for symbol in ["SLSSetAccessibilityAdjustments", "kSLSAccessibilityAdjustmentMatrix", "kSLSAccessibilityTargetDisplay"] {
    check(skyLight.flatMap { dlsym($0, symbol) } != nil, symbol)
}
let accessibility = dlopen("/System/Library/Frameworks/MediaAccessibility.framework/MediaAccessibility", RTLD_NOW)
check(accessibility != nil, "MediaAccessibility loads")
for symbol in ["MADisplayFilterCopySystemFilter", "MADisplayFilterGetMatrix", "MADisplayFilterPrefGetCategoryEnabled"] {
    check(accessibility.flatMap { dlsym($0, symbol) } != nil, symbol)
}
// The name Gloam registers for, as MediaAccessibility exports it.
let changed = accessibility.flatMap { dlsym($0, "kMADisplayFilterSettingsChangedNotification") }
    .map { $0.assumingMemoryBound(to: CFString.self).pointee as String }
check(changed == "com.apple.mediaaccessibility.displayFilterSettingsChanged", "notification \(changed ?? "missing")")

print(ProcessInfo.processInfo.operatingSystemVersionString)
exit(failed ? 1 : 0)
