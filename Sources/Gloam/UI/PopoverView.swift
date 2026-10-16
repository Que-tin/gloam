// The menu-bar window: a lamp. The orb shows what the screen is doing right now and how much
// blue light that saves. The dial and ladder show the live warmth and brightness, so they
// move with the automatic easing; moving them takes over by hand until the next stage begins
// (limits for every night live in Settings). "Auto" hands back at once.

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
    /// Blue light saved right now, by the screen's live tint, rounded to 5% (the estimate is
    /// good to about that).
    private var lessPercent: Int { Int(((1 - Melanopic.relative(model.display.effective)) * 20).rounded() * 5) }
    /// Whether the lamp is lit: Gloam is visibly tinting the screen.
    /// The same test decides what the orb says, so the two never disagree.
    private var lampLit: Bool { !model.isHeld && lessPercent >= 5 }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.bottom, 12)
            notices
            // Off or stepping aside, nothing a control does would show: they rest, inactive.
            // (When off the dial stays enabled so its orb can be the power button; its
            // bindings ignore input while held.)
            dial
                .disabled(model.isHeld && model.enabled)
            BrightnessLadder(brightness: brightness, floor: Stage.brightnessRange.lowerBound, title: "Brightness",
                             kelvin: current.kelvin, core: core)
                .padding(.top, 20)
                .disabled(model.isHeld)
            if model.manual != nil {
                footer.padding(.top, 16)
            }
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
        return LampDial(fraction: warmth, kelvinAt: Self.kelvin(at:), shown: model.display.shown,
                        core: core, bloom: bloom, orbTitle: orb.title, orbCaption: orb.caption,
                        onPower: model.enabled ? nil : { model.enabled = true },
                        stageName: model.stage.title, caption: dialCaption)
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

    /// The dial spans the Kelvin range in mired, where equal turns are equal visible steps.
    static func kelvin(at f: Double) -> Double {
        let (cool, warm) = (Kelvin.mired(Stage.kelvinRange.upperBound), Kelvin.mired(Stage.kelvinRange.lowerBound))
        return 1e6 / (cool + (warm - cool) * min(1, max(0, f)))
    }

    private var warmth: Binding<Double> {
        let (cool, warm) = (Kelvin.mired(Stage.kelvinRange.upperBound), Kelvin.mired(Stage.kelvinRange.lowerBound))
        return Binding(get: { (Kelvin.mired(Stage.kelvinRange.clamp(current.kelvin)) - cool) / (warm - cool) },
                       set: { if !model.isHeld { model.manual = Tint(kelvin: Self.kelvin(at: $0), brightness: current.brightness) } })
    }

    private var brightness: Binding<Double> {
        Binding(get: { current.brightness },
                set: { model.manual = Tint(kelvin: current.kelvin, brightness: $0) })
    }

    // MARK: Words

    private var orb: (title: String, caption: String) {
        if !model.enabled { return ("off", "") }
        if let app = model.excludedFrontmost { return ("aside", "true colour for \(app.name)") }
        if lampLit { return ("−\(lessPercent)%", "blue light") }
        // By day: just when it starts; a state word ("resting", "warms up") read as jargon.
        if let next = model.nextStage { return (Format.time(next.at), "") }
        return ("day", "")
    }

    private var stageTitle: String {
        if !model.enabled { return "Off" }
        if model.excludedFrontmost != nil { return "Stepping aside" }
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
                GearMenu(model: model)
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
        if !lampLit && model.manual == nil { return "" }  // the orb already says when
        guard let next = model.nextStage else { return model.stage.title }
        return "\(next.kind.title) at \(Format.time(next.at))"
    }

    private var footer: some View {
        HStack(spacing: 8) {
            LampLabel(text: model.nextStage.map { "Manual until \(Format.time($0.at))" } ?? "Manual", opacity: 0.6)
            Spacer()
            LampPill(title: "Auto", symbol: "arrow.counterclockwise") { model.manual = nil }
                .fixedSize()
                .help("Back to automatic")
        }
    }

    @ViewBuilder private var notices: some View {
        if model.display.interference {
            LampNotice(text: "Another app keeps changing your screen's colours, so the two take turns. Turn one of them off.")
                .padding(.bottom, 10)
        }
        if model.enabled, model.display.resolvedEngine == .gamma,
           let hdr = model.display.displays.first(where: \.hdrActive) {
            LampNotice(text: "HDR is on for \(hdr.name). The tint may look washed out.",
                       action: ("Use overlay", { model.engine = .overlay }))
                .padding(.bottom, 8)
        }
    }
}

/// Settings, app exceptions and Quit behind one quiet round button.
private struct GearMenu: View {
    let model: AppModel

    var body: some View {
        let label = ZStack {
            Circle().fill(.white.opacity(0.05))
            Circle().strokeBorder(.white.opacity(0.1))
            Image(systemName: "gearshape").font(.system(size: 11, weight: .medium))
                .foregroundStyle(Lamp.ink.opacity(0.75))
        }
        .frame(width: 26, height: 26)

        if Debug.isSnapshot {
            label
        } else {
            Menu {
                if let app = model.frontmost, let name = app.localizedName,
                   !model.excludedApps.contains(where: { $0.bundleID == app.bundleIdentifier }) {
                    Button("True Colour for \(name)") { model.excludeFrontmost() }
                    Divider()
                }
                Button("Settings…") { Windows.showSettings() }
                Divider()
                Button("Quit Gloam") { NSApp.terminate(nil) }
            } label: { label }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Settings, app exceptions and Quit")
                .accessibilityLabel("Settings and more")
        }
    }
}
