// Which way to tint the screen on this Mac.
//
// Gamma tables (CGSetDisplayTransferByTable) are the real thing: blue is actually removed
// and blacks stay black. But on some 2026 hardware running macOS 26+, the call reports
// success, reads back correctly, and changes nothing on screen (FB22273730/FB22273782). Readback cannot detect that, so those chips get the
// overlay by default. The user can always override in Settings if their Mac disagrees.

import Foundation

public enum Engine: String, Codable, Sendable {
    case auto, gamma, overlay
}

public enum EnginePolicy {
    static let gammaBrokenChips: Set<String> = ["Apple M5 Pro", "Apple M5 Max", "Apple A18 Pro"]

    public static func resolve(_ choice: Engine, chip: String, osMajor: Int) -> Engine {
        guard choice == .auto else { return choice }
        let broken = osMajor >= 26 && gammaBrokenChips.contains(chip.trimmingCharacters(in: .whitespaces))
        return broken ? .overlay : .gamma
    }
}
