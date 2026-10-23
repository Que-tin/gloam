// How Gloam reads macOS's reports about one backlight it dims (the app's `BrightnessEvents`):
// which steps are its own writes coming back, which are a move under way (and whose), when
// writes must wait for it, which settled reports to act on, and when the reports have stopped.
//
// What macOS sends, measured: a user's move (keys, slider) is user steps, then a settled report
// marked as the user's; auto-brightness is plain steps, then a settled report; Gloam's own light
// write is one plain step and nothing else, several close together sometimes one step for all;
// its slider-level write (the release) is reported like a user's move.
// Told apart by timing alone, a press during one of Gloam's fades (a write every 16 ms) was taken
// for an echo and written over; a settled report with no move behind it (the release's, arriving
// after dimming had restarted) became a phantom press. A plain step is an echo when Gloam wrote in
// the half second before it: matched one to one, a fade's late echo found its write taken and
// became an auto-brightness ramp, its dimmed level the new day level.

import Foundation

public struct BacklightReports: Sendable {
    public enum Source: Sendable, Equatable { case user, macOS }

    /// Gloam's recent light writes, oldest first, and when the last of them was reported back.
    private var writes: [Date] = []
    private var echoedAt = Date.distantPast
    /// When Gloam last wrote the slider level (the release): its own "user" report follows.
    private var levelWrittenAt = Date.distantPast
    /// The move under way: whose, since when, its last step, and until when writes wait for it.
    public private(set) var moving: (by: Source, since: Date, last: Date, until: Date)?
    /// Whose steps came since the last settled report, and whether a plain one passed for an echo
    /// (during a fade, auto-brightness's steps do).
    private var seen: Set<Source> = []
    private var masked = false

    /// Writes wait until this long after a move's last step, or its settled report (~1.3 s after a
    /// press's last step), never longer than `longestHold` in all.
    public static let stepGap: TimeInterval = 2.5, longestHold: TimeInterval = 30
    /// How long after Gloam's slider-level write its own report counts as its echo.
    public static let echoWindow: TimeInterval = 1
    /// How long after one of Gloam's light writes a plain step counts as its echo.
    public static let lightEcho: TimeInterval = 0.5
    /// This many of Gloam's writes unreported, the first `silentFor` ago: the reports stopped.
    public static let silentWrites = 5, silentFor: TimeInterval = 5

    public init() {}

    /// Gloam wrote the backlight: its light (`level` false), or its slider level (the release).
    public mutating func wrote(at date: Date, level: Bool) {
        if level { levelWrittenAt = date } else { writes = writes.suffix(63) + [date] }
    }

    /// A step macOS reported, at the time it sent it.
    public mutating func step(byUser: Bool, at date: Date) {
        if date.timeIntervalSince(levelWrittenAt) < Self.echoWindow { return }
        // macOS reports on: whatever came before this wasn't lost.
        echoedAt = max(echoedAt, date)
        // A plain step just after a light write is its echo (one for several close together); a
        // user's never is. Only writes made before it was sent.
        if !byUser, writes.contains(where: { $0 <= date && date.timeIntervalSince($0) < Self.lightEcho }) {
            masked = true
            return
        }
        let by: Source = byUser ? .user : .macOS
        seen.insert(by)
        // The same move while its steps keep coming; past `longestHold` the hold ends, and a step
        // after that holds afresh.
        let same = moving.map { date.timeIntervalSince($0.last) < Self.stepGap } ?? false
        let since = same ? moving!.since : date
        // A press during a ramp is the user's: their settled report decides.
        let who: Source = same && moving!.by == .user ? .user : by
        moving = (who, since, date, min(since.addingTimeInterval(Self.longestHold), date.addingTimeInterval(Self.stepGap)))
    }

    /// A settled report, `by` the user ("User Slider"), macOS (auto-brightness: "Ambient") or nil
    /// (another reason: a thermal cap, battery dimming; nothing to adopt): the move to take, or nil
    /// where none of that source came (Gloam's own release, or a state with nothing behind it).
    /// Auto-brightness's also where its steps passed for echoes: the caller takes it only if the
    /// panel moved off what Gloam wrote. Auto-brightness settling under a press waits for the
    /// press's own report: taken first, the press became the day level and its report found
    /// nothing left.
    public mutating func settled(_ by: Source?) -> Source? {
        if by == .macOS, seen.contains(.user) { return nil }
        defer { seen = []; moving = nil; masked = false }
        if by == .macOS, masked { return .macOS }
        return by.flatMap { seen.contains($0) ? $0 : nil }
    }

    /// Writes wait for the move under way.
    public func holds(at date: Date) -> Bool { moving.map { date < $0.until } ?? false }

    /// The hold ran out with no settled report: the user's move to take from what the panel shows
    /// now, or nil. Auto-brightness always settles ("Ambient", measured), so plain steps that never
    /// did were Gloam's own echoes come late: taken, the dimmed level became the day level.
    public mutating func expired(at date: Date) -> Source? {
        guard let m = moving, date >= m.until else { return nil }
        moving = nil
        seen = []
        return m.by == .user ? .user : nil
    }

    /// Gloam's writes stopped being reported (a macOS update, or a display that registered but
    /// isn't reported on).
    public func broken(at date: Date) -> Bool {
        let unechoed = writes.filter { $0 > echoedAt }
        return unechoed.count >= Self.silentWrites && date.timeIntervalSince(unechoed[0]) > Self.silentFor
    }
}
