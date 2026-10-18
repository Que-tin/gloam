// Blanks what Finder's saved layout (Resources/dmg-layout, shipped in every disk image) records
// about the Mac it was made on: disk IDs, and the startup disk's size and creation date and the
// folder numbers of /private and /private/tmp, which the scratch images' locations bring in.
// Overwritten in place with zeros of the same length, so the file's structure stays intact;
// Finder finds the background by name and path anyway (those details differ on every Mac).
// Usage: swift scripts/scrub-dmg-layout.swift Resources/dmg-layout

import Foundation

let path = CommandLine.arguments[1]
var data = try Data(contentsOf: URL(fileURLWithPath: path))

func blank(_ needle: Data) {
    guard !needle.isEmpty else { return }
    var from = data.startIndex
    while let range = data.range(of: needle, in: from..<data.endIndex) {
        data.replaceSubrange(range, with: Data(count: needle.count))
        from = range.upperBound
    }
}
func le<T: FixedWidthInteger>(_ v: T) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

let disk = try URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeCreationDateKey])
if let size = disk.volumeTotalCapacity { blank(le(Int64(size))) }
if let created = disk.volumeCreationDate {
    blank(withUnsafeBytes(of: created.timeIntervalSinceReferenceDate.bitPattern.bigEndian) { Data($0) })
}
for folder in ["/private", "/private/tmp"] {
    if let id = (try? FileManager.default.attributesOfItem(atPath: folder))?[.systemFileNumber] as? Int {
        blank(le(Int64(id)))
    }
}
// Disk IDs, as text (8-4-4-4-12 hex digits): the nil UUID instead, same length, still valid.
let hex = Set("0123456789ABCDEF".utf8), dash = UInt8(ascii: "-"), shape = [8, 4, 4, 4, 12]
var bytes = [UInt8](data), at = 0
while at + 36 <= bytes.count {
    var i = at, ok = true
    for (n, run) in shape.enumerated() where ok {
        ok = bytes[i..<i + run].allSatisfy(hex.contains)
        i += run
        if n < 4 { ok = ok && bytes[i] == dash; i += 1 }
    }
    if ok {
        for k in at..<at + 36 where bytes[k] != dash { bytes[k] = UInt8(ascii: "0") }
        at += 36
    } else {
        at += 1
    }
}
data = Data(bytes)
try data.write(to: URL(fileURLWithPath: path))
