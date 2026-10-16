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
            save(enabled, "enabled")
            update(fade: 1)
            announce(enabled ? "Gloam on" : "Gloam off")
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
    var displayStrength: [String: Double] { didSet { save(displayStrength, "displayStrength"); applyStrengths() } }
    /// Lets the room's light (`RoomLight`) and a backlight that is already low (`Backlight`)
    /// ease the dimming, so the screen never gets darker than the room calls for.
    var autoDimming: Bool {
        didSet {
            save(autoDimming, "autoDimming")
            syncBacklight()
            update(fade: 1)
        }
    }
    /// A hand setting from the popover. It holds until the next change the popover names
    /// ("Manual until 22:00"), then automatic takes over again, so a tweak never quietly
    /// becomes the new every-night.
    var manual: Tint? {
        didSet {
            if manual != nil && oldValue == nil { manualUntil = nextStage?.at }
            syncBacklight()
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
    private(set) var timeZonePlace = Place.forTimeZone() ?? .greenwich
    /// Mirrors SMAppService, which isn't observable; refreshed whenever it may have changed.
    private(set) var launchesAtLogin = SMAppService.mainApp.status == .enabled
    /// Shifts the app's clock; only set by the debug `--at` flag.
    @ObservationIgnored static var clockOffset: TimeInterval = 0

    @ObservationIgnored let display: DisplayController
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var pendingSave: Task<Void, Never>?

    private init() {
        let engine: Engine = Self.load("engine") ?? .auto
        enabled = Self.load("enabled") ?? true
        schedule = Self.load("schedule") ?? Schedule()
        customPlace = Self.load("place")
        self.engine = engine
        displayStrength = Self.load("displayStrength") ?? [:]
        excludedApps = Self.load("excludedApps") ?? []
        autoDimming = Self.load("autoDimming") ?? true
        frontmost = NSWorkspace.shared.frontmostApplication.flatMap {
            $0.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : $0
        }
        hasOnboarded = Self.load("hasOnboarded") ?? false
        display = DisplayController(engine: engine)
        syncBacklight()
        applyStrengths()
        readRoom()

        tasks = [
            observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didActivateApplicationNotification) { model, note in
                model.frontmostChanged(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
            },
            observe(.default, .NSSystemTimeZoneDidChange) { model, _ in
                model.timeZonePlace = Place.forTimeZone() ?? .greenwich
                model.update(fade: 2)
            },
            // Every 5 s the target is applied directly: the steps are too small to see (well
            // under 3 mired), and a fade per tick would mean ~120,000 gamma writes a night.
            Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5), tolerance: .seconds(1))
                    guard let self else { return }
                    self.tick()
                }
            },
        ]
        update(fade: 2)
    }

    // MARK: Derived state

    var place: Place { customPlace ?? timeZonePlace }
    var stage: StageKind { schedule.stage(at: now, place.coordinate) }
    /// Tonight's timeline (or the night still under way), as real dates.
    var evening: Schedule.Evening { schedule.evening(around: now, place.coordinate) }

    /// What changes next and when, at its nominal time (sunset, or the clock time) rather
    /// than when the ease crosses halfway.
    var nextStage: (kind: StageKind, at: Date)? { schedule.upcoming(after: now, place.coordinate, count: 1).first }

    /// A look shown for a moment and then let go: Welcome's "Preview tonight", or a limit
    /// being dragged in Settings. Eases in as gently as it eases out; later steps follow fast.
    var preview: Tint? {
        didSet {
            guard preview != oldValue else { return }  // re-clearing must not restart a fade
            syncBacklight()
            update(fade: preview == nil || oldValue == nil ? 0.6 : 0.15)
        }
    }

    /// True when the schedule says tint but something is holding it off.
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

    private func tick() {
        let hadRoom = roomLux != nil
        readRoom()
        if manual != nil, let until = manualUntil, now >= until { manual = nil }
        guard !display.isFading else { return }
        // The room reading appearing or going (lid opened or closed) eases instead of jumping.
        update(fade: hadRoom != (roomLux != nil) ? 3 : 0)
    }

    /// Smoothed over about a minute and a half (in log terms, as eyes see light), so a lamp
    /// switched on eases the screen over a minute rather than in one 5-second step. A missed
    /// read keeps the last value; three in a row (about 15 s) mean the sensor is gone.
    private func readRoom() {
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

    /// The backlight eases automatic dimming only; a hand setting or a preview shows exactly
    /// what was chosen.
    private func syncBacklight() {
        display.followsBacklight = autoDimming && manual == nil && preview == nil
    }

    private func applyStrengths() {
        let strengths = displayStrength
        display.strength = { strengths[$0] ?? 1 }
    }

    func update(fade: Double) {
        now = Date().addingTimeInterval(Self.clockOffset)
        display.show(target, duration: fade)
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
