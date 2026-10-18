// The app's single source of truth: settings, the clock, and what the screen should show.
// Views read from it; every change funnels through `update` to the DisplayController.

import AppKit
import GloamCore
import Observation
import ServiceManagement
import SwiftUI

/// An app that gets true colour while it's in front (photo, video, design work). This is
/// what replaces a manual pause: set once, and Gloam steps aside by itself.
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
            resumeAt = nil  // switching by hand ends a timed off; `turnOff(until:)` sets it after
            save(enabled, "enabled")
            update(fade: 1)
            announce(enabled ? String(localized: "Gloam on") : String(localized: "Gloam off"))
        }
    }
    /// Saved after the user stops adjusting, not on every drag event.
    var schedule: Schedule {
        didSet {
            saveSoon()
            if preview == nil { update(fade: 0.35) }
        }
    }
    /// Nil means "follow the time zone".
    var customPlace: Place? { didSet { save(customPlace, "place"); update(fade: 1.5) } }
    var engine: Engine { didSet { save(engine, "engine"); display.use(engine) } }
    var excludedApps: [ExcludedApp] { didSet { save(excludedApps, "excludedApps"); update(fade: 0.6) } }
    /// Per-display strength by display UUID; missing means full strength.
    var displayStrength: [String: Double] { didSet { save(displayStrength, "displayStrength"); applyDisplaySettings() } }
    /// External displays (by UUID) held to the smear floor on the user's say-so: macOS says
    /// nothing about a monitor's panel, so only its owner knows it smears. Built-ins are always held.
    var smearGuarded: Set<String> { didSet { save(smearGuarded, "smearGuarded"); applyDisplaySettings() } }
    /// Lets the room's light (`RoomLight`) ease the dimming, so the screen never gets darker
    /// than the room calls for.
    var autoDimming: Bool {
        didSet {
            save(autoDimming, "autoDimming")
            update(fade: 1)
        }
    }
    /// A hand setting from the popover. It holds until the next change the popover names
    /// ("Manual until 22:00"), then automatic takes over again, so a tweak never quietly
    /// becomes the new every-night. Where nothing changes (polar day), until the next wake.
    var manual: Tint? {
        didSet {
            if manual != nil && oldValue == nil {
                refreshClock()
                manualUntil = nextStage?.at ?? schedule.evening(around: now, place.coordinate).wake
            }
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
    /// must neither cancel an exception nor hide which app "true colour for…" refers to.
    private(set) var frontmost: NSRunningApplication?
    /// Showcase runs (README screenshots) use a fixed place, never the developer's time zone.
    private(set) var timeZonePlace = Debug.isShowcase ? .greenwich : Place.forTimeZone() ?? .greenwich
    /// Mirrors SMAppService, which isn't observable; refreshed whenever it may have changed.
    private(set) var launchesAtLogin = SMAppService.mainApp.status == .enabled
    /// Shifts the app's clock; only set by the debug `--at` flag.
    @ObservationIgnored static var clockOffset: TimeInterval = 0

    @ObservationIgnored let display: DisplayController
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    /// The running tick sleeps a minute (`isQuiet`); anything that ends the quiet restarts it.
    @ObservationIgnored private var tickingSlowly = false
    @ObservationIgnored private var pendingSave: Task<Void, Never>?

    private init() {
        let engine: Engine = Self.load("engine") ?? .auto
        enabled = Self.load("enabled") ?? true
        resumeAt = Self.load("resumeAt")
        schedule = Self.load("schedule") ?? Schedule()
        customPlace = Self.load("place")
        self.engine = engine
        displayStrength = Self.load("displayStrength") ?? [:]
        smearGuarded = Self.load("smearGuarded") ?? []
        excludedApps = Self.load("excludedApps") ?? []
        autoDimming = Self.load("autoDimming") ?? true
        frontmost = NSWorkspace.shared.frontmostApplication.flatMap {
            $0.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : $0
        }
        hasOnboarded = Self.load("hasOnboarded") ?? false
        display = DisplayController(engine: engine)
        applyDisplaySettings()
        readRoom()

        tasks = [
            observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didActivateApplicationNotification) { model, note in
                model.frontmostChanged(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
            },
            // After sleep the clock has jumped: ease to what's due now, not hours later. The
            // screens can sleep without the Mac, and nothing is written to them meanwhile.
            observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification) { model, _ in
                model.update(fade: 1.5)
            },
            observe(NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidWakeNotification) { model, _ in
                model.update(fade: 1.5)
            },
            observe(.default, .NSSystemTimeZoneDidChange) { model, _ in
                NSTimeZone.resetSystemTimeZone()  // otherwise the old zone stays cached
                model.clockedAt = nil
                model.timeZonePlace = Place.forTimeZone() ?? .greenwich
                model.update(fade: 2)
            },
        ]
        restartTick()
        update(fade: 2)
    }

    /// Every 5 s the target is applied directly: the steps are too small to see (well under
    /// 3 mired), and a fade per tick would mean ~120,000 gamma writes a night. Untinted with
    /// nothing due within the minute (the day, Gloam off), once a minute.
    private func restartTick() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let quiet = self?.isQuiet else { return }
                self?.tickingSlowly = quiet
                let every: Duration = quiet ? .seconds(60) : .seconds(5)
                try? await Task.sleep(for: every, tolerance: every / 5)
                guard !Task.isCancelled, let self else { return }
                self.tick()
            }
        }
    }

    // MARK: Derived state

    var place: Place { customPlace ?? timeZonePlace }
    /// Stored rather than computed (`refreshClock`): views read them on every redraw, and
    /// finding the next change scans the next 24 hours.
    private(set) var stage = StageKind.day
    /// What changes next and when, at its nominal time (sunset, or the clock time) rather
    /// than when the ease crosses halfway; never in the past.
    private(set) var nextStage: (kind: StageKind, at: Date)?
    /// The place the stored stage was worked out for; nil forces the next refresh.
    @ObservationIgnored private var clockedAt: Coordinate?

    /// A look shown for a moment and then let go: Welcome's "Preview tonight", or a limit
    /// being dragged in Settings. Eases in as gently as it eases out; later steps follow fast.
    var preview: Tint? {
        didSet {
            guard preview != oldValue else { return }  // re-clearing must not restart a fade
            update(fade: preview == nil || oldValue == nil ? 0.6 : 0.15)
        }
    }

    /// Something holds the tint off: Gloam is off, Welcome isn't finished, or an app in true
    /// colour is in front.
    var isHeld: Bool { !enabled || !hasOnboarded || excludedFrontmost != nil }

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

    /// How far into the evening, 0 (day) … 1 (night); the menu-bar glyph fills with it.
    var eveningDepth: Double { schedule.depth(at: now, place.coordinate) }


    // MARK: Actions

    /// Off for a while, from the menu-bar item's menu ("For an Hour", "Until Morning"): the
    /// forgotten switch is the usual way a pause goes wrong, so this one turns itself back on.
    /// Checked by the clock tick, so it can come back up to a minute late while idle.
    private(set) var resumeAt: Date? { didSet { save(resumeAt, "resumeAt") } }

    func turnOff(until date: Date) {
        enabled = false
        resumeAt = date
    }

    /// When "Until Morning" ends: when the evening hands back to day, else the next wake.
    var nextMorning: Date {
        schedule.upcoming(after: now, place.coordinate, count: 4).first { $0.kind == .day }?.at
            ?? schedule.evening(around: now.addingTimeInterval(12 * 3600), place.coordinate).wake
    }

    func run(_ command: Command) {
        switch command {
        case .toggle: enabled.toggle()
        case .on: enabled = true
        case .off: enabled = false
        case .open: break  // handled by the app delegate: the model doesn't open windows
        }
    }

    /// True colour for the app you were just using, from the gear menu.
    func excludeFrontmost() {
        guard let url = frontmost?.bundleURL else { return }
        exclude(appAt: url)
    }

    func exclude(appAt url: URL) {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
              !excludedApps.contains(where: { $0.bundleID == id }) else { return }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        excludedApps.append(ExcludedApp(bundleID: id, name: name))
    }

    func strength(for display: DisplayInfo) -> Double { displayStrength[display.uuid] ?? 1 }


    /// SMAppService isn't observable; re-read it when Settings opens.
    func refreshLoginStatus() { launchesAtLogin = SMAppService.mainApp.status == .enabled }

    func setLaunchAtLogin(_ on: Bool) {
        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        launchesAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Plumbing

    /// Nothing on screen and nothing due for a minute: the clock can tick slowly. A user action
    /// (Gloam on, an app switch, the dial) updates at once, whatever the tick.
    private var isQuiet: Bool {
        target.isNeutral && manual == nil
            && (isHeld || schedule.tint(at: now.addingTimeInterval(80), place.coordinate).isNeutral)
    }

    private func tick() {
        refreshClock()
        let hadRoom = roomLux != nil
        readRoom()
        if manual != nil, let until = manualUntil, now >= until { manual = nil }
        if !enabled, let resume = resumeAt, now >= resume { enabled = true }
        display.keepAlive()
        guard !display.isFading else { return }
        // The room reading appearing or going (lid opened or closed) eases instead of jumping.
        update(fade: hadRoom != (roomLux != nil) ? 3 : 0)
    }

    /// Smoothed over about a minute and a half (in log terms, as eyes see light), so a lamp
    /// switched on eases the screen over a minute rather than in one 5-second step. A missed
    /// read keeps the last value; three in a row (about 15 s) mean the sensor is gone.
    private func readRoom() {
        // No sensor reads while unused, nor while the schedule isn't dimming (room light only
        // eases dimming); the first read once it is starts unsmoothed.
        guard enabled && autoDimming, schedule.tint(at: now, place.coordinate).brightness < 0.999 else {
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
    }

    func update(fade: Double) {
        refreshClock()
        display.show(target, duration: fade)
        // Gloam switched on in the evening, say: room light and the keep-alive start now,
        // not when the minute's sleep ends.
        if tickingSlowly, !isQuiet {
            tickingSlowly = false
            restartTick()
        }
    }

    /// The popover is opening: what it shows is worked out now, not at the next tick (which
    /// may be a minute off, with the backlight read as long ago).
    func refreshNow() {
        display.refreshBacklights()
        tick()
    }

    /// Moves the clock to now, and with it the stage and what comes next. Skipped within a
    /// second of the last move: a drag updates ~120 times a second, and moving `now` that often
    /// would redraw every view that reads it.
    private func refreshClock() {
        let date = Date().addingTimeInterval(Self.clockOffset), coordinate = place.coordinate
        guard abs(date.timeIntervalSince(now)) >= 1 || coordinate != clockedAt else { return }
        now = date
        clockedAt = coordinate
        let current = schedule.stage(at: date, coordinate)
        if current != stage { stage = current }
        let next = schedule.upcoming(after: date, coordinate, count: 1).first
        if next?.kind != nextStage?.kind || next?.at != nextStage?.at { nextStage = next }
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

    /// Writes any schedule change still waiting for its debounce; called on quit.
    func flushSave() {
        pendingSave?.cancel()
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

    private func announce(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }

    private func save<T: Encodable>(_ value: T?, _ key: String) {
        UserDefaults.standard.set(value.flatMap { try? JSONEncoder().encode($0) }, forKey: key)
    }

    private static func load<T: Decodable>(_ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}
