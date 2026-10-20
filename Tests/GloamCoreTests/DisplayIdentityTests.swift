// Display identity: which follows a reused id invalidates, and pairing a monitor's I2C service
// with its display by EDID (a wrong pair dims the wrong monitor).

import Foundation
import Testing
@testable import GloamCore

@Suite struct DisplayIdentityTests {
    @Test func staleFollowsAfterAReplug() {
        let followed: [UInt32: String] = [1: "A", 2: "B", 3: "C", 4: "D"]
        let current: [UInt32: String] = [
            1: "A",  // unchanged: kept
            5: "B",  // same screen under a new id: stale
            3: "E",  // the id now belongs to another screen: stale
            // D went away: kept, for when it returns
        ]
        #expect(staleFollows(followed: followed, current: current) == [2, 3])
        #expect(staleFollows(followed: followed, current: followed).isEmpty)
    }

    /// Identical monitors without a serial share a UUID: neither moved, though each id is "another" twin's.
    @Test func twinsAreNotStale() {
        let twins: [UInt32: String] = [1: "A", 100: "TWIN", 200: "TWIN"]
        #expect(staleFollows(followed: twins, current: twins).isEmpty)
    }

    // A monitor like the one probed: CoreGraphics reports vendor 0x4C2D, model 0x1234 and a serial
    // the EDID's own field (0) doesn't carry.
    @Test func parsesTheObservedEDIDUUID() throws {
        let id = try #require(EDIDIdentity(edidUUID: "4C2D3412-0000-0000-0A1E-0103803C2278"))
        #expect(id == EDIDIdentity(vendor: 0x4C2D, model: 0x1234, serial: 0))
        #expect(id.matches(vendor: 0x4C2D, model: 0x1234, serial: 0x4142_4344))
        #expect(!id.matches(vendor: 0x4C2D, model: 0x3412, serial: 0))  // not byte-swapped back
        #expect(!id.matches(vendor: 0x10AC, model: 0x1234, serial: 0))
    }

    @Test func serialsTellTwinsApart() throws {
        let id = try #require(EDIDIdentity(edidUUID: "10ACA0D0-4C34-4430-1E1F-0104B53C2278"))
        #expect(id == EDIDIdentity(vendor: 0x10AC, model: 0xD0A0, serial: 0x3044_344C))
        #expect(id.matches(vendor: 0x10AC, model: 0xD0A0, serial: 0x3044_344C))
        #expect(!id.matches(vendor: 0x10AC, model: 0xD0A0, serial: 0x3044_344D))
        #expect(id.matches(vendor: 0x10AC, model: 0xD0A0, serial: 0))
    }

    @Test func rejectsMalformed() {
        #expect(EDIDIdentity(edidUUID: "") == nil)
        #expect(EDIDIdentity(edidUUID: "4C2D3412-0000") == nil)
        #expect(EDIDIdentity(edidUUID: "XX2D6779-0000-0000-0A1E-0103803C2278") == nil)
    }
}
