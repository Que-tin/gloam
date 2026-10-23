// Owns the active engine and moves the screen toward a target tint: eased fades for user
// actions, direct writes for the clock's small steps (writes are skipped when nothing changed).
// On each clock tick it checks whether the tint was overwritten (or left black) and only then
// writes it again, because macOS quietly resets gamma tables on wake, display changes and some
// ColorSync events.
// Displays whose backlight macOS controls (built-in, Apple displays) and reports on
// (`BrightnessEvents`) or never moves itself (no auto-brightness: read on the tick), and monitors
// that answer DDC/CI, are dimmed by backlight, relative to the level found there (`BacklightDim`);
// the rest by signal. Each screen shows the plan (the target tint) plus its own shift (`Shift`): the
// brightness keys, its buttons, or the ladder moved it away from the plan tonight; the dial's
// warmth shift applies to every screen, on each one's own warm range. A dimmed backlight
// outlives the process (gamma tables don't), so what each one was dimmed from is saved as it
// changes (`SavedDims`), and a launch after a crash puts it back.
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
    /// Puts back a table left black; true when it did (`GammaEngine.repairBlank`).
    func repairBlank() -> Bool
    /// The display's linear RGB, for estimates that should match what it really shows.
    func colourSpace(_ id: CGDirectDisplayID) -> LinearRGB
}

extension TintEngine {
    func isOverwritten() -> Bool { false }
    func repairBlank() -> Bool { false }
    func restoreAll() { reset() }
    func settleKept() {}
    func colourSpace(_ id: CGDirectDisplayID) -> LinearRGB { Kelvin.sRGB }
}

@Observable
final class DisplayController {
    /// The plan Gloam shows, where the screens are going: each display shows it with its shifts,
    /// eased there (`animate`).
    private(set) var shown = Tint.neutral
    private(set) var displays: [DisplayInfo] = Displays.current()
    /// Something else keeps rewriting the screen's colours, so it and Gloam take turns.
    /// Detected, not guessed from a list of app names: it works for any app.
    private(set) var interference = false
    @ObservationIgnored private var overwrites: [Date] = []
    /// macOS usually resets gamma tables itself just after a wake or reconfiguration; those resets are
    /// not another app and must not count toward the interference notice.
    @ObservationIgnored private var quietUntil = Date.distantPast
    /// Whether a display (by UUID) is tinted: Settings › Displays can leave one alone.
    @ObservationIgnored private(set) var tinted: (String) -> Bool = { _ in true }
    /// External displays (by UUID) held to the smear floor at the user's request. Their backlight
    /// can't be read, so for them the floor doesn't ease. Built-in displays are always held.
    @ObservationIgnored private(set) var smearGuarded: (String) -> Bool = { _ in false }

    /// Settings' per-display switch and smear guard, applied with one push (each its own push
    /// wrote every screen twice per change).
    func configure(tinted: @escaping (String) -> Bool, smearGuarded: @escaping (String) -> Bool) {
        self.tinted = tinted
        self.smearGuarded = smearGuarded
        // A screen switched off in Settings loses tonight's shift: kept, it came back when the
        // screen was switched on again and wrote a press made meanwhile straight back.
        let live = shifts.filter { tinted($0.key) }
        if live.count != shifts.count {
            shifts = live
            saveShifts()
        }
        push()
    }
    /// Told after the screens change: a new one can end the model's quiet (all others at 0).
    @ObservationIgnored var displaysDidChange: () -> Void = {}
    /// How far the user's settings go past the recommended night (`Schedule.pastRecommended`):
    /// their consent to what deeper costs. Warmth eases the smear floor away (none at ember),
    /// dimming eases the backlight's light floor down to its deepest (`BacklightDim.floor`).
    var consent: (warmth: Double, dimming: Double) = (0, 0) {
        didSet {
            consentKnown = true
            if consent != oldValue { refreshFloors() }
        }
    }
    /// The room's light (lux, smoothed; nil: no sensor, or the room left out): where a panel's
    /// luminance is known its floor follows the room (`BacklightDim.floorNits`).
    var roomLux: Double? {
        didSet { if roomLux != oldValue { refreshFloors() } }
    }
    /// Each panel's luminance at full brightness, where macOS reports it (`BrightnessEvents.maxNits`).
    @ObservationIgnored private var maxNits: [CGDirectDisplayID: Double] = [:]
    /// The share of daylight white's light each backlight's tint leaves (warmth takes light from
    /// white): the floor is on the white seen (`BacklightDim.floor`).
    @ObservationIgnored private var whiteShare: [CGDirectDisplayID: Double] = [:]

    private func lightFloor(_ id: CGDirectDisplayID) -> Double {
        BacklightDim.floor(maxNits: maxNits[id], lux: roomLux, consent: consent.dimming, white: whiteShare[id] ?? 1)
    }

    /// Every backlight's floor set afresh (consent or the room changed).
    private func refreshFloors() {
        for id in dims.keys { setFloor(id) }
        push()
    }

    /// A backlight's floor set to what's due now. Moved far enough to see (the room-light switch,
    /// the lid closing, consent), the screen eases there from the light it shows over 2 s: pushed
    /// at once, a 40 → 25 cd/m² floor was a step. True when it eases (the caller's levels moved).
    @discardableResult private func setFloor(_ id: CGDirectDisplayID) -> Bool {
        guard var dim = dims[id] else { return false }
        let floor = lightFloor(id)
        guard abs(floor - dim.lightFloor) > 1e-6 else { return false }
        // A shift below the floor keeps the light it shows: the same position on a lower floor was
        // darker than what was pressed. Moved by the difference, so its distance from the plan
        // (and its morning) stay its own. Not before the first target: at launch the saved shifts
        // were taken on the consent being set now.
        let uuid = uuidOf[id], plan = shiftPlan(for: id)
        let shift = uuid.flatMap { shifts[$0] }
        let below = firstTargetShown ? shift.map { $0.position(plan: plan, now: clock.now) }.flatMap { $0 > 1 ? $0 : nil } : nil
        let pressedLight = below.map { dim.light(at: $0) }
        let now = levelsNow(id), was = dim.light(at: now.position)
        dim.lightFloor = floor
        store(dim, for: id)
        if let uuid, let shift, let below, let pressedLight {
            shifts[uuid] = shift.moved(by: dim.position(of: pressedLight) - below)
        }
        // Not over an ease already running (a warmth fade moves the floor on every frame): restarted
        // each time, it stretched and reshaped that fade.
        guard dim.isDimming, firstTargetShown, motions[id] == nil,
              !BacklightDim.unseen(dim.light(at: levelsNow(id).position), was) else { return false }
        animate([id], over: 2, from: [id: Levels(position: dim.position(of: was), warmth: now.warmth)])
        return true
    }

    /// How much of daylight white's light a backlight's tint leaves at `warmth`, the smear floor's
    /// limit included; to 1/200, so the floor isn't set afresh on every frame of a warmth fade.
    private func whiteLeft(_ warmth: Double, on id: CGDirectDisplayID) -> Double {
        let space = engine.colourSpace(id)
        let kelvin = Smear.limited(Tint(kelvin: kelvin(share: warmth, on: id)), floor: smearFloor(for: id), in: space).kelvin
        return (Smear.luminance(Tint(kelvin: kelvin), in: space) * 200).rounded() / 200
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
    /// Settings' "Preview tonight" is on: the shifts show on it, but no press makes a new one.
    @ObservationIgnored var previewing = false
    /// Off or paused, every screen shows the plan alone (the model's neutral); Settings' preview
    /// shows them, as tonight will. Set by the model before its `show`, which eases the shifts out
    /// or in with the tint (`shiftsShown`): switched at once, a pause first jumped by the shift.
    /// Coming back (a pause ended, the preview closed) in the morning, a shift already shrinking
    /// goes: faded back in, a pause "Until Morning" ending at wake dimmed the screen again.
    @ObservationIgnored var shiftsWanted = true {
        didSet {
            guard shiftsWanted, !oldValue else { return }
            let live = shifts.filter { !$0.value.isShrinking(clock.now) }
            if live.count != shifts.count { shifts = live }
            if warmthShift?.isShrinking(warmthClock.now) == true { warmthShift = nil }
        }
    }
    /// The shifts show (`shiftsWanted` as of the last `show`): set there with the plan, so both
    /// ease as one. From false: a launch fades the shifts in with the plan (shown at once, a saved
    /// shift showed alone before the plan came).
    @ObservationIgnored private var shiftsShown = false
    /// The dial's warmth shift, one for every screen: each takes it on its own warm range
    /// (`warmthShare`), so it moves a MacBook's screen as far along what it can show as a
    /// monitor's. It rides along with the evening and shrinks to nothing with the morning, after
    /// which it goes, so a tweak never quietly becomes the new every-night. Saved with the
    /// screens' shifts.
    @ObservationIgnored private(set) var warmthShift: Shift? = DisplayController.loadWarmth() {
        didSet { if warmthShift != oldValue { saveShiftsSoon() } }
    }
    /// What a warmth shift chosen now belongs to: its morning ends with the plan's warmth, which
    /// can end apart from its dimming (`Schedule.morningEnd`). Set by the model before `clock`.
    @ObservationIgnored var warmthClock = ShiftClock.idle
    /// The model's clock and what a shift chosen now belongs to (`ShiftClock`): set by the model,
    /// about once a second. Shifts move with it in the morning while the plan may stand still
    /// (neutral already, its fade-out under way): pushed then, or they waited for their expiry.
    @ObservationIgnored var clock = ShiftClock.idle {
        didSet {
            guard animator == nil else { return }
            if shifts.values.contains(where: { $0.isShrinking(clock.now) }) || warmthShift?.isShrinking(warmthClock.now) == true { push() }
        }
    }
    /// Each built-in display's share of the smear floor (`Schedule.backlightFactor`) from its
    /// slider; read on the tick and with a reported move, not per fade frame. Missing means all of it. Eased
    /// there over 0.6 s when it moves while tinted (`shareEase`, `floorShare`): taken at once, the
    /// warmth jumped with a key press (read as Gloam fighting the key) and the dial's knob dipped.
    private var share: [CGDirectDisplayID: Double] = [:]
    @ObservationIgnored private var shareEase: (from: [CGDirectDisplayID: Double], start: TimeInterval)?
    private func floorShare(_ id: CGDirectDisplayID) -> Double {
        let goal = share[id] ?? 1
        guard let ease = shareEase else { return goal }
        let t = min(1, (Self.uptime - ease.start) / 0.6)
        let from = ease.from[id] ?? 1
        return from + (goal - from) * t * t * (3 - 2 * t)
    }
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
    /// A built-in's slider level is a second call per read; it moves only with the light, so it
    /// is read when the light reading moved, or once a minute (the light can be capped while the
    /// slider moves). The factor from the last read is kept for the reads in between. Only read
    /// while Gloam isn't dimming; while it is, the smear floor follows the level the user set
    /// (`userLevel`), not Gloam's own dimming below it.
    @ObservationIgnored private var levelReadAt: [CGDirectDisplayID: Date] = [:]
    @ObservationIgnored private var levelShare: [CGDirectDisplayID: Double] = [:]
    /// The screens are asleep (the Mac may not be): backlight readings then can be 0 or the
    /// idle-dim level, and adopting one would make it the morning's level. No backlight is read or
    /// written; a tint is only cleared (`push`), so a screen wakes neutral after the evening.
    @ObservationIgnored private var asleep = false
    /// A reading within a second of a write is the write itself, not an outside move (a monitor,
    /// a backlight read on the tick); writes also keep 11 ms apart (`setBacklight`).
    @ObservationIgnored private var backlightWritten: [CGDirectDisplayID: Date] = [:]
    /// The backlights macOS reports on (`BrightnessEvents`), with what its reports mean
    /// (`BacklightReports`): read when it says they moved, never polled. One it doesn't (no
    /// reports on this macOS, or they stopped) is read on the tick where macOS never moves it
    /// itself (`readOnTick`), else dimmed by signal.
    @ObservationIgnored private var reports: [CGDirectDisplayID: BacklightReports] = [:]
    /// Unreported backlights with no auto-brightness: any change Gloam didn't write is the user's.
    @ObservationIgnored private var readOnTick: Set<CGDirectDisplayID> = []
    /// Backlights whose reports stopped (`reportsBroke`): their `reports` stay, still told of every
    /// write, so the report that brings them back isn't taken for a move (the release's own "user"
    /// report, a late echo). Started afresh, those became a press, or the new day level.
    @ObservationIgnored private var quiet: Set<CGDirectDisplayID> = []
    /// The push that ends a move's hold (`reported`): its own task, as `pushLater` keeps the first
    /// of several and a frame's push due sooner swallowed it.
    @ObservationIgnored private var holdPush: Task<Void, Never>?
    /// macOS reports this backlight's moves now.
    private func heard(_ id: CGDirectDisplayID) -> Bool { reports[id] != nil && !quiet.contains(id) }
    /// How long a dimmed screen takes to settle back from where auto-brightness put it: a gentle
    /// adjustment after macOS's own ramp rather than a second step.
    static let afterMacOS = 4.0

    /// Light text on a dark background smears on built-in LCD panels once the white they draw is
    /// dim, whether the signal was dimmed or warmed (`Smear`). Measured on an XDR panel at a
    /// bright backlight: clean with the signal at 80% (61% of the light), heavy at 55%. The floor
    /// is on the luminance of the tinted white, and it eases with the user's slider: trails fade at
    /// a low backlight, measured on one panel (docs/science.md). Deeper evenings are
    /// the backlight's.
    static let smearFloor = pow(0.8, Kelvin.displayGamma)

    /// What each display shows after its shifts and its light and smear floors, live through
    /// fades: the popover's glow, for the screen it is open on. Stored, and set only when it
    /// changes: the popover reads it many times a redraw, and a computed value redrew it on every
    /// unrelated change.
    private(set) var effectives: [CGDirectDisplayID: Tint] = [:]
    func effective(on id: CGDirectDisplayID) -> Tint { effectives[id] ?? effectives[main] ?? .neutral }
    /// The main display, kept from the last display change: `CGMainDisplayID` and
    /// `CGDisplayIsBuiltin` are WindowServer round-trips, and the popover asks per frame.
    @ObservationIgnored private var main = CGMainDisplayID()

    /// The backlight dimming in force for a display. None for a monitor that stopped taking
    /// writes before it was dimmed: its evening falls back to the signal rather than not happening.
    private func backlight(_ id: CGDirectDisplayID) -> BacklightDim? {
        guard let dim = dims[id] else { return nil }
        if let monitor = monitors[id] { return dim.isDimming || !monitor.isFailing ? dim : nil }
        // Unreported with auto-brightness on: by signal (`push` releases it).
        return heard(id) || readOnTick.contains(id) ? dim : nil
    }

    /// The smear floor in force: all of it on a built-in (eased by the user's slider, `share`) or
    /// a monitor that opted in, less as Warmest goes past the recommended night (`consent`).
    private func smearFloor(for id: CGDirectDisplayID) -> Double {
        // Showcase runs (the README's pictures) show a plain monitor, whichever screen is main:
        // a built-in's floor made them differ from Mac to Mac.
        guard !Debug.isShowcase, let display = displays.first(where: { $0.id == id }) else { return 0 }
        let accepted = 1 - consent.warmth
        if display.isBuiltin { return Self.smearFloor * floorShare(id) * accepted }
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

    /// What a display will show for `tint`, after its shifts and its light and smear floors.
    func onScreen(_ tint: Tint, _ id: CGDirectDisplayID) -> Tint {
        adjusted(levels(tint, for: id, shifted: shiftsShown), for: id)
    }
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
        displays.contains { $0.id == id && tinted($0.uuid) } && darkest(id) < 0.999
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
        // Each as tinted as its own setting (Settings › Displays) has it: switched off there,
        // the orb, its glow and the blue-light reading show an untinted screen.
        var all: [CGDirectDisplayID: Tint] = [:]
        for display in displays { all[display.id] = adjusted(levelsNow(display.id), for: display.id) }
        if all != effectives { effectives = all }
    }

    /// What a display shows, on the popover's two scales: its dimming position (the ladder's) and
    /// its warmth as a share of its own warm range (the dial's), the plan for it plus its shifts.
    /// Eased as one (`animate`).
    private struct Levels: Equatable {
        var position, warmth: Double
        static let untinted = Levels(position: 0, warmth: 0)
    }

    /// A display's levels for `tint`, the plan for it (`forScreen`), with its shifts if `shifted`.
    private func levels(_ tint: Tint, for id: CGDirectDisplayID, shifted: Bool) -> Levels {
        Levels(position: position(tint, for: id, shifted: shifted),
               warmth: warmth(tint.kelvin, for: id, shifted: shifted))
    }

    /// Where a display is going: the plan with its shifts, if they show.
    private func goal(_ id: CGDirectDisplayID) -> Levels { levels(forScreen(shown, id), for: id, shifted: shiftsShown) }

    /// What a display shows this instant: its goal, or on the way there (`motions`).
    private func levelsNow(_ id: CGDirectDisplayID) -> Levels {
        let to = goal(id)
        guard let m = motions[id] else { return to }
        let e = m.eased(at: Self.uptime)
        return Levels(position: m.from.position + (to.position - m.from.position) * e,
                      warmth: m.from.warmth + (to.warmth - m.from.warmth) * e)
    }

    /// The plan as this display takes it: none where Settings leaves it alone.
    private func forScreen(_ tint: Tint, _ id: CGDirectDisplayID) -> Tint {
        displays.first(where: { $0.id == id }).map { tinted($0.uuid) } ?? true ? tint : .neutral
    }

    /// What this display shows at `levels`: its position taken the same share of the way to its
    /// own darkest, by backlight or by signal, its warmth, and never under the smear floor, which
    /// on a backlight display can only ease warmth. As a signal brightness either way (the orb's
    /// reading is worked out from it).
    private func adjusted(_ levels: Levels, for id: CGDirectDisplayID) -> Tint {
        let floor = smearFloor(for: id), space = engine.colourSpace(id), q = levels.position
        let kelvin = self.kelvin(share: levels.warmth, on: id)
        guard let dim = backlight(id) else {
            let here = Tint(kelvin: kelvin, brightness: 1 - min(1, q) * (1 - darkest(id)))
            return Smear.limited(here, floor: floor, in: space)
        }
        let top = min(1, dim.baseline)
        let brightness = top > 0 ? pow(dim.light(at: q) / top, 1 / Kelvin.displayGamma) : 1
        return Tint(kelvin: Smear.limited(Tint(kelvin: kelvin), floor: floor, in: space).kelvin, brightness: brightness)
    }

    // MARK: Warmth

    /// How far along the dial's whole scale (`Light.warmth`) a display can warm: its smear limit at
    /// full brightness, 1 where nothing limits it. The dial's 100 % on that screen: on the fixed
    /// scale a MacBook's limit sat a quarter of the way along, and the rest of the dial did nothing.
    private func warmRange(_ id: CGDirectDisplayID) -> Double {
        let floor = smearFloor(for: id)
        if let known = warmRanges[id], known.floor == floor { return known.range }
        let range = Light.warmth(max(Stage.kelvinRange.lowerBound,
                                     Smear.warmest(brightness: 1, floor: floor, in: engine.colourSpace(id))))
        warmRanges[id] = (floor, range)
        return range
    }
    /// `warmRange` by display, for the smear floor it was found at: a search asked several times a
    /// frame in a fade. Cleared with the colour spaces (`engine.displaysChanged`).
    @ObservationIgnored private var warmRanges: [CGDirectDisplayID: (floor: Double, range: Double)] = [:]
    /// A warmth as a share of this display's warm range, at most 1: a plan warmer than the screen
    /// can show sits at its end, as the screen shows it.
    func warmthShare(_ kelvin: Double, on id: CGDirectDisplayID) -> Double {
        let range = warmRange(id)
        return range > 0.001 ? min(1, Light.warmth(kelvin) / range) : 0
    }
    /// The warmth at `share` of this display's warm range.
    func kelvin(share: Double, on id: CGDirectDisplayID) -> Double {
        Light.kelvin(warmth: min(1, max(0, share)) * warmRange(id))
    }

    /// The warmth a display shows for the plan's `kelvin`, as a share of its range: with the
    /// dial's shift if `shifted`.
    private func warmth(_ kelvin: Double, for id: CGDirectDisplayID, shifted: Bool) -> Double {
        let p = warmthShare(kelvin, on: id)
        guard shifted, let warmthShift else { return p }
        return min(1, max(0, warmthShift.position(plan: p, now: clock.now)))
    }

    /// The plan's share of this display's warm range where the screens are going: what a turn of
    /// the dial is measured from, as the dial shows it while turned (`dialPosition`). Measured
    /// from the model's plan, a moment newer, the knob stopped short of the turn: at the end of
    /// the dial every further drag event was a new detent.
    func dialPlan(_ id: CGDirectDisplayID) -> Double {
        warmthShare(forScreen(shown, id).kelvin, on: id)
    }

    /// The warmest plan share among the tinted screens, for `plan`: a dial shift to 0 from there
    /// holds every screen at daylight (`AppModel.takeOverFromOff`).
    func warmestShare(_ plan: Tint) -> Double {
        displays.filter { tinted($0.uuid) }.map { warmthShare(plan.kelvin, on: $0.id) }.max() ?? 0
    }

    /// The dial's position on this screen's warm range, as it shows now. `heading`: where it is
    /// going, while it is being turned. `asked`: that plan with the shift (Settings' preview).
    func dialPosition(_ id: CGDirectDisplayID, asked: Tint? = nil, heading: Bool = false) -> Double {
        if let asked { return warmth(forScreen(asked, id).kelvin, for: id, shifted: true) }
        return (heading ? goal(id) : levelsNow(id)).warmth
    }

    /// The dial's shift moves at least `threshold` on some tinted screen ("Manual").
    func warmthShows(threshold: Double) -> Bool {
        guard let warmthShift else { return false }
        return displays.contains { d in
            guard tinted(d.uuid) else { return false }
            return abs(warmthShift.offset(plan: dialPlan(d.id), now: clock.now)) >= threshold
        }
    }

    /// The dial turned to `w` on screen `id`'s warm range: a shift from the plan's share of it
    /// there (`dialPlan`), eased there briefly.
    func turnDial(_ id: CGDirectDisplayID, to w: Double) {
        let c = warmthClock
        setWarmthShift(Shift.make(to: w, at: c.planDone ? 0 : dialPlan(id), now: c.now, until: c.until), over: 0.15)
    }

    private func setWarmthShift(_ new: Shift?, over duration: Double) {
        guard new != warmthShift else { return }
        animate(displays.map(\.id), over: duration)
        warmthShift = new
        push()
    }

    /// The position a display shows for `tint`, its plan: with its shift if `shifted`. Past 1
    /// (below the floor, a key press's) only on a backlight.
    private func position(_ tint: Tint, for id: CGDirectDisplayID, shifted: Bool) -> Double {
        let plan = Light.dimming(tint.brightness)
        guard shifted, let shift = shift(for: id) else { return plan }
        let q = shift.position(plan: shiftPlan(plan, for: id), now: clock.now)
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

    /// The plan's position for a display, where the screens are going (not mid-ease): what a move
    /// there is measured from, a key press included (the ease carries on around it, `pressed`).
    private func plan(for id: CGDirectDisplayID) -> Double {
        Light.dimming(forScreen(shown, id).brightness)
    }

    // MARK: Shifts

    /// The ladder's position for a screen: the plan plus its shift as they show now, so the
    /// ladder glides with switching on and off and with Auto (the plan where the fade was heading
    /// with the shift as it showed mid-way made it jump part-way first). Past 1 when a press took
    /// it below the floor (`DimmingLadder.beyond`); the ladder shows 100 % there. `asked`: that tint with
    /// the shift in full, for Settings' preview (the screens show the preview, not the plan).
    func ladderPosition(_ id: CGDirectDisplayID, asked: Tint? = nil) -> Double {
        // The ladder's own move, where it is heading until the screen gets there: read from the
        // screen, a step still showed the old cell, so its detent never came and a drag kept
        // restarting the fade.
        if motions[id]?.byLadder == true { return goal(id).position }
        guard let asked else { return levelsNow(id).position }
        let p = shiftPlan(Light.dimming(forScreen(asked, id).brightness), for: id)
        return min(backlight(id) == nil ? 1 : 2, max(0, shift(for: id)?.position(plan: p, now: clock.now) ?? p))
    }

    /// The ladder moved with the popover open on this screen: its shift, eased there briefly.
    func shift(_ id: CGDirectDisplayID, to position: Double) {
        guard let uuid = uuidFor(id) else { return }
        Debug.log("ladder \(id) to \(String(format: "%.3f", position)) plan \(String(format: "%.3f", shiftPlan(for: id)))")
        animate([id], over: 0.15, ladder: true)
        shifts[uuid] = newShift(to: position, plan: shiftPlan(for: id))
        push()
    }

    /// A control moved while Gloam is off: every tinted screen holds what it shows now, undimmed
    /// and at daylight, against the plan it is about to show (`plan`), so switching on changes
    /// nothing on screen; the control's own move follows (`AppModel.takeOverFromOff`). The dial's
    /// shift to 0 from the warmest screen's plan holds them all at daylight.
    func startFromOff(plan: Tint) {
        for display in displays where tinted(display.uuid) {
            let p = shiftPlan(Light.dimming(plan.brightness), for: display.id)
            shifts[display.uuid] = newShift(to: 0, plan: p)
        }
        let c = warmthClock
        warmthShift = Shift.make(to: 0, at: c.planDone ? 0 : warmestShare(plan), now: c.now, until: c.until)
        saveShifts()
    }

    /// Every shift gone at once: Gloam switched on again after an off by hand, when none shows.
    func dropShifts() {
        guard !shifts.isEmpty || warmthShift != nil else { return }
        shifts = [:]
        warmthShift = nil
        saveShifts()
    }

    /// Every screen and the warmth back on the plan ("Auto"), eased over half a second.
    func clearShifts() {
        animate(displays.map(\.id), over: 0.5)
        shifts = [:]
        warmthShift = nil
        push()
    }

    /// Shifts whose morning has ended go, whether or not Gloam saw it (asleep, quit, the lid shut).
    func expireShifts() {
        let live = shifts.filter { !$0.value.expired(clock.now) }
        let warmth = warmthShift.flatMap { $0.expired(warmthClock.now) ? nil : $0 }
        guard live.count != shifts.count || warmth != warmthShift else { return }
        warmthShift = warmth
        Debug.log("expired shifts \(Set(shifts.keys).subtracting(live.keys)) at \(clock.now)")
        shifts = live
        push()
    }

    /// Some screen shows a shift that moves it at least half a ladder step: "Manual". Screens
    /// that aren't there or aren't tinted don't count.
    var showsShift: Bool {
        displays.contains { display in
            guard tinted(display.uuid), let shift = shifts[display.uuid] else { return false }
            return abs(shift.offset(plan: shiftPlan(for: display.id), now: clock.now)) >= 0.025
        }
    }

    /// A shift chosen now: tonight's until the morning is done; after it, the coming evening's.
    /// None where it sits on the plan.
    private func newShift(to position: Double, plan: Double) -> Shift? {
        Shift.make(to: position, at: plan, now: clock.now, until: clock.until)
    }

    /// Bedtime or wake moved tonight: shifts belonging to this evening end with its new morning.
    /// `old`: the clocks' ends before the change (`clock`, `warmthClock` hold the new ones).
    func retimeShifts(from old: (dimming: Date, warmth: Date)) {
        guard old.dimming != clock.until || old.warmth != warmthClock.until else { return }
        shifts = shifts.mapValues { $0.retimed(from: old.dimming, to: clock.until, now: clock.now) }
        warmthShift = warmthShift?.retimed(from: old.warmth, to: warmthClock.until, now: warmthClock.now)
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
        UserDefaults.standard.set(warmthShift.flatMap { try? JSONEncoder().encode($0) }, forKey: "warmthShift")
    }

    private static func loadWarmth() -> Shift? {
        UserDefaults.standard.data(forKey: "warmthShift").flatMap { try? JSONDecoder().decode(Shift.self, from: $0) }
    }

    private static func loadShifts() -> [String: Shift] {
        UserDefaults.standard.data(forKey: "dimShifts").flatMap { try? JSONDecoder().decode([String: Shift].self, from: $0) } ?? [:]
    }

    @ObservationIgnored private var engine: TintEngine
    @ObservationIgnored private let redraw = Redraw()
    @ObservationIgnored private(set) var resolvedEngine: Engine
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
        } + [Task { [weak self] in
            let profiles = Notification.Name("com.apple.ColorSync.DisplayProfileNotification")
            for await _ in DistributedNotificationCenter.default().notifications(named: profiles) { self?.profileChanged() }
        }]
    }

    /// A display's colour profile changed (Displays settings, a calibration): its calibration is
    /// captured afresh under the tint. Not a whole display change, which puts the monitors in doubt
    /// and probes them again (a ColorSync restore posts this too).
    private func profileChanged() {
        engine.displaysChanged()
        warmRanges = [:]
        push()
    }

    /// Screens off (the Mac may stay awake for hours): no backlight is read or written, a tint only
    /// to clear it (`push`). macOS usually resets the tables on wake, and the wake pushes anyway.
    /// The monitors' handles are put in doubt by `displaysChangedSoon`, which the same wake
    /// notification calls.
    private func screens(asleep: Bool) {
        if self.asleep && !asleep { return woke() }
        self.asleep = asleep
        changedAt = Date()
    }

    private func woke() {
        asleep = false
        changedAt = Date()
        // A reprobe still out answers for before the wake: its answer mustn't clear the doubt.
        reprobing = false
        // A move under way when the screens slept isn't one now.
        for id in reports.keys { reports[id] = BacklightReports() }
        BrightnessEvents.rewatch()
        easeFromApplied()
    }

    /// What the screens last showed (`rendered`, kept while they slept) eases to what's due now:
    /// the evening moved on while they were off, and the push after the wake snapped it there.
    private func easeFromApplied() {
        animate(displays.map(\.id).filter { rendered[$0] != nil && rendered[$0] != goal($0) }, over: 1.5, from: rendered)
        push()
    }

    /// The routine read, on the clock's tick (every 5 s while anything is tinted or due, every
    /// minute idle): monitors' buttons are adopted, failed writes retried. `idle` (the slow tick)
    /// also slows the monitors' reads.
    func tickBacklights(idle: Bool) {
        self.idle = idle
        wakeIfMissed()
        pollBacklights()
    }

    /// The screens' wake can go missing (the model checks too): asleep for good, nothing was
    /// written all evening.
    private func wakeIfMissed() {
        guard asleep, CGDisplayIsAsleep(main) == 0 else { return }
        // As a wake heard: the monitors' handles are in doubt until a probe finds them again.
        displaysChangedSoon()
        woke()
    }
    /// The clock ticks slowly: nothing tinted, nothing due within the minute and a bit.
    @ObservationIgnored private var idle = false

    /// Reasserts the tint only when something overwrote it (macOS on some ColorSync events, or
    /// another tinting app); called on the clock's tick. Untinted there is nothing to reassert,
    /// and an interference notice still up is left to clear.
    func keepAlive() {
        // Not in the seconds after a wake or a change: tables are briefly black while macOS settles.
        if !asleep, Date().timeIntervalSince(changedAt) > 5, engine.repairBlank() { push() }
        // A shift held by day tints a signal-dimmed screen with the plan neutral: reasserted too.
        guard animator == nil, !asleep, interference || !shown.isNeutral
                || shiftsShown && (!shifts.isEmpty || warmthShift != nil) else { return }
        if noteInterference() { push() }
    }

    /// A fade (from a user action) is under way; clock ticks wait rather than cut it short.
    var isFading: Bool { animator != nil }

    func use(_ choice: Engine) {
        engine.reset()
        overwrites = []  // the overlay ends the tug of war: the notice goes with it
        interference = false
        resolvedEngine = Self.resolve(choice)
        engine = Self.make(resolvedEngine)
        push()
    }

    /// Fade to `target` over `duration` seconds, from what each screen shows now (`animate`). A
    /// new target mid-way retargets the running ease instead of restarting it: a drag sends ~120
    /// targets a second, and restarting each time meant the fade never got past its first frame.
    func show(_ target: Tint, duration requested: Double) {
        firstTargetShown = true
        if resumedAtLaunch {
            // Pushed even if it equals `shown` (neutral by day): the held pushes never ran, and a
            // backlight resumed dimmed must be released, or it stayed at last night's level.
            resumedAtLaunch = false
            motions = [:]
            shown = target
            shiftsShown = shiftsWanted
            return push()
        }
        guard target != shown || shiftsWanted != shiftsShown else { return }
        Debug.log("show plan \(String(format: "%.3f", Light.dimming(target.brightness))) shifts \(shiftsWanted) over \(requested)s")
        let from = Dictionary(displays.map { ($0.id, levelsNow($0.id)) }, uniquingKeysWith: { a, _ in a })
        shown = target
        shiftsShown = shiftsWanted
        // A monitor takes about a step every 0.1 s: a fade shorter than its steps left the last
        // ones landing after the signal had stopped, each a visible dip. Half again for the eased
        // middle, where the fade outruns the steps. Drags (short fades) keep their pace.
        let duration = requested >= 0.3 ? max(requested, 0.15 * monitorSteps()) : requested
        // Switched off or paused: the ladder glides to 0 with the screen, not from its goal.
        animate(displays.map(\.id), over: duration, from: from, keepLadder: shiftsWanted)
        push()
    }

    /// A change on its way: each of `ids` eases over `duration` from what it shows now (`from`,
    /// else worked out before the change) to its goal, which may keep moving meanwhile (the plan, a
    /// shift's morning). One ease for every change: the plan's fades, the ladder, the dial, Auto,
    /// the warm range following the user's brightness. Four loops, each easing and pushing on its
    /// own, drifted out of step (switching off went via the plan's warmth, then down). 0: no ease
    /// of its own; one already running carries on to the new goal. `ladder`: the ladder's own move,
    /// shown where it is going (`ladderPosition`): read from the screen, a step still showed the
    /// old cell, so its detent never came.
    private func animate(_ ids: [CGDirectDisplayID], over duration: Double, from: [CGDirectDisplayID: Levels]? = nil,
                         ladder: Bool = false, keepLadder: Bool = true) {
        guard duration > 0 else { return }
        let now = Self.uptime
        for id in ids {
            let running = motions[id]
            // Taken over mid-way: never sooner than the ease it replaces (a dial turn during
            // switching on finished the switch in 0.15 s), up to a second (a turn during the room's
            // 3 s fade isn't held that long), and its monitor isn't read again (`began`). Two
            // changes of one action (Auto's dimming and warmth) are one ease.
            let left = running.map { min(1, $0.start + $0.duration - now) } ?? 0
            motions[id] = Motion(from: from?[id] ?? levelsNow(id), start: now, duration: max(duration, left),
                                 began: running?.began ?? Date(), retarget: running.map { $0.start < now } ?? false,
                                 byLadder: ladder || keepLadder && running?.byLadder == true)
        }
        runAnimator()
    }

    private func runAnimator() {
        guard animator == nil, !motions.isEmpty || shareEase != nil else { return }
        animator = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16), tolerance: .milliseconds(4))
                guard !Task.isCancelled else { return }
                let now = Self.uptime
                self.push()  // at its end, each writes its goal
                self.motions = self.motions.filter { now < $0.value.start + $0.value.duration }
                if let ease = self.shareEase, now >= ease.start + 0.6 { self.shareEase = nil }
                if self.motions.isEmpty && self.shareEase == nil {
                    self.animator = nil
                    self.writeSaved()
                    return
                }
            }
        }
    }

    private struct Motion {
        /// What the display showed as it began; it eases from there to its goal.
        var from: Levels
        let start: TimeInterval, duration: Double
        /// When it began on the wall clock: a monitor is read once per ease (`setBacklight`).
        let began: Date
        /// Taken over mid-way (held arrow keys, a quick drag, a retarget): eased out from where it
        /// is, with no slow start each time, or the screen trailed the control.
        let retarget: Bool
        var byLadder: Bool

        func eased(at now: TimeInterval) -> Double {
            let t = min(1, max(0, (now - start) / duration))
            return retarget ? 1 - (1 - t) * (1 - t) : t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
        }
    }
    @ObservationIgnored private var motions: [CGDirectDisplayID: Motion] = [:]
    @ObservationIgnored private var animator: Task<Void, Never>?
    /// What each display last showed (`push`); kept while the screens sleep, for the wake's ease.
    @ObservationIgnored private var rendered: [CGDirectDisplayID: Levels] = [:]

    /// Eases run on the Mac's uptime, not the wall clock: a clock set back by hand mid-fade made
    /// one last as long as the jump, with the schedule held meanwhile.
    private static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// The most whole steps any monitor has to take to show its goal.
    private func monitorSteps() -> Double {
        displays.reduce(0) { most, display in
            guard let monitor = monitors[display.id], !monitor.isFailing, !probingIDs.contains(display.id),
                  !doubtful.contains(display.id),
                  let dim = dims[display.id], dim.step > 0 else { return most }
            let light = dim.light(at: goal(display.id).position)
            return max(most, (abs(light - (dim.written ?? min(1, dim.baseline))) / dim.step).rounded())
        }
    }
    /// The last wake or display change (`observe` distrusts dark readings for a few seconds after).
    @ObservationIgnored private var changedAt = Date()
    /// Each monitor's signal share at the last push: the redraw dot shows only while it moves.
    @ObservationIgnored private var lastShare: [CGDirectDisplayID: Double] = [:]

    /// Quitting for an update that relaunches at once: backlights stay where they are, saved as
    /// dimmed, so the new copy resumes them (`follow`) without a flash of full brightness. The
    /// gamma tables go back by themselves as the process ends.
    func keepForRelaunch() {
        stopEasing()
        writeSaved()
    }

    private func stopEasing() {
        animator?.cancel()
        animator = nil
        motions = [:]
        shareEase = nil
    }

    /// Put the displays back exactly as macOS had them; used on quit.
    func restore() {
        stopEasing()
        tasks.forEach { $0.cancel() }
        changeTask?.cancel()
        deferredPush?.cancel()
        holdPush?.cancel()
        restoring = true  // quitting writes now: a move being waited out mustn't leave it dimmed
        for id in reports.keys { reports[id] = BacklightReports() }
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

    /// Inside `push`: `store` leaves `refreshEffective` to its end.
    @ObservationIgnored private var pushing = false
    /// A write held back for being too close to the last one (`setBacklight`), sent by this push.
    @ObservationIgnored private var deferredPush: Task<Void, Never>?
    @ObservationIgnored private var restoring = false

    private func pushLater(by seconds: Double) {
        guard deferredPush == nil else { return }
        deferredPush = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0.016, seconds)))
            self?.deferredPush = nil
            self?.push()
        }
    }

    private func push() {
        // Quitting: `restore` has written what stays; a monitor's answer or a held-back write
        // pushing after it dimmed the screens again on the way out.
        guard !resumedAtLaunch, !restoring else { return }
        pushing = true
        defer { pushing = false }
        var tints: [CGDirectDisplayID: Tint] = [:], stepping: Set<CGDirectDisplayID> = []
        for display in displays {
            guard tinted(display.uuid) else { continue }
            let asked = shown
            var levels = levelsNow(display.id)
            if dims[display.id] != nil {
                whiteShare[display.id] = whiteLeft(levels.warmth, on: display.id)
                if setFloor(display.id) { levels = levelsNow(display.id) }
            }
            if !asleep { rendered[display.id] = levels }
            var t = adjusted(levels, for: display.id)
            let q = levels.position
            // Released only when the plan itself is back at 0 (or shifts don't apply): a shift
            // that brings the screen to its day level mid-evening keeps dimming engaged, so the
            // next press is a shift, not a new day level.
            let release = asked.brightness >= 1 || !shiftsWanted
            if backlight(display.id) == nil, let dim = dims[display.id] {
                requested[display.id] = (q, release)  // on the signal fallback: for the retry
                // A backlight macOS stopped reporting on goes back to its day level first.
                if monitors[display.id] == nil, dim.isDimming { setBacklight(display.id, position: 0) }
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
        for display in displays where tints[display.id] == nil {
            if !asleep { rendered[display.id] = .untinted }
            // Also one macOS stopped reporting on that's still dimmed (its release failed).
            if backlight(display.id) != nil || dims[display.id]?.isDimming == true { setBacklight(display.id, position: 0) }
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
            // A dimmed backlight waits for the wake (nothing is written asleep), which eases it up.
            engine.apply(tints)
            for id in rendered.keys {
                rendered[id] = Levels(position: backlight(id)?.isDimming == true ? rendered[id]?.position ?? 0 : 0, warmth: 0)
            }
        }
        refreshEffective()
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
        // A move under way (a press animating, a ramp): written once it settles (`reported`). Its
        // report never came: taken from the panel as whoever moved it, rather than written over.
        if !restoring, heard(id) {
            if reports[id]!.holds(at: Date()) { return }
            // Taken, then pushed afresh: written on from here, the position worked out before the
            // move was taken overwrote it.
            if let by = reports[id]!.expired(at: Date()) {
                taken(Backlight.light(id), by: by, on: id)
                return pushLater(by: 0)
            }
        }
        // Dimming starts from the panel as it is now: a report missed while the screens slept
        // left an old day level.
        if starting, monitors[id] == nil { readBacklight(id) }
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
            // The monitor is read first, and the push after the reading sends the step, whenever a
            // step is due and the last reading is over a second old (dimming starting too, from a
            // reading up to 5 minutes old by day). Sent from the old level, a monitor turned by its
            // buttons dropped ~30 steps, and its press was lost (the next read matched the step):
            // with 4 s, a press in the seconds before a ramp step still was. In a fade, once at its
            // start (the tick's glide too): its steps follow each other closely after that. A ramp
            // steps about once a minute, so this costs a read (~40 ms of I2C) per step.
            let age = Date().timeIntervalSince(monitorReadAt[id] ?? .distantPast)
            let easing = motions[id]
            let readSinceFade = easing.map { (monitorReadAt[id] ?? .distantPast) >= $0.began } ?? false
            // A fade reads at its start whatever the age: a press made just before it began was
            // otherwise stepped over from the old level.
            if !readSinceFade && (easing != nil || age > 1) && (starting || dim.nextStep(for: position, release: release) != nil) {
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
        // Two writes milliseconds apart from different sources (a tick and a ladder frame): the
        // panel kept the first, so `written` no longer matched it and the next read took Gloam's
        // own level for a press. The later one goes out a frame on instead.
        if !restoring, Date().timeIntervalSince(backlightWritten[id] ?? .distantPast) < 0.011 { return pushLater(by: 0.016) }

        if !dim.isDimming { dim.baselineLevel = Backlight.level(id) }
        let ending = position <= 0 && release
        // The release goes back to the exact slider level (the light lands a step low). Only the
        // release: macOS reports a level write as the user's, so one mid-evening (a shift at the
        // day level) came back as a press.
        let ok = if ending, let level = dim.baselineLevel { Backlight.set(level: level, on: id) }
            else { Backlight.set(light: light, on: id) }
        // A failed write changes nothing: the next push tries again from what the panel shows.
        Debug.log("write \(id) position \(String(format: "%.3f", position)) light \(String(format: "%.4f", light)) ok \(ok) shift \(uuidOf[id].flatMap { shifts[$0] }.map { "\($0)" } ?? "none")")
        guard ok else { return }
        backlightWritten[id] = Date()
        dim.wrote(light, release: ending)
        store(dim, for: id)
        if reports[id] != nil {
            reports[id]!.wrote(at: Date(), level: ending && dim.baselineLevel != nil)
            if !quiet.contains(id), reports[id]!.broken(at: Date()) { reportsBroke(id) }
        }
    }

    /// What macOS reports about a backlight it controls (`BrightnessEvents`), read by
    /// `BacklightReports`: Gloam's own writes coming back are nothing; a move under way (a press
    /// animating, an auto-brightness ramp) holds writes until it settles; settled, the user's move
    /// is theirs as before (a shift, or the day level), and macOS's own the new day level.
    private func reported(_ id: CGDirectDisplayID, _ event: BrightnessEvents.Event, at: Date) {
        guard dims[id] != nil, monitors[id] == nil, !asleep, !restoring else { return }
        guard reports[id] != nil else { return }
        // Reports that broke and were registered again (`adoptBacklights`) count once one comes.
        if quiet.remove(id) != nil {
            Debug.log("reports back on \(id)")
            readOnTick.remove(id)
        }
        switch event {
        case .step(let byUser):
            reports[id]!.step(byUser: byUser, at: at)  // when macOS sent it: the main thread may lag
            // The hold ends with a push: on the minute's tick a move with no settled report
            // otherwise waited that long to be taken.
            if reports[id]!.moving != nil {
                holdPush?.cancel()
                holdPush = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(BacklightReports.stepGap + 0.1))
                    if !Task.isCancelled { self?.push() }
                }
            }
        case .settled(let reason):
            guard let by = reports[id]!.settled(reason) else { return }
            taken(Backlight.light(id), by: by, on: id)
            refreshShares()
            push()
        }
    }

    /// A move macOS reported is done: the user's is theirs (`observe`), macOS's own the new day level.
    private func taken(_ light: Double?, by: BacklightReports.Source, on id: CGDirectDisplayID) {
        Debug.log("reported \(id) \(by == .user ? "user" : "macOS") light \(light.map { String(format: "%.4f", $0) } ?? "nil")")
        if by == .user { observe(light, on: id, byUser: true) } else if let light { macOSMoved(id, to: light) }
    }

    /// macOS moved the backlight itself (auto-brightness): its level for the room is the new day
    /// level (`BacklightDim.macOSSet`), and a dimmed screen eases back down from it. Taken as a
    /// shift, as a press is, the evening's dimming was lost until the morning and "Manual" showed
    /// for a move nobody made. A dark reading is never the room's level (a panel coming on).
    /// Not where the panel still shows what Gloam wrote: an "Ambient" report whose steps passed for
    /// echoes (in a fade) with nothing moved, taken, made the dimmed level the day level.
    private func macOSMoved(_ id: CGDirectDisplayID, to light: Double) {
        guard var dim = dims[id], light > 0.001, !(dim.written.map { BacklightDim.unseen(light, $0) } ?? false) else { return }
        let dimming = dim.isDimming
        dim.macOSSet(light)
        if dimming { dim.baselineLevel = Backlight.level(id) }
        store(dim, for: id)
        if dimming { animate([id], over: Self.afterMacOS, from: [id: Levels(position: 0, warmth: levelsNow(id).warmth)]) }
    }

    /// Gloam's writes to `id` stopped being reported (a macOS update, say): the screen is dimmed
    /// as on a Mac without the reports (`readUnreported`) until one comes again. Written on
    /// unreported, a press or a ramp would be read as nothing and undone.
    private func reportsBroke(_ id: CGDirectDisplayID) {
        Debug.log("reports broke on \(id)")
        quiet.insert(id)
        readUnreported(id)
        pushLater(by: 0)
    }

    /// A backlight macOS doesn't report on, on the tick: where macOS never moves it itself (no
    /// auto-brightness: an Apple monitor, a MacBook with it off) it is dimmed all the same and read,
    /// any change Gloam didn't write being the user's (a press during a fade is lost). With
    /// auto-brightness on, a reading can't tell a ramp from a press (ramps became shifts, the
    /// evening was lost): by signal. A built-in macOS says nothing about is taken to have it.
    private func readUnreported(_ id: CGDirectDisplayID) {
        let builtin = displays.first { $0.id == id }?.isBuiltin ?? true
        if BrightnessEvents.autoBrightness(id) ?? builtin {
            if readOnTick.remove(id) != nil { pushLater(by: 0) }
        } else if readOnTick.insert(id).inserted {
            pushLater(by: 0)
        } else {
            readBacklight(id)
        }
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
            if self.animator == nil { self.push() }
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
        if animator == nil { push() }
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
        if !pushing { refreshEffective() }  // a push ends with it, once for every screen
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
            left.lightFloor = consentKnown ? lightFloor(id) : BacklightDim.floor(maxNits: maxNits[id], lux: nil, consent: 1)
            if saved.isRecent(uuid) ? left.resumes(at: light) : left.written.map({ left.same(light, $0) }) == true {
                // Mid-fade the panel isn't at what was saved: continue from where it is.
                if !firstTargetShown { holdForFirstTarget() }
                left.lightFloor = lightFloor(id)
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
        dim.lightFloor = lightFloor(id)
        store(dim, for: id)
    }

    /// Starts following the backlight of any display that isn't followed yet: through macOS where
    /// it can dim the display, else over DDC/CI where the monitor answers.
    private func adoptBacklights() {
        guard !Debug.isShowcase else { return }  // showcase runs never touch the real screen
        for display in displays where dims[display.id] == nil && Backlight.canDim(display.id) {
            guard let light = Backlight.light(display.id) else { continue }
            maxNits[display.id] = BrightnessEvents.maxNits(display.id)
            follow(display.id, uuid: display.uuid, light: light)
            if BrightnessEvents.watch(display.id, { [weak self] in self?.reported($0, $1, at: $2) }) {
                reports[display.id] = BacklightReports()
            } else {
                readUnreported(display.id)
            }
        }
        // Reports that stopped (`reportsBroke`) are registered again with each display change (a
        // silence can be passing: corebrightnessd restarting), and count once one comes
        // (`reported`): counted at once, every wake handed the backlight over and back.
        for display in displays where dims[display.id] != nil && monitors[display.id] == nil && quiet.contains(display.id) {
            _ = BrightnessEvents.watch(display.id) { [weak self] in self?.reported($0, $1, at: $2) }
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
                guard !dim.same(monitor.initial, w) else { store(dim, for: id); continue }
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

    /// Re-reads the monitors (their buttons' moves are adopted, `BacklightDim`), retries failed
    /// writes, and when a built-in display's share of the smear floor moved it eases there over 0.6 s (a
    /// key press can move it a lot; a jump read as Gloam fighting the key).
    private func pollBacklights() {
        guard !asleep else { return }
        // DDC reads are slow and some links drop them, so each monitor is asked every 20 s; every
        // 5 minutes while the clock idles, unless one is still dimmed or
        // refusing writes: its release is retried on the next tick (a minute at most), not in 5.
        let settled = !displays.contains { d in monitors[d.id].map { $0.isFailing || dims[d.id]?.isDimming == true } ?? false }
        let monitorGap: TimeInterval = idle && settled ? 300 : 20
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
                    guard Date() >= retryAt[id] ?? .distantPast, requested[id] != nil, !readingFirst.contains(id) else { continue }
                    // Read first, then the push after the answer sends the step (with its release
                    // flag, `requested`) from what the monitor shows: sent from `written`, a level
                    // from before the failure, a button press made meanwhile was stepped over and
                    // lost. A read that fails still pushes, so the write is retried all the same
                    // (a failed answer sets the next retry, `backOff`).
                    readFirst(id, monitor)
                } else if !readingFirst.contains(id) {
                    readFirst(id, monitor)
                }
            } else {
                if !heard(id) { readUnreported(id) }
                // macOS reports its moves (`reported`): nothing to read. A write that failed (the
                // morning restore, say) is tried again here: in the day nothing else may push for hours.
                if let asked = requested[id], backlight(id) != nil, dims[id]?.light(for: asked.position, release: asked.release) != nil {
                    setBacklight(id, position: asked.position, release: asked.release)
                }
            }
        }
        refreshShares()
    }

    /// Each built-in's share of the smear floor, from the brightness the user set, eased there over
    /// 0.6 s when it moved.
    private func refreshShares() {
        var next: [CGDirectDisplayID: Double] = [:]
        for display in displays where display.isBuiltin {
            let id = display.id
            // The floor eases with the brightness the user set, not with Gloam's own dimming, or
            // dimming would move the warmth dial's end (and the warmth with it) under the user's
            // hand. Undimmed that is the slider read directly; while dimming, the user's level.
            if let dim = dims[id], dim.isDimming {
                if let level = userLevel(id, dim) { levelShare[id] = Schedule.backlightFactor(level) }
            } else if let light = Backlight.light(id),
                      light != undimmed[id]?.light || Date().timeIntervalSince(levelReadAt[id] ?? .distantPast) > 60 {
                levelReadAt[id] = Date()
                let level = Backlight.level(id)
                if let level { undimmed[id] = (level, light) }
                if shown.isNeutral, animator == nil { dayLight[display.uuid] = light }
                levelShare[id] = level.map(Schedule.backlightFactor)
            }
            if let factor = levelShare[id] { next[id] = factor }
        }
        let ids = Set(next.keys).union(share.keys)
        guard ids.contains(where: { abs((next[$0] ?? 1) - (share[$0] ?? 1)) > 0.01 }) else { return }
        // Untinted on screen the floor changes nothing: taken without easing.
        guard !shown.isNeutral || animator != nil else {
            share = next
            shareEase = nil
            return refreshEffective()
        }
        shareEase = (Dictionary(ids.map { ($0, floorShare($0)) }, uniquingKeysWith: { a, _ in a }), Self.uptime)
        share = next
        runAnimator()
        push()
    }

    /// Reads a backlight macOS controls and feeds it to its dimming (an outside move is adopted).
    @discardableResult private func readBacklight(_ id: CGDirectDisplayID) -> Double? {
        let light = Backlight.light(id)
        Debug.log("read \(id) \(light.map { String(format: "%.4f", $0) } ?? "nil") written \(dims[id]?.written.map { String(format: "%.4f", $0) } ?? "nil") sinceWrite \(String(format: "%.2f", Date().timeIntervalSince(backlightWritten[id] ?? .distantPast)))s")
        observe(light, on: id)
        return light
    }

    /// A reading of a followed display: a monitor's within a second of a write is the write itself;
    /// `byUser`, macOS reported it as the user's move (`reported`), taken however small. A move
    /// becomes the screen's shift from the plan, or its day level (`BacklightDim.Move`): in the
    /// evening's first minutes (the plan and what it shows both under `Shift.threshold`, not the
    /// morning's tail) and once the morning's plan is done. During Settings' preview (shifts off) a move is
    /// only taken as what the panel shows: measured from the preview, it landed wrong after.
    /// A dark reading in the seconds after a wake or a display change is a panel still coming on
    /// (or going off with the lid), not a light to keep: adopted while dimming, the night ended
    /// near black. Later it is the user's (the keys switch the backlight off), and kept.
    private func observe(_ light: Double?, on id: CGDirectDisplayID, byUser: Bool = false) {
        guard let light, var dim = dims[id],
              byUser || Date().timeIntervalSince(backlightWritten[id] ?? .distantPast) > 1,
              light > 0.001 || Date().timeIntervalSince(changedAt) > 5 else { return }
        // Off, paused, or Settings' preview: a press is only taken as what the panel shows. Measured
        // from the preview, a shift landed wrong after it.
        guard shiftsWanted && !previewing || !dim.isDimming else {
            dim.resume(at: light)
            return store(dim, for: id)
        }
        // Measured from the plan where the screens are going; an ease under way carries on around
        // the press (`pressed`).
        let plan = plan(for: id), showing = levelsNow(id).position
        // The morning's plan done, also while a late shift's fade still runs past that (`perUnit`):
        // a press then is the day level, not a shift held until the next evening.
        let fading = shift(for: id).flatMap { $0.isShrinking(clock.now) ? $0 : nil }
        let morningTail = plan <= 0 && fading != nil
        // Pressed up through a shift still fading, short of the day level: a new shift fading with
        // it, not a new day level, or pressing brighter left the day darker than not pressing.
        let upThroughFade = fading != nil && dim.written.map { light > $0 && light < min(1, dim.baseline) } == true
        let setsDayLevel = !upThroughFade && (clock.planDone || morningTail || max(plan, showing) < Shift.threshold && !clock.inMorning)
        let from = clock.planDone || morningTail ? 0 : plan
        let move = byUser ? dim.moved(to: light, plan: from, setsDayLevel: setsDayLevel)
            : dim.observe(light: light, plan: from, setsDayLevel: setsDayLevel)
        Debug.log("observe \(id) light \(String(format: "%.4f", light)) plan \(String(format: "%.3f", plan)) showing \(String(format: "%.3f", showing)) setsDay \(setsDayLevel) -> \(move) baseline \(String(format: "%.4f", dim.baseline))")
        store(dim, for: id)
        guard let uuid = uuidOf[id] else { return }
        switch move {
        case .none: return
        case .shift(let to):
            let p = shiftPlan(plan, for: id)
            // In the morning's tail it fades with the shift it replaces, not into the next evening.
            shifts[uuid] = upThroughFade && clock.planDone ? fading.flatMap {
                Shift.make(to: to, at: p, now: clock.now, until: $0.until) } : newShift(to: to, plan: p)
        case .dayLevel:
            shifts[uuid] = nil
        }
        pressed(id)
        // Saved at once, not debounced as a fade's frames are: a press is rare, and one lost to a
        // crash within the second was written back at the relaunch.
        saveShifts()
        refreshEffective()
    }

    /// A key press (or a monitor's buttons) put the screen where it is now, its goal: an ease under
    /// way there carries on for its warmth only. Written on, the rest of its ease undid the press
    /// (and mid-way through the shifts easing in, only part of it showed).
    private func pressed(_ id: CGDirectDisplayID) {
        guard motions[id] != nil else { return }
        motions[id]?.from.position = goal(id).position
        motions[id]?.byLadder = false
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
            reports[id] = nil
            quiet.remove(id)
            readOnTick.remove(id)
            maxNits[id] = nil
            whiteShare[id] = nil
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
        warmRanges = [:]
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
        EnginePolicy.resolve(choice, chip: SystemInfo.chip)
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
    static let chip: String = {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        return String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self)
    }()
}
