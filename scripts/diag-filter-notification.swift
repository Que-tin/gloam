// Throwaway: where macOS keeps the Color Filter change notification's name.
import Foundation
import MachO

for path in ["/System/Library/Frameworks/MediaAccessibility.framework/MediaAccessibility",
             "/System/Library/PrivateFrameworks/UniversalAccess.framework/UniversalAccess",
             "/System/Library/PrivateFrameworks/AccessibilitySupport.framework/AccessibilitySupport",
             "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
             "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"] {
    print("load \(path.split(separator: "/").last!): \(dlopen(path, RTLD_NOW) != nil)")
}

func cstrings(_ header: UnsafePointer<mach_header_64>, _ seg: String, _ sect: String) -> [String] {
    var size: UInt = 0
    guard let bytes = getsectiondata(header, seg, sect, &size) else { return [] }
    return Data(bytes: bytes, count: Int(size)).split(separator: 0).compactMap { String(data: Data($0), encoding: .utf8) }
}

let needles = ["isplayFilter", "displayfilter", "mediaaccessibility"]
for i in 0..<_dyld_image_count() {
    let name = String(cString: _dyld_get_image_name(i))
    guard let raw = _dyld_get_image_header(i) else { continue }
    raw.withMemoryRebound(to: mach_header_64.self, capacity: 1) { header in
        for (seg, sect) in [("__TEXT", "__cstring"), ("__TEXT", "__oslogstring"), ("__TEXT", "__const"), ("__DATA_CONST", "__const")] {
            for s in Set(cstrings(header, seg, sect)) where needles.contains(where: { s.lowercased().contains($0.lowercased()) }) && s.count < 200 {
                print("\(name.split(separator: "/").last!) \(seg),\(sect): \(s)")
            }
        }
    }
}
for symbol in ["kMADisplayFilterSettingsChangedNotification", "kMADisplayFilterSettingsChanged", "MADisplayFilterSettingsChangedNotification"] {
    let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), symbol)  // RTLD_DEFAULT
    let value = p.map { $0.assumingMemoryBound(to: CFString.self).pointee as String }
    print("symbol \(symbol): \(value ?? "absent")")
}
print(ProcessInfo.processInfo.operatingSystemVersionString)
