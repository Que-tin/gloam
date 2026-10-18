// Telling displays apart across replugs and across APIs that name them differently.
//
// CoreGraphics ids are reused: after a replug or wake one id can belong to another screen, and
// one screen can come back under another id. Following a backlight by an id whose screen
// changed would dim (or "restore") the wrong panel, so such follows are dropped and the display
// is followed afresh from its saved state.
//
// The IORegistry's "EDID UUID" on Apple Silicon is not the CoreGraphics display UUID: it is raw
// EDID bytes 8–23 (vendor, product code, serial, date, version…). Its first 16 hex digits are
// what CoreGraphics reports as vendor, model and serial, in EDID byte order, so a monitor's I2C
// service is paired with its display by those.

import Foundation

/// The followed displays (id → UUID) whose id no longer means the same screen: the screen is
/// back under another id, or the id now belongs to another screen. A screen that went away is
/// kept, for when it returns.
public func staleFollows<ID: Hashable>(followed: [ID: String], current: [ID: String]) -> Set<ID> {
    var idOf: [String: ID] = [:]
    for (id, uuid) in current where idOf[uuid] == nil { idOf[uuid] = id }
    return Set(followed.compactMap { id, uuid in
        let otherScreen = current[id].map { $0 != uuid } ?? false
        let movedID = idOf[uuid].map { $0 != id } ?? false
        return otherScreen || movedID ? id : nil
    })
}

/// A monitor's identity as the IORegistry's "EDID UUID" gives it.
public struct EDIDIdentity: Equatable, Sendable {
    public var vendor: UInt32, model: UInt32, serial: UInt32

    public init(vendor: UInt32, model: UInt32, serial: UInt32) {
        self.vendor = vendor
        self.model = model
        self.serial = serial
    }

    /// Parses e.g. "4C2D3412-0000-0000-0A1E-0103803C2278": vendor 0x4C2D (big-endian in EDID),
    /// model 0x1234 and serial 0 (both little-endian).
    public init?(edidUUID: String) {
        let hex = edidUUID.filter { $0 != "-" }
        guard hex.count >= 16 else { return nil }
        var bytes: [UInt32] = []
        var i = hex.startIndex
        for _ in 0..<8 {
            let next = hex.index(i, offsetBy: 2)
            guard let b = UInt32(hex[i..<next], radix: 16) else { return nil }
            bytes.append(b)
            i = next
        }
        vendor = bytes[0] << 8 | bytes[1]
        model = bytes[3] << 8 | bytes[2]
        serial = bytes[7] << 24 | bytes[6] << 16 | bytes[5] << 8 | bytes[4]
    }

    /// Whether this is the display CoreGraphics describes. Serials count only when both sides
    /// have one: many monitors leave the EDID's at 0 and CoreGraphics may take a descriptor's.
    public func matches(vendor: UInt32, model: UInt32, serial: UInt32) -> Bool {
        vendor == self.vendor && model == self.model && (serial == 0 || self.serial == 0 || serial == self.serial)
    }
}
