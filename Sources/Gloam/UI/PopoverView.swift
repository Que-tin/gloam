// The menu-bar window: a lamp. The orb shows what the screen is doing right now and how much
// blue light still reaches you. The dial and ladder show the live warmth and dimming, so they
// move with the automatic easing; moving them takes over by hand until the next stage begins
// (limits for every night live in Settings). "Auto" hands back at once.
//
// Both controls span exactly what this screen can show: 0% and 100% are its limits (the light
// floor, the smear floor). Fixed ends with a stop partway read as broken, and a drag held
// against the stop buzzed the trackpad with every event.

import GloamCore
import SwiftUI

struct PopoverView: View {
    @Bindable var model: AppModel
    /// The lamp's light, animated separately so it warms up core-first with the bloom
    /// following, and fades with an afterglow. 0 = unlit, 1 = lit.
    @State private var core = 0.0
    @State private var bloom = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// What the controls show: the hand setting, else what the main screen shows this instant.
    private var current: Tint { model.manual ?? model.display.effective }
    /// Blue light still reaching you, by the screen's live tint, rounded to 5% (the estimate is
    /// good to about that). Said as what's left ("20%") rather than what's saved ("−80%"): one
    /// number that only goes down as the evening deepens.
    private var bluePercent: Int {
        Int((Melanopic.relative(model.display.effective, in: model.display.mainColourSpace) * 20).rounded()) * 5
    }
    /// Whether the lamp is lit: Gloam is visibly tinting the screen.
    private var lampLit: Bool { !model.isHeld && bluePercent <= 95 }
    /// The dial's warm end: the warmest the main screen shows at this brightness.
    /// The same test the warmth binding uses, so the dial never takes a drag it then ignores.
    private var dialHasRange: Bool {
        Kelvin.mired(warmEnd) - Kelvin.mired(Stage.kelvinRange.upperBound) >= 0.5
    }
    private var warmEnd: Double {
        max(Stage.kelvinRange.lowerBound, model.display.warmestKelvin(brightness: current.brightness))
    }
    /// The ladder's dim end: the lowest brightness the main screen shows at this warmth.
    private var dimEnd: Double {
        max(Stage.brightnessRange.lowerBound, model.display.brightnessFloor(kelvin: current.kelvin))
    }

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
                .disabled(!canTakeOver || dimEnd > 0.999)
            if model.manual != nil {
                footer.padding(.top, 16)
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
        .background(LampSurface(glow: model.display.shown, lit: max(core, 0.25)))
        .environment(\.colorScheme, .dark)
        .onAppear {
            core = lampLit ? 1 : 0
            bloom = core
        }
        .onChange(of: lampLit) { _, lit in warm(lit) }
    }

    private var dial: some View {
        let orb = self.orb
        let warmEnd = self.warmEnd
        return LampDial(fraction: warmth, kelvinAt: { Self.kelvin(at: $0, warmest: warmEnd) }, shown: model.display.shown,
                        core: core, bloom: bloom, orbTitle: orb.title, orbCaption: orb.caption,
                        onPower: model.enabled ? nil : { model.enabled = true },
                        editable: canTakeOver && dialHasRange,
                        stageName: stageTitle, caption: dialCaption)
    }

    // MARK: The one signature motion

    /// On: the core lights first, the bloom follows 150 ms later with a slight swell.
    /// Off: one continuous afterglow, timed with the screen's own 1 s fade back to daylight: the
    /// bloom goes first, the core dims fast then lingers. (A quick ease-in drop to an ember with
    /// a second fade after it read as a stutter.) Reduce Motion: a crossfade.
    private func warm(_ lit: Bool) {
        if reduceMotion {
            withAnimation(.easeInOut(duration: 0.25)) { core = lit ? 1 : 0; bloom = core }
            return
        }
        if lit {
            withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.45)) { core = 1 }
            withAnimation(.spring(response: 0.6, dampingFraction: 0.7).delay(0.15)) { bloom = 1 }
        } else {
            withAnimation(.easeOut(duration: 0.6)) { bloom = 0 }
            withAnimation(.timingCurve(0.25, 0.1, 0.25, 1, duration: 1.1)) { core = 0 }
        }
    }

    // MARK: Editing

    /// The dial spans daylight to `warmest` in mired, where equal turns are equal visible steps.
    static func kelvin(at f: Double, warmest: Double) -> Double {
        let (cool, warm) = (Kelvin.mired(Stage.kelvinRange.upperBound), Kelvin.mired(warmest))
        return 1e6 / (cool + (warm - cool) * min(1, max(0, f)))
    }

    private var warmth: Binding<Double> {
        let (cool, warm) = (Kelvin.mired(Stage.kelvinRange.upperBound), Kelvin.mired(warmEnd))
        return Binding(get: { warm - cool < 0.5 ? 0 : min(1, max(0, (Kelvin.mired(current.kelvin) - cool) / (warm - cool))) },
                       set: {
                           guard warm - cool >= 0.5 else { return }
                           takeOver(Tint(kelvin: 1e6 / (cool + (warm - cool) * $0), brightness: current.brightness))
                       })
    }

    /// 0 = full brightness … 1 = `dimEnd`.
    private var dimming: Binding<Double> {
        let span = 1 - dimEnd
        return Binding(get: { span < 0.001 ? 0 : min(1, max(0, (1 - current.brightness) / span)) },
                       set: { takeOver(Tint(kelvin: current.kelvin, brightness: 1 - $0 * span)) })
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
        // Off, the readout crossfades to the power icon: it keeps the reading it had, since
        // swapping in a smaller "off" without its caption made the text jump as it faded.
        if let app = model.excludedFrontmost {
            return (String(localized: "aside"), String(localized: "true colour for \(app.name)"))
        }
        return (Format.percent(Double(bluePercent) / 100), String(localized: "blue light"))
    }

    private var stageTitle: String {
        if !model.enabled { return String(localized: "Off") }
        if model.excludedFrontmost != nil { return String(localized: "Stepping aside") }
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
                PowerSwitch(on: $model.enabled, kelvin: model.display.shown.kelvin)
            }
        }
        .overlay {
            HStack(spacing: 6) {
                Circle().fill(Color.kelvin(model.display.shown.kelvin)).frame(width: 5, height: 5)
                    .shadow(color: .kelvin(model.display.shown.kelvin), radius: 3)
                    .opacity(0.35 + 0.65 * core)
                LampLabel(text: stageTitle, opacity: 0.75)
            }
            .offset(x: -5)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Now: \(stageTitle)")
        }
    }

    /// What changes next, and when: the one question a schedule raises. (A separate "next"
    /// line and an evening timeline strip were tried; both said what this says, louder.)
    private var dialCaption: String {
        guard let next = model.nextStage else { return "" }  // the header already names the stage
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
        if model.enabled, model.display.smearLimits(model.target) {
            // Only a built-in display's backlight is read, so only there does turning it down help.
            LampNotice(text: model.display.mainIsBuiltin
                ? String(localized: "Your screen is bright, so going warmer would make moving text smear. Lower it with the brightness keys to go further.")
                : String(localized: "Going further would make moving text smear on this display."))
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
