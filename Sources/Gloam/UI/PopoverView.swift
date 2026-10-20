// The menu-bar window: a lamp. The orb glows with what the screen really shows and says how
// much blue light reaches you once it gets there. The dial and ladder show the warmth and
// dimming asked for, so they move with the automatic easing; moving them takes over by hand
// until the next morning, or by day the next evening (Settings sets every night). "Auto" hands back.
//
// Both controls are positions on fixed scales (the schedule's own, as in Settings), so neither
// moves when the user's brightness does: ends that followed the screen made the knobs wander,
// and nobody could tell why. Each screen takes the ladder's position the same share of the way
// to its own darkest; the dial's warmth it shows as far as its smear limit allows.

import GloamCore
import SwiftUI

struct PopoverView: View {
    @Bindable var model: AppModel
    /// The lamp's light, animated separately so it warms up core-first with the bloom
    /// following, and fades with an afterglow. 0 = unlit, 1 = lit.
    @State private var core = 0.0
    @State private var bloom = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// What the controls show: the hand setting, else what is asked of the screen this instant
    /// (before its limits; following the fades, so the knobs glide with them). Not Settings'
    /// "Preview tonight": the knobs stay at what's asked, and a move starts from there.
    private var current: Tint { model.manual ?? (model.preview == nil ? model.display.shown : model.automatic) }
    /// Blue light reaching you once the screen gets where it is going, after its limits, rounded
    /// to 5% (the estimate is good to about that). Said as what's left ("20%") rather than what's
    /// saved ("−80%"). The destination rather than every step of a fade, so a switch reads as one
    /// change of number, faded, instead of twenty.
    /// Counted against the screen as it was by day (`lightSinceDay`), so the user's own brightness
    /// counts too, while by day it still reads 100 %.
    private var blueShare: Double {
        Melanopic.relative(model.display.onMain(model.target), in: model.display.mainColourSpace) * model.display.lightSinceDay
    }
    private var bluePercent: Int { Int((blueShare * 20).rounded()) * 5 }
    /// The orb's number. Under 5 % it says so ("<5 %"): a plain "5 %" suggested more could be
    /// taken away, and "0 %" would claim none is left, which no screen that's on can do.
    private var blueText: String {
        blueShare < 0.05 ? String(localized: "<\(Format.percent(0.05))", comment: "less than 5 %") : Format.percent(Double(bluePercent) / 100)
    }
    /// Whether the lamp is lit: Gloam is visibly tinting the screen.
    private var lampLit: Bool { !model.isHeld && bluePercent <= 95 }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.bottom, 12)
            // Off, the controls stay live: reaching for one means "this, now", so it turns Gloam
            // back on (disabled controls read as broken). Paused for an app or by a Focus, nothing
            // they did would show, so they rest.
            dial
                .disabled(!canTakeOver)
            DimmingLadder(dimming: dimming, kelvin: current.kelvin, core: core,
                          editable: model.display.canDim)  // else nothing to dim
                .padding(.top, 20)
                .disabled(!canTakeOver)
            // One status row at most: a hand setting (unless it resets nothing), a pause for the
            // app in front, a timed pause (before a Focus's, so its Resume stays in reach), or a
            // Focus's pause, which also ends with the Focus.
            if let manual = model.manual, !model.matchesAutomatic(manual) {
                statusRow(model.manualUntil.map { String(localized: "Manual until \(Format.time($0))") } ?? String(localized: "Manual"),
                          String(localized: "Auto"), "arrow.counterclockwise") { model.manual = nil }
                    .help("Back to automatic")
            } else if let app = model.excludedFrontmost {
                statusRow(String(localized: "Paused for \(app.name)"), String(localized: "Stop pausing"), "play.fill") {
                    model.excludedApps.removeAll { $0 == app }
                }
            } else if !model.enabled, let resume = model.resumeAt {
                // Visibly on, as the menu's Resume: a Focus's pause is lifted too.
                statusRow(String(localized: "Paused until \(Format.time(resume))"), String(localized: "Resume"), "play.fill") {
                    model.run(.on)
                }
            } else if model.enabled, model.pausedByFocus {  // switched off, "Off" says it all
                // Lifted until the Focus next comes on; its filter pauses again then.
                statusRow(String(localized: "Paused by your Focus"), String(localized: "Resume"), "play.fill") {
                    model.pausedByFocus = false
                }
            }
            updateRow
            // Below the controls, so one appearing grows the panel downwards and never moves
            // the dial or ladder from under the pointer.
            notices
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 20)
        .frame(width: 300)
        .background(LampSurface(glow: model.display.effective, lit: max(core, 0.25)))
        .environment(\.colorScheme, .dark)
        .onAppear {
            core = lampLit ? 1 : 0
            bloom = core
        }
        .onChange(of: lampLit) { _, lit in warm(lit) }
    }

    private var dial: some View {
        // The orb turns Gloam visibly on (a Focus's pause lifted too); the header's switch is
        // only the switch.
        LampDial(fraction: warmth, kelvinAt: { Light.kelvin(warmth: $0) }, shown: model.display.effective,
                 core: core, bloom: bloom, orbTitle: blueText,
                 onPower: model.enabled ? nil : { model.run(.on) },
                 editable: canTakeOver,
                 stageName: stageTitle, caption: dialCaption)
    }

    // MARK: The one signature motion

    /// On: the core lights first, the bloom follows 150 ms later with a slight swell.
    /// Off: a quick decay, then a faint ember lingers on the core. Reduce Motion: a crossfade.
    private func warm(_ lit: Bool) {
        if reduceMotion {
            withAnimation(.easeInOut(duration: 0.25)) { core = lit ? 1 : 0; bloom = core }
            return
        }
        if lit {
            withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.45)) { core = 1 }
            withAnimation(.spring(response: 0.6, dampingFraction: 0.7).delay(0.15)) { bloom = 1 }
        } else {
            withAnimation(.easeIn(duration: 0.4)) {
                bloom = 0
                core = 0.06
            } completion: {
                guard !lampLit else { return }
                withAnimation(.easeOut(duration: 1.2)) { core = 0 }
            }
        }
    }

    // MARK: Editing

    /// The warmth asked for, on the schedule's scale (100 % = its warmest): never pegged at a
    /// screen's limit, so a touch never turns the screen cooler. Past that limit (smear) the screen
    /// shows its warmest and the steps change nothing there.
    private var warmth: Binding<Double> {
        Binding(get: { Light.warmth(current.kelvin) },
                set: { w in takeOver { Tint(kelvin: Light.kelvin(warmth: w), brightness: $0.brightness) } })
    }

    /// A position on the schedule's scale: each screen takes it the same share of the way to its
    /// own darkest, so 100 % is as dim as this screen goes and the ladder never moves under the
    /// user's brightness keys.
    private var dimming: Binding<Double> {
        Binding(get: { Light.dimming(current.brightness) },
                set: { d in takeOver { Tint(kelvin: $0.kelvin, brightness: Light.brightness(dimming: d)) } })
    }

    /// The controls can set a tint: Gloam is on or can be switched on by them, and no app in
    /// front is holding it off (and Welcome is done, though the popover only exists after it).
    private var canTakeOver: Bool { model.hasOnboarded && !model.pausedAside }

    /// What the controls start from: the hand setting, else what automatic asks. Not what's
    /// shown: off, paused or mid-fade that's neutral or half-way, and a move on one control copied
    /// it into the other (a turn of the dial at 22:30 while off left the night undimmed).
    private var asked: Tint { model.manual ?? model.automatic }

    /// A hand setting, the moved control's value over what's `asked`; when Gloam is off, the
    /// first move turns it back on, first: its update reads the room afresh, and the other
    /// control's value comes from that (built before, it dimmed as if the room were dark).
    private func takeOver(_ tint: (Tint) -> Tint) {
        guard canTakeOver else { return }
        if !model.enabled { model.enabled = true }
        model.manual = tint(asked)
    }

    // MARK: Words

    private var stageTitle: String {
        // "Paused" for anything that ends by itself (a timed pause); "Off" for the switch.
        if !model.enabled { return model.resumeAt == nil ? String(localized: "Off") : String(localized: "Paused") }
        if model.pausedAside { return String(localized: "Paused") }
        return model.stage.title
    }

    // MARK: Parts

    private var header: some View {
        HStack {
            Wordmark()
                .fill(Lamp.ink.opacity(0.92))
                .frame(width: 15 * Wordmark.aspect, height: 15)
                .accessibilityHidden(true)
            Spacer()
            HStack(spacing: 10) {
                SettingsButton()
                PowerSwitch(on: $model.enabled, kelvin: model.display.effective.kelvin)
            }
        }
        .overlay {
            // The word rolls into the next as the orb's numbers do (a fade read as a flicker beside
            // them); the dot glides along as its width changes. Reduce Motion: no roll.
            HStack(spacing: 6) {
                Circle().fill(Color.kelvin(model.display.effective.kelvin)).frame(width: 5, height: 5)
                    .shadow(color: .kelvin(model.display.effective.kelvin), radius: 3)
                    .opacity(0.35 + 0.65 * core)
                LampLabel(text: stageTitle, opacity: 0.75)
                    .contentTransition(reduceMotion ? .identity : .numericText())
            }
            .animation(reduceMotion ? nil : .snappy(duration: 0.35), value: stageTitle)
            .offset(x: -5)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Now: \(stageTitle)")
            .accessibilitySortPriority(1)  // an overlay reads last; the state comes before its controls
        }
    }

    /// What changes next, and when: the one question a schedule raises. (A separate "next"
    /// line and an evening timeline strip were tried; both said what this says, louder.)
    private var dialCaption: String {
        // Off or paused (for an app or a Focus), nothing is coming: no promise of a change.
        guard !model.isHeld, let next = model.nextStage else { return "" }
        return String(localized: "\(next.kind.title) at \(Format.time(next.at))", comment: "Stage name, then time: Night at 22:00")
    }

    /// A line of state with, on the right, its way back (`pill`), a figure (`detail`, set like the
    /// dimming percentage above it) or a spinner (`busy`).
    private func statusRow(_ text: String, _ pill: String? = nil, _ symbol: String? = nil, detail: String? = nil,
                           busy: Bool = false, action: @escaping () -> Void = {}) -> some View {
        HStack(spacing: 8) {
            LampLabel(text: text, opacity: 0.6).lineLimit(2)  // a long app name wraps once, then truncates
            Spacer()
            if let pill { LampPill(title: pill, symbol: symbol, action: action).fixedSize() }
            if let detail {
                Text(detail).font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Lamp.ink.opacity(0.9))
                    .contentTransition(.numericText())
            }
            if busy { ProgressView().controlSize(.small).accessibilityHidden(true) }
        }
        .frame(minHeight: 26)  // a row without a pill keeps the height of one with
        .padding(.top, 16)
    }

    /// Sparkle's progress, as one row (`Updates`): no update window.
    @ViewBuilder private var updateRow: some View {
        switch Updates.state.status {
        case .idle: EmptyView()
        case .checking: statusRow(String(localized: "Checking for updates…"), busy: true)
        case .upToDate: statusRow(String(localized: "Gloam is up to date"))
        case .failed: statusRow(String(localized: "Couldn't check for updates"))
        case .downloading(let version, let progress):
            statusRow(String(localized: "Downloading Gloam \(version)…"), detail: progress.map { Format.percent($0) }, busy: progress == nil)
        case .ready(let version):
            statusRow(String(localized: "Gloam \(version) is ready"), String(localized: "Install"), "arrow.clockwise") {
                Updates.install()
            }
            .help(String(localized: "Installs the update and restarts Gloam"))
        case .installing: statusRow(String(localized: "Installing…"), busy: true)
        }
    }

    @ViewBuilder private var notices: some View {
        if model.display.interference {
            // The overlay never touches the gamma table, so it ends the tug of war on its own.
            LampNotice(text: String(localized: "Another app keeps changing your screen's colours, which can make it flicker."),
                       action: model.display.resolvedEngine == .gamma ? (String(localized: "Use overlay"), { model.engine = .overlay }) : nil)
                .padding(.top, 14)
        }
        if model.enabled, model.display.resolvedEngine == .gamma,
           let hdr = model.display.displays.first(where: \.hdrActive) {
            LampNotice(text: String(localized: "HDR is on for \(hdr.name), so the tint may look washed out."),
                       action: (String(localized: "Use overlay"), { model.engine = .overlay }))
                .padding(.top, 14)
        }
    }
}

/// Settings, one click away. App exceptions and Quit live in the menu-bar item's right-click
/// menu: a menu behind the gear made Settings take two clicks.
private struct SettingsButton: View {
    @State private var hovering = false

    var body: some View {
        ZStack {
            Circle().fill(.white.opacity(hovering ? 0.09 : 0.05))
            Circle().strokeBorder(.white.opacity(0.1))
            Image(systemName: "gearshape").font(.system(size: 11, weight: .medium))
                .foregroundStyle(Lamp.ink.opacity(0.75))
        }
        .frame(width: 26, height: 26)
        .lampPress(Circle()) { Windows.showSettings() }
        .onHover { hovering = $0 }
        .help("Settings")
        .accessibilityLabel("Settings")
    }
}
