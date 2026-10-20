// Which way to tint the screen on this Mac.
//
// Gamma tables (CGSetDisplayTransferByTable) are the real thing: blue is actually removed
// and blacks stay black. But on M5 Pro and M5 Max Macs running macOS 26 or later, the call
// reports success, reads back correctly, and changes nothing on the built-in panel (and on
// some external displays); the MacBook Neo (A18 Pro) is reported to fail on external displays
// only (FB22273730/FB22273782; Apple DTS reproduced it on an M5 Max, the base M5 is fine; still
// open on macOS 27). Readback cannot detect that, so those chips get the overlay on every
// display: a per-display rule would mean running both engines at once, for a Neo's built-in
// screen. No macOS check: these chips only ship with macOS 26 or later. The user can always
// override in Settings if their Mac disagrees.

import Foundation

public enum Engine: String, Codable, Sendable {
    case auto, gamma, overlay
}

public enum EnginePolicy {
    static let gammaBrokenChips: Set<String> = ["Apple M5 Pro", "Apple M5 Max", "Apple A18 Pro"]

    public static func resolve(_ choice: Engine, chip: String) -> Engine {
        guard choice == .auto else { return choice }
        let broken = gammaBrokenChips.contains(chip.trimmingCharacters(in: .whitespaces))
        return broken ? .overlay : .gamma
    }
}
