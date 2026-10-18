// The menu-bar window: a lamp. The orb glows with what the screen really shows and says how
// much blue light reaches you once it gets there. The dial and ladder show the warmth and
// dimming asked for, so they
// move with the automatic easing; moving them takes over by hand until the next stage begins
// (limits for every night live in Settings). "Auto" hands back at once.
//
// Both controls always span their full, fixed range (daylight to ember; no dimming to the
// deepest dimming) and show what was asked for. Where the screen can't follow (the light floor,
// the smear floor) it quietly stops at its limit: the orb shows what is really on screen, and
// when a hand setting asked past it, a notice says why. Ends that moved with those limits were tried: dimming moved the warmth
// knob (the smear floor eases as the backlight dims) and nobody could tell the two apart.

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
    /// (before its limits; following the fades, so the knobs glide with them).
    private var current: Tint { model.manual ?? model.display.shown }
    /// Blue light reaching you once the screen gets where it is going, after its limits, rounded
    /// to 5% (the estimate is good to about that). Said as what's left ("20%") rather than what's
    /// saved ("−80%"). The destination rather than every step of a fade, so a switch reads as one
    /// change of number, faded, instead of twenty.
    private var bluePercent: Int {
        let t = model.display.onMain(model.target)
        return Int((Melanopic.relative(t, in: model.display.mainColourSpace) * 20).rounded()) * 5
    }
    /// Whether the lamp is lit: Gloam is visibly tinting the screen.
    private var lampLit: Bool { !model.isHeld && bluePercent <= 95 }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.bottom, 12)
            // Off, the controls stay live: reaching for one means "this, now", so it turns Gloam
            // back on (disabled controls read as broken). Stepping aside, nothing they did
            // would show, so they rest.
            dial
                .disabled(!canTakeOver)
            DimmingLadder(dimming: dimming, kelvin: current.kelvin, core: core)
                .padding(.top, 20)
                .disabled(!canTakeOver)
            if let manual = model.manual, !model.matchesAutomatic(manual) {  // nothing to reset: no "Auto"
                footer.padding(.top, 16)
            } else if let app = model.excludedFrontmost {
                // The way back from the popover itself, not only from Settings or the menu.
                HStack(spacing: 8) {
                    LampLabel(text: String(localized: "True colour for \(app.name)"), opacity: 0.6)
                    Spacer()
                    LampPill(title: String(localized: "Tint it"), symbol: "sun.haze") {
                        model.excludedApps.removeAll { $0 == app }
                    }.fixedSize()
                }
                .padding(.top, 16)
            } else if !model.enabled, let resume = model.resumeAt {
                // A timed off, from the menu-bar item's menu: say when it ends, and let it end now.
                HStack(spacing: 8) {
                    LampLabel(text: String(localized: "Off until \(Format.time(resume))"), opacity: 0.6)
                    Spacer()
                    LampPill(title: String(localized: "Turn on"), symbol: "power") { model.enabled = true }.fixedSize()
                }
                .padding(.top, 16)
            }
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
        let orb = self.orb
        return LampDial(fraction: warmth, kelvinAt: Light.kelvin(warmth:), shown: model.display.effective,
                        core: core, bloom: bloom, orbTitle: orb.title, orbCaption: orb.caption,
                        onPower: model.enabled ? nil : { model.enabled = true },
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

    private var warmth: Binding<Double> {
        Binding(get: { Light.warmth(current.kelvin) },
                set: { takeOver(Tint(kelvin: Light.kelvin(warmth: $0), brightness: current.brightness)) })
    }

    private var dimming: Binding<Double> {
        Binding(get: { Light.dimming(current.brightness) },
                set: { takeOver(Tint(kelvin: current.kelvin, brightness: Light.brightness(dimming: $0))) })
    }

    /// The controls can set a tint: Gloam is on or can be switched on by them, and no app in
    /// front is holding it off (and Welcome is done, though the popover only exists after it).
    private var canTakeOver: Bool { model.hasOnboarded && model.excludedFrontmost == nil }

    /// A hand setting; when Gloam is off, the first move turns it back on.
    private func takeOver(_ tint: Tint) {
        guard canTakeOver else { return }
        if !model.enabled { model.enabled = true }
        model.manual = tint
    }


    // MARK: Words

    private var orb: (title: String, caption: String) {
        // Numbers only, never a word ("off", "aside" read as broken): an app in true colour
        // shows its 100 % and says why.
        if let app = model.excludedFrontmost {
            return (Format.percent(Double(bluePercent) / 100), String(localized: "true colour for \(app.name)"))
        }
        return (Format.percent(Double(bluePercent) / 100), String(localized: "blue light"))
    }

    private var stageTitle: String {
        if !model.enabled { return String(localized: "Off") }
        if model.excludedFrontmost != nil { return String(localized: "True colour") }
        return model.stage.title
    }

    // MARK: Parts

    private var header: some View {
        HStack {
            Text("gloam")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Lamp.ink.opacity(0.92))
                .tracking(-0.2)
                .accessibilityHidden(true)
            Spacer()
            HStack(spacing: 10) {
                SettingsButton()
                PowerSwitch(on: $model.enabled, kelvin: model.display.effective.kelvin)
            }
        }
        .overlay {
            // Dot and word fade as one, each pair centred on its own: fading only the word left
            // the dot jumping to the new width over the old word.
            HStack(spacing: 6) {
                Circle().fill(Color.kelvin(model.display.effective.kelvin)).frame(width: 5, height: 5)
                    .shadow(color: .kelvin(model.display.effective.kelvin), radius: 3)
                    .opacity(0.35 + 0.65 * core)
                LampLabel(text: stageTitle, opacity: 0.75)
            }
            .swapFade(stageTitle)
            .offset(x: -5)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Now: \(stageTitle)")
        }
    }

    /// What changes next, and when: the one question a schedule raises. (A separate "next"
    /// line and an evening timeline strip were tried; both said what this says, louder.)
    private var dialCaption: String {
        // Off or in true colour, nothing is coming: no promise of a change.
        guard !model.isHeld, let next = model.nextStage else { return "" }
        return String(localized: "\(next.kind.title) at \(Format.time(next.at))", comment: "Stage name, then time: Night at 22:00")
    }

    private var footer: some View {
        HStack(spacing: 8) {
            LampLabel(text: model.manualUntil.map { String(localized: "Manual until \(Format.time($0))") } ?? String(localized: "Manual"),
                      opacity: 0.6)
            Spacer()
            LampPill(title: String(localized: "Auto"), symbol: "arrow.counterclockwise") { model.manual = nil }
                .fixedSize()
                .help("Back to automatic")
        }
    }

    @ViewBuilder private var notices: some View {
        if model.display.interference {
            // The overlay never touches the gamma table, so it ends the tug of war on its own.
            LampNotice(text: String(localized: "Another app keeps changing your screen's colours, so the two take turns."),
                       action: model.display.resolvedEngine == .gamma ? (String(localized: "Use overlay"), { model.engine = .overlay }) : nil)
                .padding(.top, 14)
        }
        // Limits are explained when a hand setting asked past them; automatic stopping at them
        // every evening isn't news, and a standing warning reads as something wrong.
        if model.enabled, model.manual != nil, model.display.smearLimits(model.target) {
            // On a built-in screen the limit eases as the backlight dims (Gloam's own dimming
            // included), so "dim further" is the way past it there.
            LampNotice(text: model.display.mainIsBuiltin
                ? String(localized: "Held at \(Light.name(model.display.effective.kelvin)) so scrolling text doesn't leave trails. Dim further to go warmer.")
                : String(localized: "Held back so scrolling text doesn't leave trails on this display."))
                .padding(.top, 14)
        } else if model.enabled, model.manual != nil, model.display.dimLimits(model.target) {
            // The backlight's light floor (or a monitor's signal floor): the ladder asked deeper
            // than the screen goes. Only for a hand setting; automatic stops there quietly.
            LampNotice(text: String(localized: "This screen doesn't go any dimmer."))
                .padding(.top, 14)
        }
        if model.enabled, model.display.resolvedEngine == .gamma,
           let hdr = model.display.displays.first(where: \.hdrActive) {
            LampNotice(text: String(localized: "HDR is on for \(hdr.name). The tint may look washed out."),
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
        Button { Windows.showSettings() } label: {
            ZStack {
                Circle().fill(.white.opacity(hovering ? 0.09 : 0.05))
                Circle().strokeBorder(.white.opacity(0.1))
                Image(systemName: "gearshape").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Lamp.ink.opacity(0.75))
            }
            .frame(width: 26, height: 26)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Settings")
        .accessibilityLabel("Settings")
    }
}
