// The gloam:// URL scheme, parsed here so it can be tested: gloam://toggle · gloam://on ·
// gloam://off · gloam://open (shows the panel; a second launch uses it to hand over).

import Foundation

public enum Command: Equatable, Sendable {
    case toggle, on, off, open

    public init?(url: URL) {
        guard url.scheme == "gloam" else { return nil }
        switch url.host()?.lowercased() {
        case "toggle": self = .toggle
        case "on": self = .on
        case "off": self = .off
        case "open": self = .open
        default: return nil
        }
    }
}
