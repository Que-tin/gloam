// The app's single source of truth: settings, the clock, and what the screen should show.
// Views read from it; every change funnels through `update` to the DisplayController.

import AppKit
import GloamCore
import Observation
import ServiceManagement
import SwiftUI

/// An app that pauses Gloam while it's in front (photo, video, design work): set once, and
/// Gloam pauses by itself whenever the app is in front.
struct ExcludedApp: Codable, Equatable, Identifiable {
    var bundleID: String
    var name: String
    var id: String { bundleID }
}

@Observable
final class AppModel {
    static let shared = AppModel()

    var enabled: Bool {
        didSet {
            if !enabled { manual = nil }  // a hand setting must not come back on re-enable
            resumeAt = nil  // switching by hand ends a timed off; `pause(untilMorning:)` sets it after
            save(enabled, "enabled")
            update(fade: 1)
            // After this change settles, so a timed pause (`pause`) is announced as one.
            DispatchQueue.main.async { [self] in
                AccessibilityNotification.Announcement(enabled ? String(localized: "Gloam on")
                    : resumeAt.map { String(localized: "Gloam paused until \(Format.time($0))") } ?? String(localized: "Gloam off")).post()
            }
        }
    }
    /// Saved after the user stops adjusting, not on every drag event.
    var schedule: Schedule {
        didSet {
            saveSoon()
            display.consent = schedule.pastRecommended  // past the recommended night, the floors ease
            if schedule.bedtime != oldValue.bedtime || schedule.wake != oldValue.wake { stagesMoved() }
            if preview == nil { update(fade: 0.35) }
        }
    }
    /// Nil means "follow the time zone".
    var customPlace: Place? { didSet { save(customPlace, "place"); stagesMoved(); update(fade: 1.5) } }
    var engine: Engine { didSet { save(engine, "engine"); display.use(engine) } }
    var excludedApps: [ExcludedApp] { didSet { save(excludedApps, "excludedApps"); update(fade: 0.6) } }
    /// Per-display strength by display UUID; missing means full strength.
    var displayStrength: [String: Double] {
        didSet { save(displayStrength, "displayStrength"); applyDisplaySettings(); wakeTickIfDue() }
    }
    /// External displays (by UUID) held to the smear floor on the user's say-so: macOS says
    /// nothing about a monitor's panel, so only its owner knows it smears. Built-ins are always held.
    var smearGuarded: Set<String> { didSet { save(smearGuarded, "smearGuarded"); applyDisplaySettings() } }
    /// The global shortcut that turns Gloam on or off (`ToggleShortcut`); none until one is recorded.
    var toggleShortcut: KeyCombo? { didSet { save(toggleShortcut, "toggleShortcut") } }
    /// Lets the room's light (`RoomLight`) ease the dimming, so the screen never gets darker
    /// than the room calls for.
    var autoDimming: Bool {
        didSet {
            save(autoDimming, "autoDimming")
            update(fade: 1)
        }
    }
    /// A hand setting from the popover. It holds to the next phase, morning or evening
    /// ("Manual until 7:00"), then automatic takes over again, so a tweak never quietly
    /// becomes the new every-night.
    var manual: Tint? {
        didSet {
            if manual != nil && oldValue == nil { holdManualUntilNextChange() }
            update(fade: manual == nil ? 1 : 0.15)
        }
    }
    private(set) var manualUntil: Date?
    /// The room's light, smoothed; nil when no sensor can see it.
    private(set) var roomLux: Double?
    @ObservationIgnored let roomLight = RoomLight()
    @ObservationIgnored private var missedReads = 0
    /// Until the welcome window is finished the screen stays untouched (Preview aside).
    var hasOnboarded: Bool { didSet { save(hasOnboarded, "hasOnboarded"); update(fade: 2) } }

    private(set) var now = Date()
    /// The app in front, ignoring Gloam itself: opening Gloam's panel activates Gloam, and that
    /// must neither cancel an exception nor hide which app "paused for…" refers to.
    private(set) var frontmost: NSRunningApplication?
    /// Showcase runs (README screenshots) use a fixed place, never the developer's time zone.
    private(set) var timeZonePlace = Debug.isShowcase ? .greenwich : Place.forTimeZone() ?? .greenwich
    /// Mirrors SMAppService, which isn't observable; refreshed whenever it may have changed.
    private(set) var launchesAtLogin = AppModel.loginItemEnabled
    private static var loginItemEnabled: Bool { SMAppService.mainApp.status == .enabled }
    /// Shifts the app's clock; only set by the debug `--at` flag.
    @ObservationIgnored static var clockOffset: TimeInterval = 0

    @ObservationIgnored let display: DisplayController
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    /// The running tick sleeps a minute (`isQuiet`); anything that ends the quiet restarts it.
    @ObservationIgnored private var tickingSlowly = false
    /// The screens are off (the Mac may stay awake for hours): nothing to show, so the clock
    /// ticks slowly and the room isn't read. Watched here, not read from the display layer,
    /// so the order the two hear about a wake in doesn't matter.
    @ObservationIgnored private var screensAsleep = false
    @ObservationIgnored private var pendingSave: Task<Void, Never>?

    private init() {
        let engine: Engine = Self.load("engine") ?? .auto
        // A timed off that ended while Gloam was quit: on from the start, quietly (assigned
        // here, before init completes, so no didSet announces or saves it).
        let resume: Date? = Self.load("resumeAt")
        let expired = resume.map { $0 <= Date() } ?? false
        enabled = expired || (Self.load("enabled") ?? true)
        resumeAt = expired ? nil : resume
        schedule = Self.load("schedule") ?? Schedule()
        let city: Place? = Self.load("place")
        customPlace = city
        customPlaceInUse = city?.keepsTime(of: .current, at: Date()) ?? false
        self.engine = engine
        displayStrength = Self.load("displayStrength") ?? [:]
        smearGuarded = Self.load("smearGuarded") ?? []
        excludedApps = Self.load("excludedApps") ?? []
        autoDimming = Self.load("autoDimming") ?? true
        toggleShortcut = Self.load("toggleShortcut")
        frontmost = NSWorkspace.shared.frontmostApplication.flatMap {
            $0.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : $0
        }
        hasOnboarded = Self.load("hasOnboarded") ?? false
        display = DisplayController(engine: engine)
        applyDisplaySettings()
        display.displaysDidChange = { [weak self] in self?.wakeTickIfDue() }
        readRoom()

        tasks = [
            observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didActivateApplicationNotification) { model, note in
                model.frontmostChanged(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
            },
            // After sleep the clock has jumped: ease to what's due now, not hours later. The
            // screens can sleep without the Mac, and nothing is written to them meanwhile.
            observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification) { model, _ in
                // The screens' own wake can go missing; quiet ticks would then last all evening.
                if CGDisplayIsAsleep(CGMainDisplayID()) == 0 { model.screensAsleep = false }
                model.update(fade: 1.5)
            },
            observe(NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidSleepNotification) { model, _ in
                model.screensAsleep = true
            },
            observe(NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidWakeNotification) { model, _ in
                model.screensAsleep = false
                model.update(fade: 1.5)
            },
            // The clock set by hand: what's due at the new time, eased in, not at the next tick.
            observe(.default, .NSSystemClockDidChange) { model, _ in
                model.stagesMoved()
                model.update(fade: 2)
            },
            observe(.default, .NSSystemTimeZoneDidChange) { model, _ in
                NSTimeZone.resetSystemTimeZone()  // otherwise the old zone stays cached
                model.timeZonePlace = Place.forTimeZone() ?? .greenwich
                model.stagesMoved()
                model.update(fade: 2)
            },
        ]
        restartTick()
        update(fade: 2)
    }

    /// Every 5 s the target is applied, at once unless the step would show (`tick`): the
    /// evening's steps are too small to see, and a fade per tick would mean ~120,000 gamma writes
    /// a night. Once a minute while quiet (`isQuiet`), woken early for a hold that's due
    /// (`nextExpiry`) or anything that ends the quiet (`wakeTickIfDue`).
    private func restartTick() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let quiet = self?.isQuiet else { return }
                self?.tickingSlowly = quiet
                var every: Duration = quiet ? .seconds(60) : .seconds(5)
                // A timed pause or hand setting ends when it says, not at the next slow tick.
                if let due = self?.nextExpiry, let now = self?.now {
                    every = min(every, .seconds(max(1, due.timeIntervalSince(now))))
                }
                try? await Task.sleep(for: every, tolerance: every / 5)
                guard !Task.isCancelled, let self else { return }
                self.tick()
            }
        }
    }

    // MARK: Derived state

    /// The chosen city while it keeps the Mac's time; otherwise (travel, a city in another zone)
    /// the time zone's own, until the clocks match again.
    var place: Place { customPlaceInUse ? customPlace ?? timeZonePlace : timeZonePlace }
    /// Stored, set by `refreshClock` when it changes: worked out on each read, every view showing
    /// the place redrew every tick (Settings and its graph every 5 s in the evening).
    private(set) var customPlaceInUse = false
    /// Stored rather than computed (`refreshClock`): views read them on every redraw, and
    /// finding the next change scans the next 24 hours.
    private(set) var stage = StageKind.day
    /// What changes next and when, at its nominal time (sunset, or the clock time) rather
    /// than when the ease crosses halfway; never in the past.
    private(set) var nextStage: (kind: StageKind, at: Date)?
    /// The wake that ends the evening the clock is in. Views showing "tonight" (the Settings
    /// graph, Welcome) key on it rather than `now`, so they redraw once a day, not every tick.
    private(set) var eveningWake = Date.distantPast
    /// The place the stored stage was worked out for; nil forces the next refresh.
    @ObservationIgnored private var clockedAt: Coordinate?

    /// A look shown for a moment and then let go: Settings' "Preview tonight". Eases in as gently
    /// as it eases out; later steps follow fast.
    var preview: Tint? {
        didSet {
            guard preview != oldValue else { return }  // re-clearing must not restart a fade
            update(fade: preview == nil || oldValue == nil ? 0.6 : 0.15)
        }
    }

    /// Something holds the tint off: Gloam is off, Welcome isn't finished, an app that pauses
    /// Gloam is in front, or a Focus pauses it.
    var isHeld: Bool { !enabled || !hasOnboarded || pausedAside || awaitingFocus }

    /// At launch, until the Focus filter's state is read (a second at most, `endLaunchHold`): a
    /// relaunch while a pausing Focus is on faded into the evening, then out again.
    @ObservationIgnored private var awaitingFocus = !Debug.isShowcase

    /// The launch read of the Focus filter came back (or took too long): the evening may start.
    func endLaunchHold() {
        guard awaitingFocus else { return }
        awaitingFocus = false
        update(fade: 2)
    }

    /// Stepped aside while on: an app that pauses Gloam is in front, or a Focus pauses it.
    var pausedAside: Bool { excludedFrontmost != nil || pausedByFocus }

    /// A Focus whose filter pauses Gloam is on (`GloamFocusFilter`). Like an app exception it
    /// holds the tint without touching `enabled`, so the Focus ending hands back what was there.
    var pausedByFocus = false {
        didSet {
            guard pausedByFocus != oldValue else { return }
            focusSettled = true
            update(fade: 0.5)
        }
    }
    /// The filter has spoken this run, or the user changed the pause: the launch read of the
    /// filter, which can come back later and older, then leaves it alone. A no-op (`.on` while
    /// nothing was paused) doesn't count: it says nothing about the Focus.
    @ObservationIgnored private(set) var focusSettled = false

    /// What the Focus filter says (`GloamFocusFilter`): settled even when nothing changes, since
    /// a Focus ending as Gloam starts must beat the slower launch read.
    func focusFilter(pauses: Bool) {
        focusSettled = true
        pausedByFocus = pauses
    }

    var excludedFrontmost: ExcludedApp? {
        guard let id = frontmost?.bundleIdentifier else { return nil }
        return excludedApps.first { $0.bundleID == id }
    }

    /// What the screen should show once any fade completes.
    var target: Tint {
        if let preview { return preview }
        if isHeld { return .neutral }
        return manual ?? automatic
    }

    /// The schedule's tint now, limits and room light included.
    var automatic: Tint { schedule.tint(at: now, place.coordinate, roomLux: autoDimming ? roomLux : nil) }

    /// How deep into the evening, in the menu-bar glyph's 24 steps: set by `refreshClock` when it
    /// changes, so the glyph redraws a couple of dozen times a night, not on every tick.
    private(set) var eveningDepth = 0.0

    // MARK: Actions

    /// Paused for a while, from the menu-bar item's "Pause" menu ("For an Hour", "Until Morning")
    /// or Shortcuts' Pause Gloam: the forgotten switch is the usual way a pause goes wrong, so
    /// this one turns itself back on.
    /// Checked on every update and tick; the tick wakes for it (`nextExpiry`), so it ends on time.
    private(set) var resumeAt: Date? { didSet { save(resumeAt, "resumeAt") } }

    /// A tint within half a step of either popover control of what automatic asks (a dial nudge is
    /// 2 % of the warmth scale and a scroll notch 1 %, a ladder cell 5 % of the dimming scale):
    /// "Auto" would reset nothing.
    /// Compared as asked, on the controls' fixed scales, not as the main screen shows it: a setting
    /// the main screen can't show (past its smear limit, or nothing to dim) may still show on
    /// another, and was cleared from under it.
    func matchesAutomatic(_ tint: Tint) -> Bool {
        abs(Light.warmth(tint.kelvin) - Light.warmth(automatic.kelvin)) < 0.005
            && abs(Light.dimming(tint.brightness) - Light.dimming(automatic.brightness)) < 0.025
    }

    /// A timed pause from the clock as it is now: on the minute's tick `now` can be a minute old,
    /// which cut an hour short and could put "Until Morning" already in the past. "Until
    /// Morning" ends at `Schedule.nextMorning`.
    func pause(untilMorning: Bool) {
        refreshClock()
        let end = untilMorning ? schedule.nextMorning(after: now, place.coordinate) : now.addingTimeInterval(3600)
        enabled = false
        resumeAt = end
    }

    func run(_ command: Command) {
        switch command {
        // "On" from the shortcut, an intent or a URL means visibly on: a Focus's pause is lifted too
        // (until that Focus next comes on), else it would change nothing on screen. So a toggle
        // turns on what the switch or a Focus holds off; an app's pause stays (Settings owns it).
        case .toggle: run(enabled && !pausedByFocus ? .off : .on)
        case .on:
            enabled = true
            pausedByFocus = false
        case .off: enabled = false
        case .open: break  // handled by the app delegate: the model doesn't open windows
        }
    }

    func exclude(appAt url: URL) {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
              !excludedApps.contains(where: { $0.bundleID == id }) else { return }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        excludedApps.append(ExcludedApp(bundleID: id, name: name))
    }

    func strength(for display: DisplayInfo) -> Double { displayStrength[display.uuid] ?? 1 }

    /// SMAppService isn't observable; re-read it when Settings opens.
    func refreshLoginStatus() { launchesAtLogin = Self.loginItemEnabled }

    func setLaunchAtLogin(_ on: Bool) {
        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        launchesAtLogin = Self.loginItemEnabled
    }

    // MARK: Plumbing

    /// Nothing on screen and nothing due for a minute: the clock can tick slowly. A user action
    /// (Gloam on, an app switch, the dial) updates at once, whatever the tick.
    /// Every display switched off in Settings counts too: nothing is tinted all night. Held
    /// (off or paused), a hand setting waits too: lifting the pause updates at once.
    private var isQuiet: Bool {
        screensAsleep || !display.displays.isEmpty && display.displays.allSatisfy { strength(for: $0) <= 0 }
            || target.isNeutral
            && (isHeld || manual == nil && schedule.tint(at: now.addingTimeInterval(80), place.coordinate).isNeutral)
    }

    private func tick() {
        refreshClock()
        let hadRoom = roomLux != nil
        // A missed wake notification mustn't leave the clock on the minute's tick all evening.
        if screensAsleep, CGDisplayIsAsleep(CGMainDisplayID()) == 0 { screensAsleep = false }
        // Not on the minute's tick: the smoothing assumes 5 s. The reading is kept meanwhile and
        // taken afresh when the quiet ends (`update`).
        if !tickingSlowly { readRoom() }
        expireHolds()
        // Before the comparison below: a key press since the last tick moves what's on screen.
        display.tickBacklights(idle: tickingSlowly)
        // Brought back to what automatic asks (the schedule caught up with it), a hand setting is
        // automatic again: the knobs don't move.
        if let manual, matchesAutomatic(manual) { self.manual = nil }
        display.keepAlive()
        guard !display.isFading else { return }
        // The room reading appearing or going (lid opened or closed) eases instead of jumping. A
        // step the eye would catch (a lamp switched on moves the smoothed room light fastest at
        // first) glides briefly; the evening's own steps are far below that and go at once. Under
        // 0.3 s, which `show` would stretch for a monitor's steps: readings within a second of a
        // write are ignored, so a longer glide each tick left key presses and auto-brightness no
        // reading to be adopted from, and wrote over them.
        let visible = abs(target.brightness - display.shown.brightness) > 0.01
        update(fade: hadRoom != (roomLux != nil) ? 3 : visible ? 0.29 : 0)
    }

    /// Smoothed over about a minute and a half (in log terms, as eyes see light), so a lamp
    /// switched on eases the screen over a minute rather than in one 5-second step. A missed
    /// read keeps the last value; three in a row (about 15 s) mean the sensor is gone.
    private func readRoom() {
        // No sensor reads while unused, nor while the schedule isn't dimming (room light only
        // eases dimming); the first read once it is starts unsmoothed.
        guard enabled && autoDimming, !screensAsleep, schedule.tint(at: now, place.coordinate).brightness < 0.999 else {
            roomLux = nil
            return
        }
        guard !Debug.isShowcase, let lux = roomLight.read() else {
            missedReads += 1
            if missedReads >= 3 { roomLux = nil }
            return
        }
        missedReads = 0
        guard let last = roomLux else { roomLux = lux; return }
        let k = 1 - exp(-5.0 / 90)
        roomLux = pow(10, log10(max(last, 1)) + (log10(max(lux, 1)) - log10(max(last, 1))) * k)
    }

    private func frontmostChanged(_ app: NSRunningApplication?) {
        guard app?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let wasExcluded = excludedFrontmost != nil
        frontmost = app
        if wasExcluded != (excludedFrontmost != nil) { update(fade: 0.5) }
    }

    private func applyDisplaySettings() {
        let strengths = displayStrength, guarded = smearGuarded
        display.strength = { strengths[$0] ?? 1 }
        display.smearGuarded = { guarded.contains($0) }
        display.consent = schedule.pastRecommended
    }

    func update(fade: Double) {
        refreshClock()
        expireHolds()  // after a wake, an expired hand setting or pause must not come back first
        // Leaving a quiet stretch (a pause lifted, Gloam back on): the room as it is now, unsmoothed,
        // or the first fade goes to a minute-old (or no) room reading and eases back after.
        if tickingSlowly, !isQuiet {
            roomLux = nil
            missedReads = 0
            readRoom()
        }
        display.show(target, duration: fade)
        wakeTickIfDue()
    }

    /// Gloam switched on in the evening, say: room light and the keep-alive start now, not when
    /// the minute's sleep ends.
    private func wakeTickIfDue() {
        if tickingSlowly, !isQuiet {
            tickingSlowly = false
            restartTick()
        }
    }

    /// The popover is opening: what it shows is worked out now (backlights read included), not
    /// at the next tick, which may be a minute off.
    func refreshNow() { tick() }

    /// When the next hold ends by itself: a hand setting's expiry, or a timed pause's.
    private var nextExpiry: Date? {
        [manual == nil ? nil : manualUntil, enabled ? nil : resumeAt].compactMap { $0 }.min()
    }

    /// Ends a hand setting or a timed pause whose time has come.
    private func expireHolds() {
        if manual != nil, let until = manualUntil, now >= until { manual = nil }
        if !enabled, let resume = resumeAt, now >= resume { enabled = true }
    }

    /// A hand setting holds to the next phase, morning or evening (`Schedule.manualHold`).
    private func holdManualUntilNextChange() {
        refreshClock()
        manualUntil = schedule.manualHold(after: now, place.coordinate)
    }

    /// Bedtime, wake, the place or the time zone changed: the stages move, and a running hand
    /// setting's end with them.
    private func stagesMoved() {
        clockedAt = nil
        refreshClock()  // now, not at the next tick: Settings' graph shows the night `eveningWake` names
        if manual != nil { holdManualUntilNextChange() }
    }

    /// Moves the clock to now, and with it the stage and what comes next. Skipped within a
    /// second of the last move: a drag updates ~120 times a second, and moving `now` that often
    /// would redraw every view that reads it.
    private func refreshClock() {
        let date = Date().addingTimeInterval(Self.clockOffset)
        let inUse = customPlace?.keepsTime(of: .current, at: date) ?? false
        if inUse != customPlaceInUse { customPlaceInUse = inUse }
        let coordinate = place.coordinate
        guard abs(date.timeIntervalSince(now)) >= 1 || coordinate != clockedAt else { return }
        now = date
        clockedAt = coordinate
        let current = schedule.stage(at: date, coordinate)
        if current != stage { stage = current }
        let next = schedule.upcoming(after: date, coordinate, count: 1).first
        if next?.kind != nextStage?.kind || next?.at != nextStage?.at { nextStage = next }
        let wake = schedule.evening(around: date, coordinate).wake
        if wake != eveningWake { eveningWake = wake }
        let depth = (min(1, max(0, schedule.depth(at: date, coordinate))) * 24).rounded() / 24
        if depth != eveningDepth { eveningDepth = depth }
    }

    /// Notification-center observers as main-actor tasks, so handlers need no isolation dance.
    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ handler: @escaping (AppModel, Notification) -> Void) -> Task<Void, Never> {
        Task { [weak self] in
            for await note in center.notifications(named: name) {
                guard let self else { return }
                handler(self, note)
            }
        }
    }

    /// Writes any schedule change still waiting for its debounce; called on quit. Not before
    /// Start: Welcome closed first quits without saving anything.
    func flushSave() {
        pendingSave?.cancel()
        guard hasOnboarded else { return }
        save(schedule, "schedule")
    }

    private func saveSoon() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            self.save(self.schedule, "schedule")
        }
    }

    private func save<T: Encodable>(_ value: T?, _ key: String) {
        UserDefaults.standard.set(value.flatMap { try? JSONEncoder().encode($0) }, forKey: key)
    }

    private static func load<T: Decodable>(_ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}
