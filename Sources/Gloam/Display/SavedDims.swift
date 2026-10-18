// The dimmed backlights, saved by display UUID as they change. A backlight Gloam dimmed outlives
// the process (a gamma table doesn't), so after a crash, a kill or a failed restore the next
// launch must not take that level for the user's own: `DisplayController.follow` picks the saved
// baseline back up when the panel still shows exactly what was written.

import Foundation
import GloamCore

struct SavedDims {
    private(set) var dims: [String: BacklightDim] = [:]
    /// When each entry last changed: one older than a day is a display that went away dimmed,
    /// and must not hand its old baseline to whatever reconnects at that level weeks later.
    private var at: [String: Date] = [:]
    /// Changed since last written to UserDefaults.
    private var dirty = false
    private static let key = "dimmedBacklights"
    private struct Entry: Codable { var dim: BacklightDim; var at: Date }

    subscript(uuid: String) -> BacklightDim? { dims[uuid] }

    /// Records a display's state, nil when it isn't dimming. Returns nil when nothing changed,
    /// else whether dimming started or ended (worth writing at once; steps in between can wait).
    mutating func set(_ dim: BacklightDim?, for uuid: String) -> Bool? {
        guard dims[uuid] != dim else { return nil }
        let startedOrEnded = (dims[uuid] == nil) != (dim == nil)
        dims[uuid] = dim
        at[uuid] = dim == nil ? nil : Date()
        dirty = true
        return startedOrEnded
    }

    mutating func write() {
        guard dirty else { return }  // every fade ends with a write, most with nothing new
        dirty = false
        let entries = dims.reduce(into: [String: Entry]()) { $0[$1.key] = Entry(dim: $1.value, at: at[$1.key] ?? Date()) }
        UserDefaults.standard.set(try? JSONEncoder().encode(entries), forKey: Self.key)
    }

    /// Entries from the last day that make sense (a hand-edited or corrupt one could otherwise
    /// make the morning write 0).
    static func load() -> SavedDims {
        let entries = UserDefaults.standard.data(forKey: key)
            .flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
        let fresh = entries.filter { _, e in
            Date().timeIntervalSince(e.at) < 86_400 && e.dim.baseline.isFinite && (0...100).contains(e.dim.baseline)
                && e.dim.written.map { $0.isFinite && (0...1).contains($0) } ?? false
        }
        var saved = SavedDims()
        saved.dims = fresh.mapValues(\.dim)
        saved.at = fresh.mapValues(\.at)
        return saved
    }
}
