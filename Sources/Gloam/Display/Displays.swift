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
    let diagonalInches: Double
    let pixels: CGSize
    let refreshRate: Double
    let wideGamut: Bool
    /// An external display in HDR mode. SDR is then composited inside an HDR signal and gamma
    /// tints can look washed out. Built-in XDR panels report EDR headroom even in SDR, so the
    /// signal is only trusted for externals, which report 1.0 with HDR off.
    let hdrActive: Bool

    var summary: String {
        var parts = [isBuiltin ? "Built-in" : "External"]
        if diagonalInches > 1 { parts.append("\(Int(diagonalInches.rounded()))″") }
        parts.append("\(Int(pixels.width))×\(Int(pixels.height))")
        if refreshRate > 0 { parts.append("\(Int(refreshRate.rounded())) Hz") }
        if wideGamut { parts.append("Wide colour") }
        if hdrActive { parts.append("HDR") }
        return parts.joined(separator: " · ")
    }
}

enum Displays {
    static func current() -> [DisplayInfo] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.displayID else { return nil }
            let mm = CGDisplayScreenSize(id)
            let mode = CGDisplayCopyDisplayMode(id)
            return DisplayInfo(
                id: id,
                uuid: uuid(id),
                name: screen.localizedName,
                isBuiltin: CGDisplayIsBuiltin(id) != 0,
                diagonalInches: (mm.width * mm.width + mm.height * mm.height).squareRoot() / 25.4,
                pixels: CGSize(width: mode?.pixelWidth ?? 0, height: mode?.pixelHeight ?? 0),
                refreshRate: mode?.refreshRate ?? 0,
                wideGamut: screen.canRepresent(.p3),
                hdrActive: CGDisplayIsBuiltin(id) == 0
                    && screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1)
        }
    }

    static func uuid(_ id: CGDirectDisplayID) -> String {
        guard let ref = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return "display-\(id)" }
        return CFUUIDCreateString(nil, ref) as String
    }
}
