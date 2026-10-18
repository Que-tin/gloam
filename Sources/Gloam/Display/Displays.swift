// What we know about each connected screen, from public APIs only (no permissions).
// Settings are keyed by the ColorSync UUID, which survives reconnects and port changes
// for monitors that report a serial number.

import AppKit
import CoreGraphics

struct DisplayInfo: Identifiable, Equatable {
    let id: CGDirectDisplayID
    let uuid: String
    let name: String
    let isBuiltin: Bool
    /// An external display in HDR mode. SDR is then composited inside an HDR signal and gamma
    /// tints can look washed out. Built-in XDR panels report EDR headroom even in SDR, so the
    /// signal is only trusted for externals, which report 1.0 with HDR off.
    let hdrActive: Bool
}

enum Displays {
    static func current() -> [DisplayInfo] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.displayID else { return nil }
            return DisplayInfo(
                id: id,
                uuid: uuid(id),
                name: screen.localizedName,
                isBuiltin: CGDisplayIsBuiltin(id) != 0,
                hdrActive: CGDisplayIsBuiltin(id) == 0
                    && screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1)
        }
    }

    static func uuid(_ id: CGDirectDisplayID) -> String {
        guard let ref = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return "display-\(id)" }
        return CFUUIDCreateString(nil, ref) as String
    }
}
