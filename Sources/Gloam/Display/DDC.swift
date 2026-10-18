// Brightness of third-party monitors over DDC/CI (VCP code 0x10), on Apple Silicon.
//
// macOS exposes no API for it; this speaks the MCCS protocol over the display's I2C bus
// (IOAVService, private IOKit), loaded with dlsym so a future
// macOS that drops a symbol simply yields no monitor. A monitor is used only if it answers a
// brightness read, which proves the channel, and if its IOKit service maps to exactly one
// CoreGraphics display (by EDID vendor, model and serial, `EDIDIdentity`, or because both sides
// have a single external); anything doubtful is left to signal dimming. The EDID is not on the
// I2C service but on its port's framebuffer, and its "EDID UUID" is not CoreGraphics' display
// UUID. Known gaps, from those projects: most hubs and docks, DisplayLink, TVs, EIZO, the
// built-in HDMI of M1 Macs, and picture modes that lock brightness. Verified on one monitor (a
// 0–50 scale): read, dim and restore on quit all work, and its EDID pairs it.
//
// All I2C traffic runs on one serial queue per monitor, never the main thread: each command
// sleeps 10–60 ms. Writes are coalesced to the latest value and spaced 60 ms apart: MCCS asks
// for ~50 ms between commands and some monitors drop a flood. Many store every brightness write
// in EEPROM, so the controller sends one step per write (`BacklightDim.nextStep`): the count is
// the levels crossed, however fast they go.

import CoreGraphics
import Foundation
import GloamCore
import IOKit

nonisolated final class DDC: @unchecked Sendable {
    private typealias Create = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<AnyObject>?
    private typealias Write = @convention(c) (AnyObject, UInt32, UInt32, UnsafeRawPointer, UInt32) -> IOReturn
    private typealias Read = @convention(c) (AnyObject, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    nonisolated(unsafe) private static let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let iokit, let s = dlsym(iokit, name) else { return nil }
        return unsafeBitCast(s, to: type)
    }
    private static let create = symbol("IOAVServiceCreateWithService", as: Create.self)
    private static let write = symbol("IOAVServiceWriteI2C", as: Write.self)
    private static let read = symbol("IOAVServiceReadI2C", as: Read.self)
    private static let chip: UInt32 = 0x37, host: UInt8 = 0x51, destination: UInt8 = 0x6E
    private static let brightness: UInt8 = 0x10

    private let service: AnyObject
    /// The monitor's own scale, usually 100.
    let maximum: Int
    /// The brightness found when the monitor answered, as a fraction of `maximum`.
    let initial: Double

    private let queue = DispatchQueue(label: "Gloam.DDC")
    private let lock = NSLock()
    /// The latest value asked for and not yet sent, with who to tell how it went (guarded by `lock`).
    private var pending: (fraction: Double, done: @MainActor @Sendable (Bool) -> Void)?
    /// The last write didn't get through, even retried (guarded by `lock`).
    private var lastFailed = false
    private var lastWrite = Date.distantPast  // queue only

    private init?(service: AnyObject) {
        self.service = service
        guard let (current, max) = Self.readBrightness(service), max > 0 else { return nil }
        maximum = max
        initial = Double(current) / Double(max)
    }

    /// One step of the monitor's own scale, as a fraction.
    var step: Double { 1 / Double(maximum) }
    var isFailing: Bool { lock.withLock { lastFailed } }

    /// Sends `fraction` soon, replacing any value still waiting: the latest one always arrives.
    /// `done` hears on the main actor whether it got through; a replaced value is never sent
    /// and never reported, so the caller records only what reached the monitor.
    func set(fraction: Double, done: @escaping @MainActor @Sendable (Bool) -> Void = { _ in }) {
        guard fraction.isFinite else { return }
        let idle = lock.withLock {
            defer { pending = (fraction, done) }
            return pending == nil
        }
        if idle { queue.async { self.drain() } }
    }

    /// Waits until everything asked for has been sent; whether the last write got through.
    func flush() -> Bool {
        queue.sync {}
        return !isFailing
    }

    /// Reads the brightness on the I2C queue (after any pending write) and hands the fraction
    /// to the main actor; nil when the monitor didn't answer.
    func read(_ done: @escaping @MainActor @Sendable (Double?) -> Void) {
        queue.async {
            let fraction = Self.readBrightness(self.service).map { Double($0.current) / Double(self.maximum) }
            DispatchQueue.main.async { done(fraction) }
        }
    }

    private func drain() {
        let wait = 0.06 - Date().timeIntervalSince(lastWrite)
        if wait > 0 { usleep(UInt32(wait * 1_000_000)) }
        guard let (fraction, done) = lock.withLock({ defer { pending = nil }; return pending }) else { return }
        // Written twice (some monitors drop the first), but heard
        // of after the first that got through: the signal evens out the step as soon as it can.
        var ok = false
        for attempt in 0..<6 {  // up to three tries of two writes
            if attempt > 0 && attempt.isMultiple(of: 2) {
                if ok { break }
                usleep(50_000)
            }
            usleep(10_000)
            guard send(fraction) else { continue }
            if !ok {
                lock.withLock { lastFailed = false }
                DispatchQueue.main.async { done(true) }
            }
            ok = true
        }
        lastWrite = Date()
        if !ok {
            lock.withLock { lastFailed = true }
            DispatchQueue.main.async { done(false) }
        }
    }

    private func send(_ fraction: Double) -> Bool {
        guard let write = Self.write else { return false }
        let value = UInt16(max(0, min(Double(maximum), (fraction * Double(maximum)).rounded())))
        var data: [UInt8] = [0x84, 0x03, Self.brightness, UInt8(value >> 8), UInt8(value & 0xFF), 0]
        data[5] = Self.checksum(data.dropLast(), from: Self.destination ^ Self.host)
        return write(service, Self.chip, UInt32(Self.host), data, UInt32(data.count)) == kIOReturnSuccess
    }

    /// MCCS's checksum: every byte XORed onto the addresses it travels between.
    private static func checksum(_ bytes: ArraySlice<UInt8>, from seed: UInt8) -> UInt8 { bytes.reduce(seed, ^) }

    private static func readBrightness(_ service: AnyObject) -> (current: Int, max: Int)? {
        guard let write, let read else { return nil }
        var request: [UInt8] = [0x82, 0x01, brightness, 0]
        request[3] = checksum(request.dropLast(), from: destination ^ host)
        for _ in 0..<3 {  // reads are optional in MCCS and flaky through some links
            usleep(10_000)
            guard write(service, chip, UInt32(host), request, UInt32(request.count)) == kIOReturnSuccess else { continue }
            usleep(50_000)
            var reply = [UInt8](repeating: 0, count: 11)
            guard read(service, chip, UInt32(host), &reply, 11) == kIOReturnSuccess else { continue }
            // Reply: [source, length|0x80, 0x02, result, opcode, type, maxHi, maxLo, curHi, curLo, checksum].
            guard reply[2] == 0x02, reply[3] == 0, reply[4] == brightness,
                  reply[10] == checksum(reply.dropLast(), from: 0x50) else { continue }
            return (Int(reply[8]) << 8 | Int(reply[9]), Int(reply[6]) << 8 | Int(reply[7]))
        }
        return nil
    }

    /// The monitors among `wanted` (display, UUID) that answer, and the UUIDs of those that
    /// don't. Blocking (I2C reads): call off the main thread. `externals` is how many external
    /// displays are physically attached, for the fallback below.
    static func probe(_ wanted: [(id: CGDirectDisplayID, uuid: String)], externals: Int)
        -> (found: [CGDirectDisplayID: DDC], silent: Set<String>) {
        guard let create, read != nil, write != nil, !wanted.isEmpty else { return ([:], []) }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS
        else { return ([:], []) }
        defer { IOObjectRelease(iterator) }
        let edids = framebufferEDIDs()
        var candidates: [(edid: EDIDIdentity?, service: AnyObject)] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String, location == "External",
                  let service = create(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }
            // The proxy hangs off an endpoint named for its port ("dispext0:dcpav-service-epic:0");
            // the EDID sits on that port's framebuffer, in another branch of the registry.
            let port = parentName(entry)?.split(separator: ":").first.map(String.init)
            candidates.append((port.flatMap { edids[$0] }.flatMap(EDIDIdentity.init(edidUUID:)), service))
        }
        var found: [CGDirectDisplayID: DDC] = [:], silent: Set<String> = []
        for display in wanted {
            let byEDID = candidates.filter {
                $0.edid?.matches(vendor: CGDisplayVendorNumber(display.id), model: CGDisplayModelNumber(display.id),
                                 serial: CGDisplaySerialNumber(display.id)) == true
            }
            // Without an EDID match, pair only one physical external with one I2C service: an
            // AirPlay or Sidecar screen next to a monitor could otherwise take its channel. Twins
            // without serials match several: left to signal dimming.
            let alone = wanted.count == 1 && externals == 1 && candidates.count == 1 && isPhysical(display.id)
            let matches = byEDID.isEmpty && alone ? candidates : byEDID
            guard matches.count == 1 else { continue }
            if let ddc = DDC(service: matches[0].service) { found[display.id] = ddc } else { silent.insert(display.uuid) }
        }
        return (found, silent)
    }

    /// Each external framebuffer's "EDID UUID", by port name ("dispext0").
    private static func framebufferEDIDs() -> [String: String] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMobileFramebufferShim"), &iterator) == KERN_SUCCESS
        else { return [:] }
        defer { IOObjectRelease(iterator) }
        var edids: [String: String] = [:]
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let port = parentName(entry),
                  let uuid = IORegistryEntryCreateCFProperty(entry, "EDID UUID" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String else { continue }
            edids[port] = uuid
        }
        return edids
    }

    private static func parentName(_ entry: io_registry_entry_t) -> String? {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(parent) }
        var name = [CChar](repeating: 0, count: 128)  // io_name_t
        guard IORegistryEntryGetName(parent, &name) == KERN_SUCCESS else { return nil }
        return String(cString: name)
    }

    /// A display with a cable behind it, as far as CoreGraphics tells: virtual screens (AirPlay,
    /// screen-sharing and dummy displays) usually report no vendor. Not verified for Sidecar.
    static func isPhysical(_ id: CGDirectDisplayID) -> Bool {
        let vendor = CGDisplayVendorNumber(id)
        return vendor != 0 && vendor != 0xFFFF_FFFF
    }
}
