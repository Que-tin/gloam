// Owns the active engine and moves the screen toward a target tint: eased fades for user
// actions, direct writes for the clock's small steps (writes are skipped when nothing changed).
// On each clock tick it checks whether the tint was overwritten and only then writes it again,
// because macOS quietly resets gamma tables on wake, display changes and some ColorSync events.
// Displays whose backlight macOS controls (built-in, Apple displays), and monitors that answer
// DDC/CI, are dimmed by backlight, relative to the level found there (`BacklightDim`); the rest
// by signal. A dimmed backlight outlives the process (gamma tables don't), so what each one was
// dimmed from is saved as it changes, and a launch after a crash puts it back. Each built-in
// display's slider level also eases its smear floor.

import AppKit
import GloamCore
import Observation

protocol TintEngine: AnyObject {
    /// Show each listed display at its tint; displays not listed are left neutral.
    func apply(_ tints: [CGDirectDisplayID: Tint])
    func reset()
    /// On quit; defaults to `reset`.
    func restoreAll()
    /// Screens were added, removed or rearranged: drop per-display state.
    func displaysChanged()
    /// Whether another app has rewritten what this engine put on screen.
    func isOverwritten() -> Bool
    /// The display's linear RGB, for estimates that should match what it really shows.
    func colourSpace(_ id: CGDirectDisplayID) -> LinearRGB
}

extension TintEngine {
    func isOverwritten() -> Bool { false }
    func restoreAll() { reset() }
    func colourSpace(_ id: CGDirectDisplayID) -> LinearRGB { Kelvin.sRGB }
}

@Observable
final class DisplayController {
    /// The global tint on screen this instant, mid-fade included; the UI marker follows it.
    private(set) var shown = Tint.neutral
    private(set) var displays: [DisplayInfo] = Displays.current()
    /// Something else keeps rewriting the screen's colours, so it and Gloam take turns.
    /// Detected, not guessed from a list of app names: it works for any app.
    private(set) var interference = false
    @ObservationIgnored private var overwrites: [Date] = []
    /// macOS resets gamma tables itself just after a wake or reconfiguration; those resets are
    /// not another app and must not count toward the interference notice.
    @ObservationIgnored private var quietUntil = Date.distantPast
    /// Per-display strength 0…1, looked up by display UUID. 0 leaves a display alone.
    @ObservationIgnored var strength: (String) -> Double = { _ in 1 } { didSet { push() } }
    /// External displays (by UUID) held to the smear floor at the user's request. Their backlight
    /// can't be read, so for them the floor doesn't ease. Built-in displays are always held.
    @ObservationIgnored var smearGuarded: (String) -> Bool = { _ in false } { didSet { push() } }
    /// Each built-in display's share of the smear floor (`Schedule.backlightFactor`) from its
    /// slider; read with the backlight poll, not per fade frame, and eased over about half a
    /// second when it moves while tinted. Missing means all of it.
    private var share: [CGDirectDisplayID: Double] = [:]
    @ObservationIgnored private var shareTask: Task<Void, Never>?
    /// The displays Gloam dims by backlight, each relative to its own baseline. Their signal keeps
    /// full brightness, so the smear floor can only ease their warmth. A display that goes away
    /// keeps its entry: re-reading a still-dimmed panel as a fresh baseline would lose the morning.
    private var dims: [CGDirectDisplayID: BacklightDim] = [:]
    /// Third-party monitors dimmed over DDC/CI; everything else in `dims` goes through macOS.
    @ObservationIgnored private var monitors: [CGDirectDisplayID: DDC] = [:]
    /// Monitors (by UUID) that didn't answer DDC: each try blocks for ~180 ms, so they aren't
    /// asked again on every wake, only when they reconnect.
    @ObservationIgnored private var silent: Set<String> = []
    @ObservationIgnored private var probing = false
    @ObservationIgnored private var probeAgain = false
    @ObservationIgnored private var monitorsPolled = Date.distantPast
    /// Each dimmed display's state by UUID, saved as it changes: after a crash, a kill or a
    /// failed restore the panel is still dimmed, and the next launch must not take that level
    /// for the user's own.
    @ObservationIgnored private var saved: [String: BacklightDim] = [:]
    /// When each saved entry last changed: one older than a day is a display that went away
    /// dimmed, and must not hand its old baseline to whatever reconnects at that level weeks on.
    @ObservationIgnored private var savedAt: [String: Date] = [:]
    @ObservationIgnored private var savedWrite: Task<Void, Never>?
    /// `saved` changed since it was last written to UserDefaults.
    @ObservationIgnored private var savedDirty = false
    private static let savedKey = "dimmedBacklights"
    private struct SavedEntry: Codable { var dim: BacklightDim; var at: Date }
    /// The fraction each display was last asked for, so a monitor that stopped taking writes can
    /// be sent it again; and the light on its way to each monitor, recorded only once confirmed.
    @ObservationIgnored private var requested: [CGDirectDisplayID: Double] = [:]
    @ObservationIgnored private var inFlight: [CGDirectDisplayID: Double] = [:]
    /// A monitor refusing writes is sent its level again, each time waiting twice as long (up
    /// to 5 minutes): one switched to another input may refuse all evening. Reset on wake.
    @ObservationIgnored private var retryAt: [CGDirectDisplayID: Date] = [:]
    @ObservationIgnored private var retryDelay: [CGDirectDisplayID: TimeInterval] = [:]
    /// A built-in's slider level is a second call per poll; it moves only with the light, so it
    /// is read when the light reading moved, or once a minute (the light can be capped while the
    /// slider moves). The factor from the last read is kept for the polls in between.
    @ObservationIgnored private var lastLight: [CGDirectDisplayID: Double] = [:]
    @ObservationIgnored private var levelReadAt: [CGDirectDisplayID: Date] = [:]
    @ObservationIgnored private var levelShare: [CGDirectDisplayID: Double] = [:]
    /// The screens are asleep (the Mac may not be): backlight readings then can be 0 or the
    /// idle-dim level, and adopting one would make it the morning's level. Nothing is read or written.
    @ObservationIgnored private var asleep = false
    /// Readings within a second of a write are the write itself, not an outside move.
    @ObservationIgnored private var backlightWritten: [CGDirectDisplayID: Date] = [:]

    /// Light text on a dark background smears on built-in LCD panels once the white they draw is
    /// dim, whether the signal was dimmed or warmed (`Smear`). Measured on an XDR panel at a
    /// bright backlight: clean with the signal at 80% (61% of the light), heavy at 55%. The floor
    /// is on the luminance of the tinted white, and it eases with the backlight like the dimming
    /// does: at a low backlight the trails are faint, and the room is dark. Deeper evenings are
    /// the backlight's. Changed only by the debug `--floor` flag, to calibrate it on screen.
    static var smearFloor = pow(0.8, Kelvin.displayGamma)

    /// What the main display shows after its light floor and smear floor, live through fades:
    /// the colour of the popover's orb glow. Stored, and set only when it changes: the popover reads it many
    /// times a redraw, and a computed value redrew it on every unrelated change.
    private(set) var effective = Tint.neutral
    /// The main display, kept from the last display change: `CGMainDisplayID` and
    /// `CGDisplayIsBuiltin` are WindowServer round-trips, and the popover asks per frame.
    @ObservationIgnored private var main = CGMainDisplayID()

    /// The smear floor would hold the main display short of `tint`. Asked of the target, not the
    /// live fade, so the popover's notice doesn't pop in halfway through a fade.
    func smearLimits(_ tint: Tint) -> Bool {
        let e = adjusted(tint, for: main)
        return backlight(main) != nil ? e.kelvin > tint.kelvin + 0.5 : e != tint
    }
    var mainIsBuiltin: Bool { isBuiltin(main) }
    var mainColourSpace: LinearRGB { engine.colourSpace(main) }

    /// The backlight dimming in force for a display. None for a monitor that stopped taking
    /// writes before it was dimmed: its evening falls back to the signal rather than not happening.
    private func backlight(_ id: CGDirectDisplayID) -> BacklightDim? {
        guard let dim = dims[id] else { return nil }
        return !dim.isDimming && monitors[id]?.isFailing == true ? nil : dim
    }

    private func isBuiltin(_ id: CGDirectDisplayID) -> Bool { displays.first { $0.id == id }?.isBuiltin ?? false }

    private func smearFloor(for id: CGDirectDisplayID) -> Double {
        guard let display = displays.first(where: { $0.id == id }) else { return 0 }
        if display.isBuiltin { return Self.smearFloor * (share[id] ?? 1) }
        return smearGuarded(display.uuid) ? Self.smearFloor : 0
    }

    /// What the main display would show for `tint`, after its light and smear floors.
    func onMain(_ tint: Tint) -> Tint { adjusted(tint, for: main) }

    /// The main display can't go as dim as `tint` asks (its light floor, or the smear floor
    /// raising brightness): the popover says so, since its ladder shows what was asked.
    func dimLimits(_ tint: Tint) -> Bool { onMain(tint).brightness > tint.brightness + 0.01 }

    private func refreshEffective() {
        let e = adjusted(shown, for: main)
        if e != effective { effective = e }
    }

    /// What this display shows for `tint`: dimmed by backlight (never under the light floor) or
    /// by signal, and never under the smear floor, which on a backlight display can only ease warmth.
    private func adjusted(_ tint: Tint, for id: CGDirectDisplayID) -> Tint {
        let floor = smearFloor(for: id), space = engine.colourSpace(id)
        guard let dim = backlight(id) else { return Smear.limited(tint, floor: floor, in: space) }
        let fraction = max(pow(tint.brightness, Kelvin.displayGamma), dim.lowestFraction)
        return Tint(kelvin: Smear.limited(Tint(kelvin: tint.kelvin), floor: floor, in: space).kelvin,
                    brightness: pow(fraction, 1 / Kelvin.displayGamma))
    }

    @ObservationIgnored private var engine: TintEngine
    @ObservationIgnored private(set) var resolvedEngine: Engine
    @ObservationIgnored private var fadeTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// How often the backlight poll runs now (`pollPace`).
    @ObservationIgnored private var pollEvery: Duration = .seconds(60)
    @ObservationIgnored private var changeTask: Task<Void, Never>?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    init(engine choice: Engine) {
        resolvedEngine = Self.resolve(choice)
        engine = Self.make(resolvedEngine)
        (saved, savedAt) = Self.loadSaved()
        adoptBacklights()
        pollBacklights()
        let workspace = NSWorkspace.shared.notificationCenter
        tasks = [
            (NotificationCenter.default, NSApplication.didChangeScreenParametersNotification),
            (workspace, NSWorkspace.didWakeNotification),
            (workspace, NSWorkspace.screensDidWakeNotification),
        ].map { center, name in
            Task { [weak self] in
                for await _ in center.notifications(named: name) { self?.displaysChangedSoon() }
            }
        } + [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false)].map { name, sleeping in
            Task { [weak self] in
                for await _ in workspace.notifications(named: name) { self?.screens(asleep: sleeping) }
            }
        }
        restartPoll()
    }

    /// Screens off (the Mac may stay awake for hours): nothing is read or written, and the poll
    /// slows to its idle pace. macOS resets the tables on wake, and the wake pushes anyway.
    private func screens(asleep: Bool) {
        self.asleep = asleep
        repace()
    }

    /// Re-reads the backlights now: the popover is opening, and in the day the last reading may
    /// be a minute old (the smear notice and the orb's glow depend on it).
    func refreshBacklights() { pollBacklights() }

    /// Reasserts the tint only when something overwrote it (macOS on some ColorSync events, or
    /// another tinting app); called on the clock's tick. Untinted there is nothing to reassert,
    /// and an interference notice still up is left to clear.
    func keepAlive() {
        guard fadeTask == nil, !asleep, interference || !shown.isNeutral else { return }
        if noteInterference() { push() }
    }

    /// While anything is tinted or dimmed, a backlight macOS controls is read twice a second, so
    /// a brightness key or auto-brightness is followed within half a second; macOS offers no
    /// public change hook. Monitors are only read every 20 s (DDC is slow), so with nothing else
    /// to read the poll runs at that pace. Untinted, or with the screens asleep, nothing depends
    /// on it but the baseline, which is read afresh when dimming starts: once a minute keeps an
    /// idle Mac from waking Gloam 7,000 times an hour (every 20 s with a DDC monitor, whose
    /// baseline can't be read on the spot).
    private var pollPace: Duration {
        let active = !shown.isNeutral || dims.values.contains(where: \.isDimming)
        guard active, !asleep else { return monitors.isEmpty ? .seconds(60) : .seconds(20) }
        let readsMacOS = displays.contains { $0.isBuiltin || (dims[$0.id] != nil && monitors[$0.id] == nil) }
        return readsMacOS ? .milliseconds(500) : .seconds(20)
    }

    /// Moves the poll to the pace things call for; speeding up starts from a fresh reading.
    private func repace() {
        let pace = pollPace
        guard pace != pollEvery else { return }
        if pace < pollEvery { pollBacklights() }
        pollEvery = pace
        restartPoll()
    }

    private func restartPoll() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let every = self?.pollEvery else { return }
                try? await Task.sleep(for: every, tolerance: every / 5)
                guard !Task.isCancelled else { return }
                self?.pollBacklights()
            }
        }
    }

    /// A fade (from a user action) is under way; clock ticks wait rather than cut it short.
    var isFading: Bool { fadeTask != nil }

    func use(_ choice: Engine) {
        engine.reset()
        resolvedEngine = Self.resolve(choice)
        engine = Self.make(resolvedEngine)
        push()
    }

    /// Fade to `target` over `duration` seconds, starting from whatever is on screen now.
    /// A new target during a fade retargets the running one instead of restarting it: a drag
    /// sends ~120 targets a second, and restarting each time meant the fade never got past its
    /// first frame, so the screen only caught up on release. Retargets ease out (no slow start).
    func show(_ target: Tint, duration: Double) {
        guard duration > 0 else {
            fadeTask?.cancel()
            fadeTask = nil
            fade = nil
            guard target != shown else { return }
            shown = target
            return push()
        }
        guard target != (fade?.to ?? shown) else { return }
        fade = Fade(from: shown, to: target, start: Date(), duration: duration, retarget: fadeTask != nil)
        guard fadeTask == nil else { return }
        fadeTask = Task { [weak self] in
            while let self, let f = self.fade, !Task.isCancelled {
                let t = min(1, Date().timeIntervalSince(f.start) / f.duration)
                let eased = f.retarget ? 1 - (1 - t) * (1 - t) : (t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2)
                self.shown = t >= 1 ? f.to : .mix(f.from, f.to, eased)
                self.push()
                if t >= 1 {
                    self.fade = nil
                    self.fadeTask = nil
                    self.writeSaved()
                    return
                }
                try? await Task.sleep(for: .milliseconds(16), tolerance: .milliseconds(4))
            }
        }
    }

    private struct Fade { var from, to: Tint; var start: Date; var duration: Double; var retarget: Bool }
    @ObservationIgnored private var fade: Fade?

    /// Put the displays back exactly as macOS had them; used on quit.
    func restore() {
        fadeTask?.cancel()
        fadeTask = nil
        fade = nil
        shareTask?.cancel()
        tasks.forEach { $0.cancel() }
        pollTask?.cancel()
        changeTask?.cancel()
        asleep = false
        for id in dims.keys { setBacklight(id, fraction: 1) }
        // Checked, and tried again: a backlight left dimmed is the one thing that outlives Gloam.
        for id in dims.keys where monitors[id] == nil && dims[id]?.isDimming == true {
            for _ in 0..<2 where dims[id]?.isDimming == true {
                usleep(50_000)
                setBacklight(id, fraction: 1)
            }
        }
        // A monitor's answer would arrive on the main actor after quitting: wait for it here,
        // and record the restore only if it got through. Unreachable, it stays saved as dimmed,
        // so the next launch restores it.
        for (id, monitor) in monitors {
            guard var dim = dims[id], dim.isDimming, let light = dim.light(for: 1) else { continue }
            var ok = monitor.flush()
            if !ok {
                monitor.set(fraction: light)
                ok = monitor.flush()
            }
            if ok {
                dim.wrote(light, for: 1)
                store(dim, for: id)
            }
        }
        writeSaved()
        engine.restoreAll()
    }

    private func push() {
        var tints: [CGDirectDisplayID: Tint] = [:]
        for display in displays {
            let s = strength(display.uuid)
            guard s > 0 else { continue }
            var t = adjusted(.mix(.neutral, shown, s), for: display.id)
            if backlight(display.id) == nil, dims[display.id] != nil {
                // On the signal fallback: remember what the backlight should show, for the retry.
                requested[display.id] = pow(Tint.mix(.neutral, shown, s).brightness, Kelvin.displayGamma)
            } else if dims[display.id] != nil {
                setBacklight(display.id, fraction: pow(t.brightness, Kelvin.displayGamma))
                t.brightness = 1
            }
            tints[display.id] = t
        }
        // A display switched off in Settings gets its backlight back.
        for display in displays where tints[display.id] == nil && backlight(display.id) != nil {
            setBacklight(display.id, fraction: 1)
        }
        if !asleep { engine.apply(tints) }
        refreshEffective()
        repace()
    }

    private func setBacklight(_ id: CGDirectDisplayID, fraction: Double) {
        guard !asleep, var dim = dims[id] else { return }
        requested[id] = fraction
        // Undimmed, the baseline is only read once a minute: start from the level there now.
        if !dim.isDimming, monitors[id] == nil, fraction < 1, let now = Backlight.light(id) { dim.observe(light: now) }
        guard let light = dim.light(for: fraction) else { return store(dim, for: id) }
        if let monitor = monitors[id] {
            // Sent in the background, the latest value winning, and recorded only once the
            // monitor took it: a write lost to a sleeping monitor must be sent again, not assumed.
            guard inFlight[id] != light else { return }
            inFlight[id] = light
            monitor.set(fraction: light) { [weak self] ok in
                self?.monitorAnswered(id, monitor, light: light, fraction: fraction, ok: ok)
            }
            return
        } else {
            if !dim.isDimming { dim.baselineLevel = Backlight.level(id) }
            let ok = if fraction >= 1, let level = dim.baselineLevel { Backlight.set(level: level, on: id) }
                else { Backlight.set(light: light, on: id) }
            // A failed write changes nothing: the next push tries again from what the panel shows.
            guard ok else { return }
        }
        backlightWritten[id] = Date()
        dim.wrote(light, for: fraction)
        store(dim, for: id)
    }

    private func monitorAnswered(_ id: CGDirectDisplayID, _ monitor: DDC, light: Double, fraction: Double, ok: Bool) {
        if inFlight[id] == light { inFlight[id] = nil }
        guard ok, monitors[id] === monitor, var dim = dims[id] else { return }
        retryAt[id] = nil
        retryDelay[id] = nil
        let wasDimming = dim.isDimming
        backlightWritten[id] = Date()
        dim.wrote(light, for: fraction)
        store(dim, for: id)
        // Dimming took over (perhaps from the signal fallback): drop the signal dimming now,
        // not at the next clock tick.
        if !wasDimming, dim.isDimming, fadeTask == nil { push() }
    }

    /// Every change to `dims` goes through here: unchanged values aren't written (each write
    /// redraws the popover), and the dimmed ones are saved for a launch after a crash.
    private func store(_ dim: BacklightDim, for id: CGDirectDisplayID) {
        guard dims[id] != dim else { return }
        dims[id] = dim
        refreshEffective()
        guard let uuid = displays.first(where: { $0.id == id })?.uuid else { return }
        let keep = dim.isDimming ? dim : nil
        guard saved[uuid] != keep else { return }
        // Starting or ending dimming is saved at once; steps in between at most once a second
        // and at the end of a fade (a fade writes the backlight ~40 times a second).
        let startedOrEnded = (saved[uuid] == nil) != (keep == nil)
        saved[uuid] = keep
        savedAt[uuid] = keep == nil ? nil : Date()
        savedDirty = true
        if startedOrEnded { return writeSaved() }
        guard savedWrite == nil else { return }
        savedWrite = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1), tolerance: .milliseconds(200))
            self?.writeSaved()
        }
    }

    private func writeSaved() {
        savedWrite?.cancel()
        savedWrite = nil
        guard savedDirty else { return }  // every fade ends here, most with nothing new
        savedDirty = false
        let entries = saved.reduce(into: [String: SavedEntry]()) { $0[$1.key] = SavedEntry(dim: $1.value, at: savedAt[$1.key] ?? Date()) }
        UserDefaults.standard.set(try? JSONEncoder().encode(entries), forKey: Self.savedKey)
    }

    /// Entries from the last day that make sense (a hand-edited or corrupt one could otherwise
    /// make the morning write 0).
    private static func loadSaved() -> ([String: BacklightDim], [String: Date]) {
        let entries = UserDefaults.standard.data(forKey: savedKey)
            .flatMap { try? JSONDecoder().decode([String: SavedEntry].self, from: $0) } ?? [:]
        let fresh = entries.filter { _, e in
            Date().timeIntervalSince(e.at) < 86_400 && e.dim.baseline.isFinite && (0...100).contains(e.dim.baseline)
                && e.dim.written.map { $0.isFinite && (0...1).contains($0) } ?? false
        }
        return (fresh.mapValues(\.dim), fresh.mapValues(\.at))
    }

    /// Starts following a display at the light found there: the user's level, unless it is
    /// exactly what a Gloam that never got to quit left behind, whose baseline then still holds.
    private func follow(_ id: CGDirectDisplayID, uuid: String, light: Double, step: Double = 0) {
        var dim = BacklightDim(baseline: light, step: step)
        if var left = saved[uuid], let w = left.written, left.same(light, w) {
            left.step = step
            dim = left
        }
        store(dim, for: id)
    }

    /// Starts following the backlight of any display that isn't followed yet: through macOS where
    /// it can dim the display, else over DDC/CI where the monitor answers.
    private func adoptBacklights() {
        guard !Debug.isShowcase else { return }  // showcase runs never touch the real screen
        for display in displays where dims[display.id] == nil && Backlight.canDim(display.id) {
            if let light = Backlight.light(display.id) { follow(display.id, uuid: display.uuid, light: light) }
        }
        probeMonitors()
    }

    /// Looks for monitors that answer DDC, off the main thread. Monitors already followed are
    /// asked again too: after a wake or replug their I2C service is a new one, and writes
    /// through the old handle fail silently.
    private func probeMonitors() {
        guard !probing else { return probeAgain = true }
        let wanted = displays
            .filter { !$0.isBuiltin && (dims[$0.id] == nil || monitors[$0.id] != nil) && !silent.contains($0.uuid) }
            .map { (id: $0.id, uuid: $0.uuid) }
        guard !wanted.isEmpty else { return }
        let externals = displays.filter { !$0.isBuiltin && DDC.isPhysical($0.id) }.count
        // The old handle's queue must be quiet first: two queues talking to one monitor
        // corrupt each other's replies, and the monitor then looks silent.
        let old = wanted.compactMap { monitors[$0.id] }
        probing = true
        Task.detached { [weak self] in
            old.forEach { _ = $0.flush() }
            let (found, silent) = DDC.probe(wanted, externals: externals)
            await self?.adopt(found, silent: silent)
        }
    }

    private func adopt(_ found: [CGDirectDisplayID: DDC], silent quiet: Set<String>) {
        probing = false
        // A monitor already followed that missed one probe keeps its handle; it isn't written off.
        let followed = Set(displays.filter { monitors[$0.id] != nil }.map(\.uuid))
        silent.formUnion(quiet.subtracting(followed))
        for (id, monitor) in found {
            monitors[id] = monitor
            inFlight[id] = nil
            if let w = dims[id]?.written {
                monitor.set(fraction: w)  // a fresh handle: put the monitor back where Gloam has it
            } else if dims[id] == nil, let uuid = displays.first(where: { $0.id == id })?.uuid {
                follow(id, uuid: uuid, light: monitor.initial, step: monitor.step)
            }
        }
        if probeAgain {
            probeAgain = false
            probeMonitors()
        }
        push()
    }

    /// Re-reads the backlights: outside moves of a dimmed display are adopted (`BacklightDim`),
    /// and when a built-in display's share of the smear floor moved it eases there over 0.6 s (a
    /// key press can move it a lot; a jump read as Gloam fighting the key).
    private func pollBacklights() {
        guard !asleep else { return }
        var next: [CGDirectDisplayID: Double] = [:]
        // DDC reads are slow and some links drop them, so monitors are asked every 20 s, not twice a second.
        let askMonitors = Date().timeIntervalSince(monitorsPolled) > 20
        if askMonitors { monitorsPolled = Date() }
        var lights: [CGDirectDisplayID: Double] = [:]
        for display in displays where dims[display.id] != nil {
            let id = display.id
            if let monitor = monitors[id] {
                guard askMonitors else { continue }
                if monitor.isFailing {
                    // Not read while it refuses writes; sent its level again instead (a monitor
                    // asleep at the morning restore would otherwise stay dim all day).
                    guard Date() >= retryAt[id] ?? .distantPast, let fraction = requested[id] else { continue }
                    let delay = min(300, (retryDelay[id] ?? 10) * 2)
                    retryDelay[id] = delay
                    retryAt[id] = Date().addingTimeInterval(delay)
                    setBacklight(id, fraction: fraction)
                } else {
                    monitor.read { [weak self] in self?.observe($0, on: id) }
                }
            } else {
                lights[id] = Backlight.light(id)
                observe(lights[id], on: id)
                // A write that failed (the morning restore, say) is tried again here: in the day
                // nothing else may push for hours.
                if let fraction = requested[id], dims[id]?.light(for: fraction) != nil { setBacklight(id, fraction: fraction) }
            }
        }
        for display in displays where display.isBuiltin {
            let id = display.id, light = lights[id] ?? Backlight.light(id)
            if light != lastLight[id] || Date().timeIntervalSince(levelReadAt[id] ?? .distantPast) > 60 {
                lastLight[id] = light
                levelReadAt[id] = Date()
                levelShare[id] = Backlight.level(id).map(Schedule.backlightFactor)
            }
            if let factor = levelShare[id] { next[id] = factor }
        }
        let ids = Set(next.keys).union(share.keys)
        guard ids.contains(where: { abs((next[$0] ?? 1) - (share[$0] ?? 1)) > 0.01 }) else { return }
        shareTask?.cancel()
        // Untinted the floor changes nothing on screen: take the new share without easing.
        guard !shown.isNeutral else {
            share = next
            return refreshEffective()
        }
        let from = share, start = Date()
        shareTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                let t = min(1, Date().timeIntervalSince(start) / 0.6)
                let eased = t * t * (3 - 2 * t)
                var share: [CGDirectDisplayID: Double] = [:]
                for id in ids { share[id] = (from[id] ?? 1) + ((next[id] ?? 1) - (from[id] ?? 1)) * eased }
                self.share = share
                if self.fadeTask == nil { self.push() }  // a running fade pushes every frame anyway
                if t >= 1 { return }
                try? await Task.sleep(for: .milliseconds(16), tolerance: .milliseconds(4))
            }
        }
    }

    /// A reading of a followed display; within a second of a write it is the write itself.
    private func observe(_ light: Double?, on id: CGDirectDisplayID) {
        guard let light, var dim = dims[id],
              Date().timeIntervalSince(backlightWritten[id] ?? .distantPast) > 1 else { return }
        dim.observe(light: light)
        store(dim, for: id)
    }

    /// Two overwrites within a minute raise the notice; two quiet minutes clear it. Returns
    /// whether the tint was overwritten just now (and so needs writing again).
    private func noteInterference() -> Bool {
        let now = Date()
        let overwritten = engine.isOverwritten()
        if overwritten && now > quietUntil { overwrites.append(now) }
        overwrites.removeAll { now.timeIntervalSince($0) > 120 }
        let raised = overwrites.filter { now.timeIntervalSince($0) <= 60 }.count >= 2
        if raised != interference && (raised || overwrites.isEmpty) { interference = raised }
        return overwritten
    }

    /// A wake sends several notifications at once (wake, screens wake, one or more parameter
    /// changes), each of which used to re-capture, re-adopt and re-probe: handled once, together.
    private func displaysChangedSoon() {
        quietUntil = Date().addingTimeInterval(10)
        changeTask?.cancel()
        changeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.displaysChanged()
        }
    }

    private func displaysChanged() {
        changeTask = nil
        quietUntil = Date().addingTimeInterval(10)
        let known = Set(displays.map(\.uuid))
        displays = Displays.current()
        main = CGMainDisplayID()
        // Normally cleared by the screens' wake; also here, so a missed notification can't stop
        // backlights being read for good.
        if asleep, CGDisplayIsAsleep(main) == 0 { asleep = false }
        retryAt = [:]
        retryDelay = [:]
        levelReadAt = [:]
        silent.subtract(displays.map(\.uuid).filter { !known.contains($0) })  // reconnected: ask again
        engine.displaysChanged()
        adoptBacklights()
        pollBacklights()
        push()
    }

    private static func resolve(_ choice: Engine) -> Engine {
        EnginePolicy.resolve(choice, chip: SystemInfo.chip, osMajor: SystemInfo.osMajor)
    }

    private static func make(_ engine: Engine) -> TintEngine {
        if Debug.isShowcase { return NullEngine() }
        return engine == .overlay ? OverlayEngine() : GammaEngine()
    }
}

/// Leaves the screen alone in debug showcase runs.
private final class NullEngine: TintEngine {
    func apply(_ tints: [CGDirectDisplayID: Tint]) {}
    func reset() {}
    func displaysChanged() {}
}

enum SystemInfo {
    static let osMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    static let chip: String = {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        return String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self)
    }()
}
