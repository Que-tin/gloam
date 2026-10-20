// Owns the active engine and moves the screen toward a target tint: eased fades for user
// actions, direct writes for the clock's small steps (writes are skipped when nothing changed).
// On each clock tick it checks whether the tint was overwritten and only then writes it again,
// because macOS quietly resets gamma tables on wake, display changes and some ColorSync events.
// Displays whose backlight macOS controls (built-in, Apple displays), and monitors that answer
// DDC/CI, are dimmed by backlight, relative to the level found there (`BacklightDim`); the rest
// by signal. Each screen shows the plan (the target tint) plus its own shift (`Shift`): the
// brightness keys, its buttons, or the ladder moved it away from the plan tonight. A dimmed backlight outlives the process (gamma tables don't), so what each one was
// dimmed from is saved as it changes (`SavedDims`), and a launch after a crash puts it back.
// Each built-in display's slider level (the user's, not Gloam's dimming) also eases its smear floor.

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
    /// A change is arriving and nothing is tinted: clear what an earlier change left on screen.
    func settleKept()
    /// Whether another app has rewritten what this engine put on screen.
    func isOverwritten() -> Bool
    /// The display's linear RGB, for estimates that should match what it really shows.
    func colourSpace(_ id: CGDirectDisplayID) -> LinearRGB
}

extension TintEngine {
    func isOverwritten() -> Bool { false }
    func restoreAll() { reset() }
    func settleKept() {}
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
    /// macOS usually resets gamma tables itself just after a wake or reconfiguration; those resets are
    /// not another app and must not count toward the interference notice.
    @ObservationIgnored private var quietUntil = Date.distantPast
    /// Per-display strength 0…1, looked up by display UUID. 0 leaves a display alone.
    @ObservationIgnored var strength: (String) -> Double = { _ in 1 } { didSet { push() } }
    /// External displays (by UUID) held to the smear floor at the user's request. Their backlight
    /// can't be read, so for them the floor doesn't ease. Built-in displays are always held.
    @ObservationIgnored var smearGuarded: (String) -> Bool = { _ in false } { didSet { push() } }
    /// Told after the screens change: a new one can end the model's quiet (all others at 0).
    @ObservationIgnored var displaysDidChange: () -> Void = {}
    /// How far the user's settings go past the recommended night (`Schedule.pastRecommended`):
    /// their consent to what deeper costs. Warmth eases the smear floor away (none at ember),
    /// dimming eases the backlight's light floor down to `BacklightDim.deepestFloorLight`.
    var consent: (warmth: Double, dimming: Double) = (0, 0) {
        didSet {
            consentKnown = true
            guard consent != oldValue else { return }
            for (id, var dim) in dims {
                // A shift below the floor keeps the light it shows: the same position on a lower
                // floor was darker than what was pressed. Moved by the difference, so its distance
                // from the plan (and its morning) stay its own. Not before the first target: at
                // launch the saved shifts were taken on the consent being set now.
                let uuid = uuidOf[id], plan = shiftPlan(for: id)
                let shift = uuid.flatMap { shifts[$0] }
                let below = firstTargetShown ? shift.map { $0.position(plan: plan, now: clock.now) }.flatMap { $0 > 1 ? $0 : nil } : nil
                let shownLight = below.map { dim.light(at: $0) }
                dim.lightFloor = lightFloor
                store(dim, for: id)
                if let uuid, let shift, let below, let shownLight {
                    shifts[uuid] = shift.moved(by: dim.position(of: shownLight) - below)
                }
            }
            push()
        }
    }
    /// The model has set `consent` (just after `init`, where the saved dims are followed).
    @ObservationIgnored private var consentKnown = false
    /// Launched with a backlight still dimmed (after an update, a crash): nothing is pushed until
    /// the model's first target, which then shows at once. Pushed from the neutral start, the
    /// backlight went to full brightness first and faded back down. Monitors are found later (the
    /// probe) and hold the same way if that's before the first target.
    @ObservationIgnored private var resumedAtLaunch = false
    /// The model has shown a target: from then on a resumed display is simply pushed.
    @ObservationIgnored private var firstTargetShown = false
    /// Each screen's dimming shift from the plan tonight (`Shift`), by UUID: a key press or the
    /// monitor's buttons there, or the ladder with the popover open on it. Saved (debounced, not
    /// per fade frame) until its morning ends it: a crash or an update keeps it.
    private(set) var shifts: [String: Shift] = DisplayController.loadShifts() {
        didSet { if shifts != oldValue { saveShiftsSoon() } }
    }
    @ObservationIgnored private var shiftSave: Task<Void, Never>?
    /// Off, paused or previewing, every screen shows the plan alone (the model's neutral, or
    /// Settings' preview). Set by the model before its `show`, which fades the shifts out or in
    /// with the tint (`shiftWeight`): switched at once, a pause first jumped by the shift.
    /// Coming back (a pause ended, the preview closed) in the morning, a shift already shrinking
    /// goes: faded back in, a pause "Until Morning" ending at wake dimmed the screen again.
    @ObservationIgnored var shiftsWanted = true {
        didSet {
            guard shiftsWanted, !oldValue else { return }
            let live = shifts.filter { !$0.value.isShrinking(clock.now) }
            if live.count != shifts.count { shifts = live }
        }
    }
    /// How much of each shift shows, 0…1: faded with the tint by `show`. From 0: a launch fades
    /// the shifts in with the plan (at 1, a saved shift showed alone before the plan came).
    @ObservationIgnored private var shiftWeight = 0.0
    @ObservationIgnored private var shiftFades: [String: Task<Void, Never>] = [:] {
        didSet { shiftGoals = shiftGoals.filter { shiftFades[$0.key] != nil } }
    }
    /// Where each running shift fade is heading (`ladderPosition`).
    private var shiftGoals: [String: Double] = [:]
    /// The model's clock and what a shift chosen now belongs to (`ShiftClock`): set by the model,
    /// about once a second. Shifts move with it in the morning while the plan may stand still
    /// (neutral already, its fade-out under way): pushed then, or they waited for their expiry.
    @ObservationIgnored var clock = ShiftClock.idle {
        didSet { if fadeTask == nil, shifts.values.contains(where: { $0.isShrinking(clock.now) }) { push() } }
    }
    private var lightFloor: Double {
        BacklightDim.floorLight + (BacklightDim.deepestFloorLight - BacklightDim.floorLight) * consent.dimming
    }
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
    /// A followed monitor can miss the probe after a change (its DDC not up yet): asked once
    /// more a few seconds later, since writes through its old handle fail silently.
    @ObservationIgnored private var reprobe: Task<Void, Never>?
    @ObservationIgnored private var reprobed = false
    /// The reprobe is wanted (`reprobeWanted`, until a probe starts) or running (`reprobing`):
    /// only its answer ends the doubt. An earlier probe's answer arriving first (a second display
    /// change queued one) cleared it, and the release went through the dead handle after all.
    @ObservationIgnored private var reprobeWanted = false
    @ObservationIgnored private var reprobing = false
    /// Followed monitors whose handle may be dead: every one from a wake or display change until
    /// the probe answers for it, and those it missed until the reprobe. Nothing is sent or read
    /// through the old handle meanwhile: a release written there "got through" to a dead service,
    /// and the probe then took the still-dimmed level as the day's.
    @ObservationIgnored private var doubtful: Set<CGDirectDisplayID> = []
    /// When each monitor was last read (a probe's first reading counts): DDC is slow, so each is
    /// read on its own pace (`pollBacklights`), freshly before its first dimming step, before a
    /// step once the last reading is a few seconds old, and once at each fade's start.
    @ObservationIgnored private var monitorReadAt: [CGDirectDisplayID: Date] = [:]
    /// Monitors whose I2C service is being probed: nothing is sent to them meanwhile (two queues
    /// on one monitor corrupt each other's replies); the push after the probe sends it.
    @ObservationIgnored private var probingIDs: Set<CGDirectDisplayID> = []
    /// Each followed display's UUID, kept after it goes: the same screen back under a new id (a
    /// replug, a wake) must replace its old entry, not be followed twice.
    @ObservationIgnored private var uuidOf: [CGDirectDisplayID: String] = [:]
    /// Each dimmed display's state by UUID, for a launch after a crash.
    @ObservationIgnored private var saved = SavedDims.load()
    @ObservationIgnored private var savedWrite: Task<Void, Never>?
    /// The position each display was last asked for, so a monitor that stopped taking writes can
    /// be sent it again; and the light on its way to each monitor, recorded only once confirmed.
    @ObservationIgnored private var requested: [CGDirectDisplayID: (position: Double, release: Bool)] = [:]
    @ObservationIgnored private var inFlight: [CGDirectDisplayID: Double] = [:]
    /// Monitors being read (`readFirst`: the poll's routine read, and `setBacklight`'s before a
    /// step): no step goes out until the reading is in, so it starts from what the monitor shows.
    @ObservationIgnored private var readingFirst: Set<CGDirectDisplayID> = []
    /// A monitor refusing writes is sent its level again, each time waiting twice as long (up
    /// to 5 minutes): one switched to another input may refuse all evening. Reset on wake.
    @ObservationIgnored private var retryAt: [CGDirectDisplayID: Date] = [:]
    @ObservationIgnored private var retryDelay: [CGDirectDisplayID: TimeInterval] = [:]
    /// The last undimmed (slider level, light) pair, to turn an adopted baseline light back into
    /// a slider level while dimming, and to tell when the light reading moved.
    @ObservationIgnored private var undimmed: [CGDirectDisplayID: (level: Double, light: Double)] = [:]
    /// A built-in's slider level is a second call per poll; it moves only with the light, so it
    /// is read when the light reading moved, or once a minute (the light can be capped while the
    /// slider moves). The factor from the last read is kept for the polls in between. Only read
    /// while Gloam isn't dimming; while it is, the smear floor follows the level the user set
    /// (`userLevel`), not Gloam's own dimming below it.
    @ObservationIgnored private var levelReadAt: [CGDirectDisplayID: Date] = [:]
    @ObservationIgnored private var levelShare: [CGDirectDisplayID: Double] = [:]
    /// The screens are asleep (the Mac may not be): backlight readings then can be 0 or the
    /// idle-dim level, and adopting one would make it the morning's level. No backlight is read or
    /// written; a tint is only cleared (`push`), so a screen wakes neutral after the evening.
    @ObservationIgnored private var asleep = false
    /// Readings within a second of a write are the write itself, not an outside move. (Adopting a
    /// built-in's reading that differs from the write was tried: unmeasured whether DisplayServices
    /// reports a write at once, a trailing read mid-fade would be taken for a key press and drift
    /// the baseline. A press during a fade is undone instead.)
    @ObservationIgnored private var backlightWritten: [CGDirectDisplayID: Date] = [:]
    /// When each backlight macOS controls was last read: one read longer ago than half a second
    /// is read again right before Gloam writes it, so a key press is adopted, not overwritten
    /// (outside fades; see `backlightWritten`).
    @ObservationIgnored private var backlightRead: [CGDirectDisplayID: Date] = [:]
    /// The popover is open: brightness keys are read twice a second, so what it shows follows
    /// them. Closed, backlights are read on the clock's tick (`tickBacklights`) and before writes.
    @ObservationIgnored var watchingClosely = false { didSet { repace() } }

    /// Light text on a dark background smears on built-in LCD panels once the white they draw is
    /// dim, whether the signal was dimmed or warmed (`Smear`). Measured on an XDR panel at a
    /// bright backlight: clean with the signal at 80% (61% of the light), heavy at 55%. The floor
    /// is on the luminance of the tinted white, and it eases with the user's slider: trails fade at
    /// a low backlight, measured on one panel (docs/science.md). Deeper evenings are
    /// the backlight's. Changed only by the debug `--floor` flag, to calibrate it on screen.
    static var smearFloor = pow(0.8, Kelvin.displayGamma)

    /// What the main display shows after its light floor and smear floor, live through fades:
    /// the colour of the popover's orb glow. Stored, and set only when it changes: the popover reads it many
    /// times a redraw, and a computed value redrew it on every unrelated change.
    private(set) var effective = Tint.neutral
    /// The same for every display, by id: the popover glows with the screen it is open on.
    private(set) var effectives: [CGDirectDisplayID: Tint] = [:]
    func effective(on id: CGDirectDisplayID) -> Tint { effectives[id] ?? effective }
    /// The main display, kept from the last display change: `CGMainDisplayID` and
    /// `CGDisplayIsBuiltin` are WindowServer round-trips, and the popover asks per frame.
    @ObservationIgnored private var main = CGMainDisplayID()


    /// The backlight dimming in force for a display. None for a monitor that stopped taking
    /// writes before it was dimmed: its evening falls back to the signal rather than not happening.
    private func backlight(_ id: CGDirectDisplayID) -> BacklightDim? {
        guard let dim = dims[id] else { return nil }
        return !dim.isDimming && monitors[id]?.isFailing == true ? nil : dim
    }

    /// The smear floor in force: all of it on a built-in (eased by the user's slider, `share`) or
    /// a monitor that opted in, less as Warmest goes past the recommended night (`consent`).
    private func smearFloor(for id: CGDirectDisplayID) -> Double {
        // Showcase runs (the README's pictures) show a plain monitor, whichever screen is main:
        // a built-in's floor made them differ from Mac to Mac.
        guard !Debug.isShowcase, let display = displays.first(where: { $0.id == id }) else { return 0 }
        let accepted = 1 - consent.warmth
        if display.isBuiltin { return Self.smearFloor * (share[id] ?? 1) * accepted }
        return smearGuarded(display.uuid) ? Self.smearFloor * accepted : 0
    }

    /// A built-in's day level now against its level by day, at most 1: what a move in the
    /// evening's first minutes took away (`BacklightDim.Move.dayLevel`), which the blue-light
    /// reading counts too; later moves are shifts, in `onScreen`. By day, without a backlight or
    /// for a monitor (no day reading kept), 1.
    func lightSinceDay(on id: CGDirectDisplayID) -> Double {
        guard !shown.isNeutral, let dim = backlight(id),
              let uuid = uuidFor(id), let day = dayLight[uuid], day > 0 else { return 1 }
        return min(1, max(0, min(1, dim.baseline) / day))
    }
    /// Each display's light by day: read only while nothing is tinted, so neither the evening's
    /// key presses nor a released dimming move the reference. By UUID, across display changes.
    @ObservationIgnored private var dayLight: [String: Double] = [:]

    /// What a display would show for `tint`, after its shift and its light and smear floors.
    func onScreen(_ tint: Tint, _ id: CGDirectDisplayID) -> Tint { adjusted(tint, for: id) }
    func colourSpace(of id: CGDirectDisplayID) -> LinearRGB { engine.colourSpace(id) }

    /// The slider level the user set while Gloam dims: the one saved when dimming began (also
    /// after a crash, from the saved state), else the adopted baseline light turned back into a
    /// level by the last undimmed reading (slider levels follow light roughly as a 2.2 power).
    private func userLevel(_ id: CGDirectDisplayID, _ dim: BacklightDim) -> Double? {
        if let level = dim.baselineLevel { return level }
        guard let (level, light) = undimmed[id], light > 0 else { return nil }
        return min(1, max(0, level * pow(dim.baseline / light, 1 / Kelvin.displayGamma)))
    }

    /// Whether the ladder can dim this screen: tinted, and not already at its floor by day level.
    func canDim(_ id: CGDirectDisplayID) -> Bool {
        displays.contains { $0.id == id && strength($0.uuid) > 0 } && darkest(id) < 0.999
    }

    /// Where a display's 100 % dimming lands: its backlight's light floor against its day level,
    /// else the signal floor. Not the smear floor
    /// as it moves with warmth: the ladder must not reach further when the dial turns. Signal-
    /// dimmed, the smear floor at daylight counts (a protected monitor), or the ladder's lower
    /// half would do nothing.
    private func darkest(_ id: CGDirectDisplayID) -> Double {
        if let dim = backlight(id) { return dim.darkest }
        return max(Stage.brightnessRange.lowerBound, pow(smearFloor(for: id), 1 / Kelvin.displayGamma))
    }

    private func refreshEffective() {
        // As tinted as the main display's own setting (Settings › Displays) has it: switched off
        // there, the orb, its glow and the blue-light reading show an untinted screen.
        var all: [CGDirectDisplayID: Tint] = [:]
        for display in displays { all[display.id] = adjusted(.mix(.neutral, shown, strength(display.uuid)), for: display.id) }
        let e = all[main] ?? adjusted(shown, for: main)
        if e != effective { effective = e }
        if all != effectives { effectives = all }
    }

    /// What this display shows for `tint` (the plan, for it): its position, plan plus its shift
    /// (`position`), taken the same share of the way to this display's own darkest, by backlight
    /// or by signal, and never under the smear floor, which on a backlight display can only ease
    /// warmth. As a signal brightness either way (the orb's reading is worked out from it).
    private func adjusted(_ tint: Tint, for id: CGDirectDisplayID) -> Tint {
        let floor = smearFloor(for: id), space = engine.colourSpace(id), q = position(tint, for: id)
        guard let dim = backlight(id) else {
            let here = Tint(kelvin: tint.kelvin, brightness: 1 - min(1, q) * (1 - darkest(id)))
            return Smear.limited(here, floor: floor, in: space)
        }
        let top = min(1, dim.baseline)
        let brightness = top > 0 ? pow(dim.light(at: q) / top, 1 / Kelvin.displayGamma) : 1
        return Tint(kelvin: Smear.limited(Tint(kelvin: tint.kelvin), floor: floor, in: space).kelvin, brightness: brightness)
    }

    /// The position a display shows for `tint`, its plan: plus its shift, as much as shows
    /// (`shiftWeight`). Past 1 (below the floor, a key press's) only on a backlight.
    private func position(_ tint: Tint, for id: CGDirectDisplayID) -> Double {
        let plan = Light.dimming(tint.brightness)
        guard shiftWeight > 0, let shift = shift(for: id) else { return plan }
        let p = shiftPlan(plan, for: id)
        let q = p + shiftWeight * (shift.position(plan: p, now: clock.now) - p)
        return min(backlight(id) == nil ? 1 : 2, max(0, q))
    }

    /// The plan as this screen shows it, for its shift: on a screen with no range (its day level
    /// at or under its floor) every dimming plan shows the floor, so it counts as 1. Measured from
    /// the plan itself there, a lamp lowering the plan undid a press made below the floor. Also
    /// while its shift still fades after the plan is done: back at 0 then, a press below the floor
    /// came back to the day level in one jump.
    private func shiftPlan(_ plan: Double, for id: CGDirectDisplayID) -> Double {
        darkest(id) >= 0.999 && (plan > 0 || shift(for: id)?.isShrinking(clock.now) == true) ? 1 : plan
    }
    private func shiftPlan(for id: CGDirectDisplayID) -> Double { shiftPlan(plan(for: id), for: id) }

    private func uuidFor(_ id: CGDirectDisplayID) -> String? { uuidOf[id] ?? displays.first(where: { $0.id == id })?.uuid }
    private func shift(for id: CGDirectDisplayID) -> Shift? { uuidFor(id).flatMap { shifts[$0] } }

    /// The plan's position for a display, where the screens are heading (not mid-fade): what a
    /// move there is measured from.
    private func plan(for id: CGDirectDisplayID) -> Double {
        let s = displays.first(where: { $0.id == id }).map { strength($0.uuid) } ?? 1
        return Light.dimming(Tint.mix(.neutral, fade?.to ?? shown, s).brightness)
    }

    // MARK: Shifts

    /// The ladder's position for a screen: the plan where the screens are heading, plus its shift.
    /// Past 1 when a press took it below the floor (`ladderBeyond`); the ladder shows 100 % there.
    func ladderPosition(_ id: CGDirectDisplayID) -> Double {
        // Mid-way through the ladder's own ease, where it is heading: read from the screen, a step
        // still showed the old cell, so its detent never came and a drag kept restarting the fade.
        if let goal = uuidFor(id).flatMap({ shiftGoals[$0] }) { return goal }
        let s = displays.first(where: { $0.id == id }).map { strength($0.uuid) } ?? 1
        return position(.mix(.neutral, fade?.to ?? shown, s), for: id)
    }

    /// The ladder moved with the popover open on this screen: its shift, eased there briefly.
    func shift(_ id: CGDirectDisplayID, to position: Double) {
        guard let uuid = uuidFor(id) else { return }
        fadeShift(uuid, id, to: position, over: 0.15, showingGoal: true)
    }

    /// Every screen back on the plan ("Auto"), eased over a second.
    func clearShifts() {
        for uuid in shifts.keys {
            guard let id = displays.first(where: { $0.uuid == uuid })?.id else { shifts[uuid] = nil; continue }
            fadeShift(uuid, id, to: nil, over: 0.5)
        }
    }

    /// Shifts whose morning has ended go, whether or not Gloam saw it (asleep, quit, the lid shut).
    func expireShifts() {
        let live = shifts.filter { !$0.value.expired(clock.now) }
        guard live.count != shifts.count else { return }
        Debug.log("expired shifts \(Set(shifts.keys).subtracting(live.keys)) at \(clock.now)")
        shifts = live
        push()
    }

    /// Some screen shows a shift that moves it at least half a ladder step: "Manual". Screens
    /// that aren't there or aren't tinted don't count.
    var showsShift: Bool {
        displays.contains { display in
            guard strength(display.uuid) > 0, let shift = shifts[display.uuid] else { return false }
            return abs(shift.offset(plan: shiftPlan(for: display.id), now: clock.now)) >= 0.025
        }
    }

    /// Moves a screen's shift to `goal` (nil: back on the plan) frame by frame, so the ladder and
    /// Auto ease like the rest of Gloam's changes; a key press is written as it is, with no fade.
    /// `showingGoal`: the ladder's own move, shown where it is heading (`ladderPosition`); Auto's
    /// return glides on the ladder as on the dial.
    private func fadeShift(_ uuid: String, _ id: CGDirectDisplayID, to goal: Double?, over duration: Double,
                           showingGoal: Bool = false) {
        shiftFades[uuid]?.cancel()
        let plan = shiftPlan(for: id), start = Date()
        let from = shifts[uuid]?.position(plan: plan, now: clock.now) ?? plan
        let end = goal ?? plan
        shiftFades[uuid] = Task { [weak self] in
            while let self, !Task.isCancelled {
                let t = min(1, Date().timeIntervalSince(start) / duration)
                let eased = t * t * (3 - 2 * t)
                let plan = self.shiftPlan(for: id)
                self.shifts[uuid] = t >= 1 && goal == nil ? nil
                    : self.newShift(to: from + (end - from) * eased, plan: plan)
                self.push()
                if t >= 1 { self.shiftFades[uuid] = nil; return }
                try? await Task.sleep(for: .milliseconds(16), tolerance: .milliseconds(4))
            }
        }
        shiftGoals[uuid] = showingGoal ? end : nil  // an earlier ladder move's goal mustn't stay
    }

    /// A shift chosen now: tonight's until the morning is done; after it, the coming evening's.
    /// None where it sits on the plan.
    private func newShift(to position: Double, plan: Double) -> Shift? {
        Shift.make(to: position, at: plan, now: clock.now, until: clock.until)
    }

    /// Bedtime or wake moved tonight: shifts belonging to this evening end with its new morning.
    func retimeShifts(from oldUntil: Date, to newUntil: Date) {
        guard oldUntil != newUntil, oldUntil > clock.now else { return }
        // Its own (a late choice can end up to half an hour after the morning: `perUnit`), not the
        // coming evening's.
        let tonight = { (s: Shift) in s.until >= oldUntil && s.until < oldUntil.addingTimeInterval(3600) }
        shifts = shifts.mapValues { tonight($0) ? $0.retimed(by: newUntil.timeIntervalSince(oldUntil)) : $0 }
        push()
    }

    private func saveShiftsSoon() {
        shiftSave?.cancel()
        shiftSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            self.saveShifts()
        }
    }

    private func saveShifts() {
        shiftSave?.cancel()
        shiftSave = nil
        UserDefaults.standard.set(try? JSONEncoder().encode(shifts), forKey: "dimShifts")
    }

    private static func loadShifts() -> [String: Shift] {
        UserDefaults.standard.data(forKey: "dimShifts").flatMap { try? JSONDecoder().decode([String: Shift].self, from: $0) } ?? [:]
    }

    @ObservationIgnored private var engine: TintEngine
    @ObservationIgnored private let redraw = Redraw()
    @ObservationIgnored private(set) var resolvedEngine: Engine
    @ObservationIgnored private var fadeTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// How often the backlight poll's own timer runs now (`pollPace`); nil when it doesn't.
    @ObservationIgnored private var pollEvery: Duration?
    @ObservationIgnored private var changeTask: Task<Void, Never>?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    init(engine choice: Engine) {
        resolvedEngine = Self.resolve(choice)
        engine = Self.make(resolvedEngine)
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
    }

    /// Screens off (the Mac may stay awake for hours): no backlight is read or written, a tint only
    /// to clear it (`push`), and the popover's poll stops. macOS usually resets the tables on
    /// wake, and the wake pushes anyway.
    private func screens(asleep: Bool) {
        let woke = self.asleep && !asleep
        self.asleep = asleep
        changedAt = Date()
        if woke { doubtful.formUnion(monitors.keys) }  // as `displaysChangedSoon`: the probe follows
        if woke { easeFromApplied() }
        repace()
    }

    /// What the screens last showed (`applied`, kept while they slept) eases to what's due now:
    /// the evening moved on while they were off, and the push after the wake snapped it there.
    private func easeFromApplied() {
        let target = fade?.to ?? shown
        guard applied != target else { return }
        shown = applied
        fade = nil
        fadeTask?.cancel()
        fadeTask = nil
        show(target, duration: 1.5)
    }

    /// The routine read, on the clock's tick (every 5 s while anything is tinted or due, every
    /// minute idle): brightness keys and auto-brightness are adopted, failed writes retried.
    /// `idle` (the slow tick) also slows the monitors' reads.
    func tickBacklights(idle: Bool) {
        self.idle = idle
        wakeIfMissed()
        pollBacklights()
    }

    /// The screens' wake can go missing (the model checks too): asleep for good, nothing was
    /// written all evening.
    private func wakeIfMissed() {
        guard asleep, CGDisplayIsAsleep(main) == 0 else { return }
        asleep = false
        changedAt = Date()
        easeFromApplied()
        repace()
    }
    /// The clock ticks slowly: nothing tinted, nothing due within the minute and a bit.
    @ObservationIgnored private var idle = false

    /// Reasserts the tint only when something overwrote it (macOS on some ColorSync events, or
    /// another tinting app); called on the clock's tick. Untinted there is nothing to reassert,
    /// and an interference notice still up is left to clear.
    func keepAlive() {
        // A shift held by day tints a signal-dimmed screen with the plan neutral: reasserted too.
        guard fadeTask == nil, !asleep, interference || !shown.isNeutral || shiftWeight > 0 && !shifts.isEmpty else { return }
        if noteInterference() { push() }
    }

    /// The poll's own timer: only while the popover is open, twice a second for a backlight macOS
    /// controls (macOS offers no public change hook). Otherwise the clock's tick does the routine
    /// reads (`tickBacklights`, from the model's launch on), and every write reads first
    /// (`setBacklight`), so a key press is adopted within 5 s, not overwritten (but undone
    /// mid-fade): the 500 ms poll all evening was ~7,000 wakeups an hour. Monitors keep their own
    /// pace in `pollBacklights`. The popover opening reads at once (the model's `refreshNow`).
    private var pollPace: Duration? {
        let readsMacOS = displays.contains { $0.isBuiltin || (dims[$0.id] != nil && monitors[$0.id] == nil) }
        return !asleep && watchingClosely && readsMacOS ? .milliseconds(500) : nil
    }

    private func repace() {
        let pace = pollPace
        guard pace != pollEvery else { return }
        pollEvery = pace
        restartPoll()
    }

    private func restartPoll() {
        pollTask?.cancel()
        pollTask = nil
        guard pollEvery != nil else { return }
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
        overwrites = []  // the overlay ends the tug of war: the notice goes with it
        interference = false
        resolvedEngine = Self.resolve(choice)
        engine = Self.make(resolvedEngine)
        push()
    }

    /// Fade to `target` over `duration` seconds, starting from whatever is on screen now.
    /// A new target during a fade retargets the running one instead of restarting it: a drag
    /// sends ~120 targets a second, and restarting each time meant the fade never got past its
    /// first frame, so the screen only caught up on release. Retargets ease out (no slow start).
    func show(_ target: Tint, duration requested: Double) {
        firstTargetShown = true
        if resumedAtLaunch {
            // Pushed even if it equals `shown` (neutral by day): the held pushes never ran, and a
            // backlight resumed dimmed must be released, or it stayed at last night's level.
            resumedAtLaunch = false
            fadeTask?.cancel()
            fadeTask = nil
            fade = nil
            shown = target
            shiftWeight = shiftsWanted ? 1 : 0
            return push()
        }
        // A monitor takes about a step every 0.1 s: a fade shorter than its steps left the last
        // ones landing after the signal had stopped, each a visible dip. Half again for the eased
        // middle, where the fade outruns the steps. Drags (short fades) keep their pace.
        let duration = requested >= 0.3 ? max(requested, 0.15 * monitorSteps(to: target)) : requested
        let weight = shiftsWanted ? 1.0 : 0
        guard duration > 0 else {
            fadeTask?.cancel()
            fadeTask = nil
            fade = nil
            guard target != shown || weight != shiftWeight else { return }
            shown = target
            shiftWeight = weight
            return push()
        }
        guard target != (fade?.to ?? shown) || weight != (fade?.toWeight ?? shiftWeight) else { return }
        fade = Fade(from: shown, to: target, fromWeight: shiftWeight, toWeight: weight,
                    start: Self.uptime, duration: duration, retarget: fadeTask != nil)
        guard fadeTask == nil else { return }
        fadeBegan = Date()
        fadeTask = Task { [weak self] in
            while let self, let f = self.fade, !Task.isCancelled {
                let t = min(1, (Self.uptime - f.start) / f.duration)
                let eased = f.retarget ? 1 - (1 - t) * (1 - t) : (t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2)
                self.shown = t >= 1 ? f.to : .mix(f.from, f.to, eased)
                self.shiftWeight = f.fromWeight + (f.toWeight - f.fromWeight) * (t >= 1 ? 1 : eased)
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

    private struct Fade {
        var from, to: Tint
        var fromWeight, toWeight: Double  // `shiftWeight`, faded with the tint
        var start: TimeInterval
        var duration: Double
        var retarget: Bool
    }
    /// Fades run on the Mac's uptime, not the wall clock: a clock set back by hand mid-fade made
    /// one last as long as the jump, with the schedule held meanwhile.
    private static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// The most whole steps any monitor has to take to show `target`.
    private func monitorSteps(to target: Tint) -> Double {
        displays.reduce(0) { most, display in
            guard let monitor = monitors[display.id], !monitor.isFailing, !probingIDs.contains(display.id),
                  !doubtful.contains(display.id),
                  let dim = dims[display.id], dim.step > 0 else { return most }
            let goal = dim.light(at: position(.mix(.neutral, target, strength(display.uuid)), for: display.id))
            return max(most, (abs(goal - (dim.written ?? min(1, dim.baseline))) / dim.step).rounded())
        }
    }
    @ObservationIgnored private var fade: Fade?
    /// The tint last put on screen: `shown` moves on while the screens sleep, the screens don't.
    @ObservationIgnored private var applied = Tint.neutral
    /// The last wake or display change (`observe` distrusts dark readings for a few seconds after).
    @ObservationIgnored private var changedAt = Date()
    /// Each monitor's signal share at the last push: the redraw dot shows only while it moves.
    @ObservationIgnored private var lastShare: [CGDirectDisplayID: Double] = [:]
    /// When the running fade began (retargets keep it): a monitor is read once per fade (`setBacklight`).
    @ObservationIgnored private var fadeBegan = Date.distantPast

    /// Quitting for an update that relaunches at once: backlights stay where they are, saved as
    /// dimmed, so the new copy resumes them (`follow`) without a flash of full brightness. The
    /// gamma tables go back by themselves as the process ends.
    func keepForRelaunch() {
        fadeTask?.cancel()
        fadeTask = nil
        fade = nil
        writeSaved()
    }

    /// Put the displays back exactly as macOS had them; used on quit.
    func restore() {
        fadeTask?.cancel()
        fadeTask = nil
        fade = nil
        shareTask?.cancel()
        tasks.forEach { $0.cancel() }
        pollTask?.cancel()
        changeTask?.cancel()
        // Asleep (an overnight update restart, a shutdown with the display off) or gone (lid
        // closed, unplugged), a write may not stick though it reports success: it is sent, but the
        // display stays saved as dimmed, and the next launch finds which (`follow`).
        let unsure = dims.filter { id, dim in dim.isDimming && (asleep || !displays.contains { $0.id == id }) }
        asleep = false
        for id in dims.keys { setBacklight(id, position: 0) }
        // Checked, and tried again: a backlight left dimmed is the one thing that outlives Gloam.
        for id in dims.keys where monitors[id] == nil && dims[id]?.isDimming == true {
            for _ in 0..<2 where dims[id]?.isDimming == true {
                usleep(50_000)
                setBacklight(id, position: 0)
            }
        }
        // A monitor walks back a step at a time, which quitting can't wait for: its baseline goes
        // in one write here, waited for, and the restore is recorded only if it got through.
        // Unreachable or unplugged, it stays saved as dimmed, so the next launch (or reconnect)
        // restores it. A first step still in flight counts: it lands after this, one step dim.
        // Not through a handle in doubt or being replaced: the write "gets through" to a dead
        // service, the dim is dropped as released, and the next launch takes the night as the day.
        for (id, monitor) in monitors where displays.contains(where: { $0.id == id })
            && !doubtful.contains(id) && !probingIDs.contains(id) {
            guard var dim = dims[id], dim.isDimming || inFlight[id] != nil else { continue }
            let light = min(1, dim.baseline)
            var ok = false
            for _ in 0..<2 where !ok {
                monitor.set(fraction: light)
                ok = monitor.flush()
            }
            if ok {
                dim.wrote(light, release: true)
                store(dim, for: id)
            }
        }
        for (id, dim) in unsure { if let uuid = uuidOf[id] { _ = saved.set(dim, for: uuid) } }
        writeSaved()
        engine.restoreAll()
        redraw.nudge([])
    }

    /// A press found inside a write (`setBacklight`): one more push once this one is through.
    @ObservationIgnored private var pushAgain = false

    private func push() {
        guard !resumedAtLaunch else { return }
        defer { if pushAgain { pushAgain = false; push() } }
        var tints: [CGDirectDisplayID: Tint] = [:], stepping: Set<CGDirectDisplayID> = []
        for display in displays {
            let s = strength(display.uuid)
            guard s > 0 else { continue }
            let asked = Tint.mix(.neutral, shown, s)
            // Read before the position is worked out (unless it just was): a press since the last
            // read becomes the shift first. Read inside the write instead, the position worked out
            // from the old shift was written over the press (the morning's tail: all day). The
            // evening's first write likewise maps onto the range of the light shown now.
            if !asleep, monitors[display.id] == nil, let dim = dims[display.id], asked.brightness < 1 || dim.isDimming,
               Date().timeIntervalSince(backlightRead[display.id] ?? .distantPast) > 0.5 {
                readBacklight(display.id)
            }
            var t = adjusted(asked, for: display.id)
            let q = position(asked, for: display.id)
            // Released only when the plan itself is back at 0 (or shifts don't apply): a shift
            // that brings the screen to its day level mid-evening keeps dimming engaged, so the
            // next press is a shift, not a new day level.
            let release = asked.brightness >= 1 || !shiftsWanted
            if backlight(display.id) == nil, dims[display.id] != nil {
                requested[display.id] = (q, release)  // on the signal fallback: for the retry
            } else if dims[display.id] != nil {
                setBacklight(display.id, position: q, release: release)
                t.brightness = signalShare(display.id, position: q)
                // Not merely below 1: a monitor's step is rounded up, so its share sits a hair under
                // all evening, and the dot was flipped on every push until morning.
                if inFlight[display.id] != nil || lastShare[display.id] != t.brightness { stepping.insert(display.id) }
                lastShare[display.id] = t.brightness
            }
            tints[display.id] = t
        }
        // A display switched off in Settings gets its backlight back.
        for display in displays where tints[display.id] == nil && backlight(display.id) != nil {
            setBacklight(display.id, position: 0)
        }
        // What the screens show. Nothing pushed, nothing shown. Asleep, the tables go neutral below
        // but a dimmed backlight waits for the wake: kept dim here, so the wake fades it up.
        if !tints.isEmpty {
            if !asleep { applied = shown }
            else if tints.values.allSatisfy(\.isNeutral) {
                applied = dims.values.contains(where: \.isDimming) ? Tint(kelvin: Tint.neutral.kelvin, brightness: applied.brightness) : shown
            }
        }
        if !asleep {
            engine.apply(tints)
            // A monitor steps its own brightness at once; the signal evening it out must show now too.
            // Only while that goes on: the dot stays off screen the rest of the time (removing it
            // draws the frame that shows the last step's signal).
            redraw.nudge(resolvedEngine == .gamma ? stepping : [])
        } else if tints.values.allSatisfy(\.isNeutral) {
            // The evening ending while the screens sleep: the tables go back now, so a screen that
            // wakes (and a lid that opens) comes on neutral rather than flashing last night's tint.
            engine.apply(tints)
        }
        refreshEffective()
        repace()
    }

    /// A monitor moves a whole step at a time, a few times a second (`DDC`): until it shows the
    /// light asked for, the signal dims what it shows too much of, so fades and the hand-over
    /// from signal dimming at launch run smoothly. A step up in flight already counts as shown:
    /// the signal darkens first and the monitor brightens after, so a timing slip dips, never flashes.
    /// Not on a monitor guarded against smearing: a dimmed signal is what smears.
    private func signalShare(_ id: CGDirectDisplayID, position: Double) -> Double {
        guard monitors[id] != nil, smearFloor(for: id) == 0, let dim = dims[id] else { return 1 }
        let shown = max(dim.written ?? min(1, dim.baseline), inFlight[id] ?? 0)
        guard shown > 0 else { return 1 }
        return pow(min(1, dim.light(at: position) / shown), 1 / Kelvin.displayGamma)
    }

    private func setBacklight(_ id: CGDirectDisplayID, position: Double, release: Bool = true) {
        guard !asleep, let found = dims[id] else { return }
        requested[id] = (position, release)
        // Dimming starting here (even where nothing is written yet: `settle` records it) begins
        // from what the panel shows now, not a reading from the last tick or poll.
        let starting = !found.isDimming && position > 0
        // A backlight macOS controls is read before it's written unless it just was: undimmed its
        // baseline is only read on the tick, dimmed a key press since must be adopted, not undone.
        if monitors[id] == nil, starting || found.light(for: position, release: release) != nil,
           Date().timeIntervalSince(backlightRead[id] ?? .distantPast) > 0.5 {
            let before = shift(for: id)
            readBacklight(id)
            // The read found a press: `position` was worked out before it, from the old shift.
            // Written anyway, the old level went out a moment before the new one, and the panel
            // stayed on the old one (two writes 2 ms apart): every press undone, and the next read
            // taking that for another press, back and forth. Worked out again after this push.
            if shift(for: id) != before { pushAgain = true; return }
        }
        guard var dim = dims[id] else { return }
        // A dark reading (a panel still waking) isn't the evening's level: started from it, the
        // night had no range and went undimmed. Read again on the next push.
        if starting, monitors[id] == nil, dim.baseline <= 0.001 { return }
        if let monitor = monitors[id] {
            // One step at a time, sent in the background, the next once the monitor took this
            // one (each answer pushes again), and recorded only then: a write lost to a sleeping
            // monitor must be sent again, not assumed.
            // Not while its handle is being replaced or is in doubt (`doubtful`), nor while it
            // refuses writes before its retry (`pollBacklights` paces those; each failed write
            // costs ~200 ms of I2C).
            guard !probingIDs.contains(id), !doubtful.contains(id), inFlight[id] == nil, !readingFirst.contains(id),
                  !(monitor.isFailing && Date() < retryAt[id] ?? .distantPast) else { return }
            // The monitor is read first, and the push after the reading sends the step: when dimming
            // starts here from a reading up to 5 minutes old (idle, `pollBacklights`), and before a
            // step once the last reading is a few seconds old. Sent from the old level, a monitor
            // turned up by its buttons dropped ~30 steps, and its press was lost (the next read
            // matched the step). In a fade, once at its start (the tick's glide too): its steps
            // follow each other closely after that.
            let age = Date().timeIntervalSince(monitorReadAt[id] ?? .distantPast)
            let readSinceFade = fadeTask != nil && (monitorReadAt[id] ?? .distantPast) >= fadeBegan
            if starting ? age > 20 : !readSinceFade && age > 4 && dim.nextStep(for: position, release: release) != nil {
                return readFirst(id, monitor)
            }
            guard let (light, released) = dim.nextStep(for: position, release: release) else { return settle(&dim, at: position, on: id) }
            inFlight[id] = light
            monitor.set(fraction: light) { [weak self] ok in
                self?.monitorAnswered(id, monitor, light: light, release: released, ok: ok)
            }
            return
        }
        guard let light = dim.light(for: position, release: release) else { return settle(&dim, at: position, on: id) }
        if !dim.isDimming { dim.baselineLevel = Backlight.level(id) }
        let ending = position <= 0 && release
        let ok = if position <= 0, let level = dim.baselineLevel { Backlight.set(level: level, on: id) }
            else { Backlight.set(light: light, on: id) }
        // A failed write changes nothing: the next push tries again from what the panel shows.
        Debug.log("write \(id) position \(String(format: "%.3f", position)) light \(String(format: "%.4f", light)) ok \(ok) shift \(uuidOf[id].flatMap { shifts[$0] }.map { "\($0)" } ?? "none")")
        guard ok else { return }
        backlightWritten[id] = Date()
        dim.wrote(light, release: ending)
        store(dim, for: id)
    }

    /// Reads a monitor with nothing sent until the answer: a step queued behind the read went out
    /// from the old level, and its answer then overwrote the press the read had just adopted. The
    /// push after the answer sends the step from what the monitor shows (a fade pushes anyway).
    private func readFirst(_ id: CGDirectDisplayID, _ monitor: DDC) {
        monitorReadAt[id] = Date()
        readingFirst.insert(id)
        monitor.read { [weak self] light in
            // Only while that handle still drives `id` (a replug or a reused id since made it another screen's).
            guard let self, self.monitors[id] === monitor, self.readingFirst.remove(id) != nil else { return }
            if !self.asleep { self.observe(light, on: id) }  // a failed read (nil) changes nothing
            if self.fadeTask == nil { self.push() }
        }
    }

    /// The panel already shows `position`: dimming that starts here starts all the same
    /// (`BacklightDim.settle`), so a key press is a move, and keeps the exact slider level for the
    /// morning, as a first write does.
    private func settle(_ dim: inout BacklightDim, at position: Double, on id: CGDirectDisplayID) {
        if !dim.isDimming && position > 0 && monitors[id] == nil { dim.baselineLevel = Backlight.level(id) }
        dim.settle(at: position)
        store(dim, for: id)
    }

    private func monitorAnswered(_ id: CGDirectDisplayID, _ monitor: DDC, light: Double, release: Bool, ok: Bool) {
        guard monitors[id] === monitor else { return }  // a replaced handle's late answer
        if inFlight[id] == light { inFlight[id] = nil }
        if !ok { backOff(id) }
        guard ok, var dim = dims[id] else { return }
        retryAt[id] = nil
        retryDelay[id] = nil
        backlightWritten[id] = Date()
        dim.wrote(light, release: release)
        store(dim, for: id)
        // The next step, and the signal eased to what the monitor shows now (a running fade
        // pushes every frame anyway).
        if fadeTask == nil { push() }
    }

    /// A failed write holds the next until its retry time, 10 s doubling to 5 minutes: unpaced, a
    /// fade re-sent it every frame (~200 ms of I2C each). Only once the last one has passed.
    private func backOff(_ id: CGDirectDisplayID) {
        guard Date() >= retryAt[id] ?? .distantPast else { return }
        let delay = retryDelay[id].map { min(300, $0 * 2) } ?? 10
        retryDelay[id] = delay
        retryAt[id] = Date().addingTimeInterval(delay)
    }

    /// Every change to `dims` goes through here: unchanged values aren't written (each write
    /// redraws the popover), and the dimmed ones are saved for a launch after a crash.
    private func store(_ dim: BacklightDim, for id: CGDirectDisplayID) {
        guard dims[id] != dim else { return }
        dims[id] = dim
        refreshEffective()
        // Every display in `dims` came through `follow` or `restart`, after `uuidOf` was set.
        guard let uuid = uuidOf[id], let startedOrEnded = saved.set(dim.isDimming ? dim : nil, for: uuid) else { return }
        // Starting or ending dimming is saved at once; steps in between at most once a second
        // and at the end of a fade (a fade writes the backlight ~40 times a second).
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
        saved.write()
        if shiftSave != nil { saveShifts() }
    }

    /// Starts following a display at the light found there: the user's level, unless it is
    /// exactly what a Gloam that never got to quit left behind, whose baseline then still holds.
    private func follow(_ id: CGDirectDisplayID, uuid: String, light: Double, step: Double = 0) {
        uuidOf[id] = uuid
        if var left = saved[uuid] {
            // Before `resumes`: the floor isn't saved, and checked against the default 0.08 a
            // panel faded on to a consented 0.03 read as the user's own level, the morning's. At
            // launch the settings' consent isn't known yet (it's set just after `init`): the
            // deepest floor any consent allows decides then.
            left.step = step
            left.lightFloor = consentKnown ? lightFloor : BacklightDim.deepestFloorLight
            if saved.isRecent(uuid) ? left.resumes(at: light) : left.written.map({ left.same(light, $0) }) == true {
                // Mid-fade the panel isn't at what was saved: continue from where it is.
                if !firstTargetShown { holdForFirstTarget() }
                left.lightFloor = lightFloor
                left.resume(at: light)
                return store(left, for: id)
            }
        }
        restart(id, at: light, step: step)
    }

    /// Holds pushes until the model's first target (`resumedAtLaunch`); should none come within
    /// 3 s, what's there is pushed.
    private func holdForFirstTarget() {
        guard !resumedAtLaunch else { return }
        resumedAtLaunch = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.resumedAtLaunch else { return }
            self.resumedAtLaunch = false
            self.push()
        }
    }

    /// Follows a display afresh from the light it shows now, as its baseline.
    private func restart(_ id: CGDirectDisplayID, at light: Double, step: Double = 0) {
        var dim = BacklightDim(baseline: light, step: step)
        dim.lightFloor = lightFloor
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
        reprobing = reprobeWanted
        reprobeWanted = false
        probingIDs = Set(wanted.map(\.id))
        Task.detached { [weak self] in
            old.forEach { _ = $0.flush() }
            let (found, silent) = DDC.probe(wanted, externals: externals)
            await self?.adopt(found, silent: silent)
        }
    }

    private func adopt(_ found: [CGDirectDisplayID: DDC], silent quiet: Set<String>) {
        probing = false
        let missed = probingIDs.filter { monitors[$0] != nil && found[$0] == nil }
        probingIDs = []
        // In doubt until the reprobe; missed again there, the old handle is used as before (some
        // monitors answer writes, not probes).
        let wasReprobe = reprobing
        if reprobing {
            reprobing = false
            doubtful = []
        } else {
            doubtful = doubtful.union(missed).subtracting(found.keys)
        }
        // A monitor already followed that missed one probe keeps its handle; it isn't written off.
        // One that never answered is silent for the session only once asked twice: its DDC may not
        // be up yet (at login, just after a wake), and silent it was dimmed by signal all session.
        let followed = Set(displays.filter { monitors[$0.id] != nil }.map(\.uuid))
        let quietNow = quiet.subtracting(followed)
        if wasReprobe || reprobed { silent.formUnion(quietNow) }
        if (!missed.isEmpty || !quietNow.subtracting(silent).isEmpty) && !reprobed {
            reprobed = true
            reprobe = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                self?.reprobeWanted = true
                self?.probeMonitors()
            }
        }
        for (id, monitor) in found {
            monitors[id] = monitor
            inFlight[id] = nil
            readingFirst.remove(id)  // a read on the old handle is ignored when it lands
            monitorReadAt[id] = Date()  // the probe just read it (`initial`)
            if var dim = dims[id], let w = dim.written {
                // Back from a replug or a power cycle at the user's own level, not Gloam's: that is
                // the new baseline, dimmed again from there (recorded like any write).
                dim.step = monitor.step
                guard !dim.same(monitor.initial, w) else { continue }
                restart(id, at: monitor.initial, step: monitor.step)  // the push below dims it as asked now
            } else if var dim = dims[id] {
                // Followed but not dimmed: its level may have changed while it was away (another
                // machine, a KVM), and dimming must start from what it shows now.
                dim.step = monitor.step
                _ = dim.observe(light: monitor.initial, plan: 0, setsDayLevel: true)
                store(dim, for: id)
            } else if let uuid = displays.first(where: { $0.id == id })?.uuid {
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
        // DDC reads are slow and some links drop them, so each monitor is asked every 20 s, not
        // twice a second; every 5 minutes while the clock idles, unless one is still dimmed or
        // refusing writes: its release is retried on the next tick (a minute at most), not in 5.
        let settled = !displays.contains { d in monitors[d.id].map { $0.isFailing || dims[d.id]?.isDimming == true } ?? false }
        let monitorGap: TimeInterval = idle && settled ? 300 : 20
        var lights: [CGDirectDisplayID: Double] = [:]
        for display in displays where dims[display.id] != nil {
            let id = display.id
            if let monitor = monitors[id] {
                // Not while a probe reads it on a new handle (two queues on one monitor garble
                // replies), nor through a handle in doubt.
                guard Date().timeIntervalSince(monitorReadAt[id] ?? .distantPast) > monitorGap,
                      !probingIDs.contains(id), !doubtful.contains(id) else { continue }
                let asked = requested[id] ?? (0, true)
                if monitor.isFailing, dims[id]?.nextStep(for: asked.position, release: asked.release) == nil {
                    // Failed, but no step is due (it failed before dimming anything and the evening
                    // is over, or the panel already shows what's asked): a retry sends nothing, so
                    // the failure never cleared and the monitor went unread, its button presses
                    // unadopted (all day, once: the next evening began on the signal). Read as usual.
                    monitor.forgetFailure()
                    retryAt[id] = nil
                    retryDelay[id] = nil
                }
                if monitor.isFailing {
                    // Not read while it refuses writes; sent its level again instead (a monitor
                    // asleep at the morning restore would otherwise stay dim all day).
                    guard Date() >= retryAt[id] ?? .distantPast, let asked = requested[id] else { continue }
                    monitorReadAt[id] = Date()
                    // With its release flag: retried as a release, a shift holding the screen at its day
                    // level ended the dimming, and the next press became the day level.
                    setBacklight(id, position: asked.position, release: asked.release)  // a failed answer sets the next retry (`backOff`)
                } else if !readingFirst.contains(id) {
                    readFirst(id, monitor)
                }
            } else {
                let before = shift(for: id), written = dims[id]?.written
                lights[id] = readBacklight(id)
                // The reading was a press (a new shift or day level): `requested` is the position
                // from before it. Retried, it wrote the old level straight over every press.
                if shift(for: id) != before || dims[id]?.written != written {
                    push()
                    continue
                }
                // A write that failed (the morning restore, say) is tried again here: in the day
                // nothing else may push for hours.
                if let asked = requested[id], dims[id]?.light(for: asked.position, release: asked.release) != nil {
                    setBacklight(id, position: asked.position, release: asked.release)
                }
            }
        }
        refreshShares(lights)
    }

    /// Each built-in's share of the smear floor, from the brightness the user set (`lights`: this
    /// poll's readings), eased there over 0.6 s when it moved.
    private func refreshShares(_ lights: [CGDirectDisplayID: Double]) {
        var next: [CGDirectDisplayID: Double] = [:]
        for display in displays where display.isBuiltin {
            let id = display.id, light = lights[id] ?? Backlight.light(id)
            // The floor eases with the brightness the user set, not with Gloam's own dimming, or
            // dimming would move the warmth dial's end (and the warmth with it) under the user's
            // hand. Undimmed that is the slider read directly; while dimming, the user's level.
            if let dim = dims[id], dim.isDimming {
                if let level = userLevel(id, dim) { levelShare[id] = Schedule.backlightFactor(level) }
            } else if light != undimmed[id]?.light || Date().timeIntervalSince(levelReadAt[id] ?? .distantPast) > 60 {
                levelReadAt[id] = Date()
                let level = Backlight.level(id)
                if let level, let light { undimmed[id] = (level, light) }
                if shown.isNeutral, let light { dayLight[display.uuid] = light }
                levelShare[id] = level.map(Schedule.backlightFactor)
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
                let eased = t * t * (3 - 2 * t)  // smoothstep
                var share: [CGDirectDisplayID: Double] = [:]
                for id in ids { share[id] = (from[id] ?? 1) + ((next[id] ?? 1) - (from[id] ?? 1)) * eased }
                self.share = share
                if self.fadeTask == nil { self.push() }  // a running fade pushes every frame anyway
                if t >= 1 { return }
                try? await Task.sleep(for: .milliseconds(16), tolerance: .milliseconds(4))
            }
        }
    }

    /// Reads a backlight macOS controls and feeds it to its dimming (an outside move is adopted).
    @discardableResult private func readBacklight(_ id: CGDirectDisplayID) -> Double? {
        let light = Backlight.light(id)
        Debug.log("read \(id) \(light.map { String(format: "%.4f", $0) } ?? "nil") written \(dims[id]?.written.map { String(format: "%.4f", $0) } ?? "nil") sinceWrite \(String(format: "%.2f", Date().timeIntervalSince(backlightWritten[id] ?? .distantPast)))s")
        backlightRead[id] = Date()
        observe(light, on: id)
        return light
    }

    /// A reading of a followed display; within a second of a write it is the write itself. A move
    /// becomes the screen's shift from the plan, or its day level (`BacklightDim.Move`): in the
    /// evening's first minutes (the plan and what it shows both under `Shift.threshold`, not the
    /// morning's tail) and once the morning's plan is done. During Settings' preview (shifts off) a move is
    /// only taken as what the panel shows: measured from the preview, it landed wrong after.
    /// A dark reading in the seconds after a wake or a display change is a panel still coming on
    /// (or going off with the lid), not a light to keep: adopted while dimming, the night ended
    /// near black. Later it is the user's (the keys switch the backlight off), and kept.
    private func observe(_ light: Double?, on id: CGDirectDisplayID) {
        guard let light, var dim = dims[id],
              Date().timeIntervalSince(backlightWritten[id] ?? .distantPast) > 1,
              light > 0.001 || Date().timeIntervalSince(changedAt) > 5 else { return }
        guard shiftsWanted || !dim.isDimming else {
            dim.resume(at: light)
            return store(dim, for: id)
        }
        let plan = plan(for: id), showing = ladderPosition(id)
        // The morning's plan done, also while a late shift's fade still runs past that (`perUnit`):
        // a press then is the day level, not a shift held until the next evening.
        let fading = shift(for: id).flatMap { $0.isShrinking(clock.now) ? $0 : nil }
        let morningTail = plan <= 0 && fading != nil
        // Pressed up through a shift still fading, short of the day level: a new shift fading with
        // it, not a new day level, or pressing brighter left the day darker than not pressing.
        let upThroughFade = fading != nil && dim.written.map { light > $0 && light < min(1, dim.baseline) } == true
        let setsDayLevel = !upThroughFade && (clock.planDone || morningTail || max(plan, showing) < Shift.threshold && !clock.inMorning)
        let move = dim.observe(light: light, plan: clock.planDone || morningTail ? 0 : plan, setsDayLevel: setsDayLevel)
        Debug.log("observe \(id) light \(String(format: "%.4f", light)) plan \(String(format: "%.3f", plan)) showing \(String(format: "%.3f", showing)) setsDay \(setsDayLevel) -> \(move) baseline \(String(format: "%.4f", dim.baseline))")
        store(dim, for: id)
        guard let uuid = uuidOf[id] else { return }
        switch move {
        case .none: return
        case .shift(let to):
            shiftFades[uuid]?.cancel()
            shiftFades[uuid] = nil
            let chosen = newShift(to: to, plan: shiftPlan(plan, for: id))
            // In the morning's tail it fades with the shift it replaces, not into the next evening.
            shifts[uuid] = upThroughFade && clock.planDone ? fading.flatMap {
                Shift.make(to: to, at: shiftPlan(plan, for: id), now: clock.now, until: $0.until) } : chosen
        case .dayLevel:
            shiftFades[uuid]?.cancel()
            shiftFades[uuid] = nil
            shifts[uuid] = nil
        }
        // Saved at once, not debounced as a fade's frames are: a press is rare, and one lost to a
        // crash within the second was written back at the relaunch.
        saveShifts()
        refreshEffective()
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
    /// changes): handled once, together, 250 ms after the last.
    private func displaysChangedSoon() {
        quietUntil = Date().addingTimeInterval(10)
        changedAt = Date()
        // After a wake or replug a monitor's I2C service is a new one, and writes through the old
        // handle "succeed" into nothing: none until the probe answers (`adopt`).
        doubtful.formUnion(monitors.keys)
        // A screen back with a tint an earlier change left (lid opened in the morning) is cleared
        // as it arrives, not 250 ms later on screen. Not while tinting: the push puts tonight's on.
        if shown.isNeutral { engine.settleKept() }
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
        // The same screen back under a new id (a replug, a wake): the old entry goes, the new one
        // is followed from the saved state. Screens that went away keep theirs, for the morning.
        // An id now naming another screen goes the same way. `saved` keeps every screen's entry.
        let current = Dictionary(displays.map { ($0.id, $0.uuid) }, uniquingKeysWith: { a, _ in a })
        for id in staleFollows(followed: uuidOf, current: current) {
            dims[id] = nil
            monitors[id] = nil
            requested[id] = nil
            inFlight[id] = nil
            readingFirst.remove(id)
            monitorReadAt[id] = nil
            uuidOf[id] = nil
        }
        // Normally cleared by the screens' wake; also here, so a missed notification can't stop
        // backlights being read for good.
        wakeIfMissed()
        retryAt = [:]
        retryDelay = [:]
        levelReadAt = [:]
        reprobe?.cancel()
        reprobed = false
        reprobeWanted = false
        reprobing = false
        doubtful = Set(monitors.keys)  // until the probe below answers for each
        silent.subtract(displays.map(\.uuid).filter { !known.contains($0) })  // reconnected: ask again
        engine.displaysChanged()
        redraw.displaysChanged()
        // A screen macOS dims back after an unplug or power cycle at its own level, not Gloam's:
        // that level is the new baseline (as `adopt` does for monitors). Read as a key press it
        // scaled the baseline up, and the morning restore could go to full brightness.
        // A built-in back from clamshell keeps its panel's level but may read a little off it, or
        // be mid-ramp: anywhere on tonight's curve is still Gloam's (restarted there, the night
        // became the day's level).
        for display in displays where !known.contains(display.uuid) && monitors[display.id] == nil {
            guard let dim = dims[display.id], let w = dim.written, let light = Backlight.light(display.id), light > 0.001,
                  !(display.isBuiltin ? dim.resumes(at: light) : dim.same(light, w)) else { continue }
            restart(display.id, at: light)
        }
        adoptBacklights()
        pollBacklights()
        push()
        displaysDidChange()
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
