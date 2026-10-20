// The dimmed backlights, saved by display UUID as they change. A backlight Gloam dimmed outlives
// the process (a gamma table doesn't), so after a crash, a kill or a failed restore the next
// launch must not take that level for the user's own: `DisplayController.follow` picks the saved
// baseline back up when the panel still shows a light on tonight's saved curve (a crash mid-fade
// leaves it between saves), `BacklightDim.resumes`.

import Foundation
import GloamCore

struct SavedDims {
    /// Each dimming display's state, with when it last changed. Kept for a month: a display that
    /// went away dimmed (a monitor unplugged at night, a weekend, a restart) still holds Gloam's
    /// level, and dropped after a day its night became the day's level. `resumes` only matches a
    /// panel still on that night's curve; older than that, it is the user's own.
    private var entries: [String: Entry] = [:]
    private static let kept: TimeInterval = 30 * 86_400
    /// Changed since last written to UserDefaults.
    private var dirty = false
    private static let key = "dimmedBacklights"
    private struct Entry: Codable { var dim: BacklightDim; var at: Date }

    subscript(uuid: String) -> BacklightDim? {
        entries[uuid].flatMap { Date().timeIntervalSince($0.at) < Self.kept ? $0.dim : nil }
    }

    var isEmpty: Bool { entries.isEmpty }

    /// Saved within the last few hours: a panel anywhere on that night's curve is still Gloam's
    /// (a crash mid-fade). Older, only exactly what was written is: days on, the user's own level
    /// (auto-brightness, the keys) could fall on the curve, and the old baseline came back.
    func isRecent(_ uuid: String) -> Bool {
        entries[uuid].map { Date().timeIntervalSince($0.at) < 6 * 3600 } ?? false
    }

    /// Records a display's state, nil when it isn't dimming. Returns nil when nothing changed,
    /// else whether dimming started or ended (worth writing at once; steps in between can wait).
    mutating func set(_ dim: BacklightDim?, for uuid: String) -> Bool? {
        guard self[uuid] != dim else { return nil }
        let startedOrEnded = (self[uuid] == nil) != (dim == nil)
        entries[uuid] = dim.map { Entry(dim: $0, at: Date()) }
        dirty = true
        return startedOrEnded
    }

    mutating func write() {
        guard dirty else { return }  // every fade ends with a write, most with nothing new
        dirty = false
        UserDefaults.standard.set(try? JSONEncoder().encode(entries), forKey: Self.key)
    }

    /// Entries from the last month that make sense (a hand-edited or corrupt one could otherwise
    /// make the morning write 0).
    static func load() -> SavedDims {
        let entries = UserDefaults.standard.data(forKey: key)
            .flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
        let fresh = entries.filter { _, e in
            Date().timeIntervalSince(e.at) < kept && e.dim.baseline.isFinite && (0...1).contains(e.dim.baseline)
                && e.dim.written.map { $0.isFinite && (0...1).contains($0) } ?? false
        }
        var saved = SavedDims()
        saved.entries = fresh
        return saved
    }
}
