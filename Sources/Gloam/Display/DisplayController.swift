// Owns the active engine and moves the screen toward a target tint: eased fades for user
// actions, direct writes for the clock's small steps (writes are skipped when nothing changed).
// It checks every few seconds whether the tint was overwritten and only then writes it again,
// because macOS quietly resets gamma tables on wake, display changes and some ColorSync events,
// and reads each built-in display's backlight, whose level eases that display's dimming.

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
}

extension TintEngine {
    func isOverwritten() -> Bool { false }
    func restoreAll() { reset() }
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
    /// Per-display strength 0…1, looked up by display UUID. 0 leaves a display alone.
    @ObservationIgnored var strength: (String) -> Double = { _ in 1 } { didSet { push() } }
    /// Ease dimming on a display whose backlight is already low (`Backlight`). Off for a hand
    /// setting or a preview: those show exactly what was chosen.
    @ObservationIgnored var followsBacklight = true {
        didSet { if followsBacklight != oldValue { readBacklights() } }
    }
    /// Each display's share of the dimming, from its backlight; read every few seconds, not
    /// per fade frame, and eased over a second when it moves. Missing means all of it.
    private var dimShare: [CGDirectDisplayID: Double] = [:]
    @ObservationIgnored private var shareTask: Task<Void, Never>?

    /// What the main display shows after its backlight share: what the popover's ladder and
    /// orb describe.
    var effective: Tint {
        var t = shown
        t.brightness = 1 - (1 - t.brightness) * (dimShare[CGMainDisplayID()] ?? 1)
        return t
    }

    @ObservationIgnored private var engine: TintEngine
    @ObservationIgnored private(set) var resolvedEngine: Engine
    @ObservationIgnored private var fadeTask: Task<Void, Never>?
    @ObservationIgnored private var keepAlive: Task<Void, Never>?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    init(engine choice: Engine) {
        resolvedEngine = Self.resolve(choice)
        engine = Self.make(resolvedEngine)
        readBacklights()
        let workspace = NSWorkspace.shared.notificationCenter
        tasks = [
            (NotificationCenter.default, NSApplication.didChangeScreenParametersNotification),
            (workspace, NSWorkspace.didWakeNotification),
            (workspace, NSWorkspace.screensDidWakeNotification),
        ].map { center, name in
            Task { [weak self] in
                for await _ in center.notifications(named: name) { self?.displaysChanged() }
            }
        }
        // Reasserts the tint only when something overwrote it (macOS on some ColorSync events,
        // or another tinting app); wakes and display changes arrive as notifications.
        keepAlive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5), tolerance: .seconds(1))
                guard let self else { return }
                guard self.fadeTask == nil else { continue }
                self.readBacklights()
                if self.noteInterference() { self.push() }
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
                    return
                }
                try? await Task.sleep(for: .milliseconds(16))
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
        keepAlive?.cancel()
        engine.restoreAll()
    }

    private func push() {
        var tints: [CGDirectDisplayID: Tint] = [:]
        for display in displays {
            let s = strength(display.uuid)
            guard s > 0 else { continue }
            var tint = Tint.mix(.neutral, shown, s)
            tint.brightness = 1 - (1 - tint.brightness) * (dimShare[display.id] ?? 1)
            tints[display.id] = tint
        }
        engine.apply(tints)
    }

    /// Re-reads the backlights and, when a share moved, eases to it over a second (a brightness
    /// key press can move it a lot; a jump read as Gloam fighting the key).
    private func readBacklights() {
        var next: [CGDirectDisplayID: Double] = [:]
        if followsBacklight {
            for display in displays { if let level = Backlight.level(display.id) { next[display.id] = Schedule.backlightFactor(level) } }
        }
        let ids = Set(next.keys).union(dimShare.keys)
        guard ids.contains(where: { abs((next[$0] ?? 1) - (dimShare[$0] ?? 1)) > 0.01 }) else { return }
        let from = dimShare, start = Date()
        shareTask?.cancel()
        shareTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                let t = min(1, Date().timeIntervalSince(start) / 1.2)
                let eased = t * t * (3 - 2 * t)
                var share: [CGDirectDisplayID: Double] = [:]
                for id in ids { share[id] = (from[id] ?? 1) + ((next[id] ?? 1) - (from[id] ?? 1)) * eased }
                self.dimShare = share
                if self.fadeTask == nil { self.push() }  // a running fade pushes every frame anyway
                if t >= 1 { return }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    /// Two overwrites within a minute raise the notice; two quiet minutes clear it. Returns
    /// whether the tint was overwritten just now (and so needs writing again).
    private func noteInterference() -> Bool {
        let now = Date()
        let overwritten = engine.isOverwritten()
        if overwritten { overwrites.append(now) }
        overwrites.removeAll { now.timeIntervalSince($0) > 120 }
        let raised = overwrites.filter { now.timeIntervalSince($0) <= 60 }.count >= 2
        if raised != interference && (raised || overwrites.isEmpty) { interference = raised }
        return overwritten
    }

    private func displaysChanged() {
        displays = Displays.current()
        engine.displaysChanged()
        readBacklights()
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
