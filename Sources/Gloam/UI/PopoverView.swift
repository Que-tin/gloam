// The menu-bar window: a lamp. The orb glows with what the screen really shows and says how
// much blue light reaches you once it gets there. The dial shows the warmth asked for, the ladder
// the dimming of the screen the popover is open on: the plan, plus what was moved by hand tonight.
// Moving them shifts that screen (or every screen's warmth) away from the plan, and the shift rides
// along with the evening until its morning ends it (`Shift`); "Auto" hands back at once.
//
// Both controls are positions. The ladder's scale is the schedule's own, as in Settings, and never
// moves when the user's brightness does (a key press moves it by the press alone): ends that
// followed the screen made the knob wander, and nobody could tell why. Each screen takes it the
// same share of the way to its own darkest. The dial spans the popover screen's warm range (to
// its smear limit at the user's brightness), so all of it does something on a MacBook too.

import GloamCore
import SwiftUI

struct PopoverView: View {
    @Bindable var model: AppModel
    /// The lamp's light, animated separately so it warms up core-first with the bloom
    /// following, and fades with an afterglow. 0 = unlit, 1 = lit.
    @State private var core = 0.0
    @State private var bloom = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// When the dial was last turned by hand (`dialPosition`).
    @State private var turnedAt = Date.distantPast

    /// The dial's position on the popover screen's warm range: what the screens show this instant
    /// (following the fades, so the knob glides with them: switching on and off, Auto). While it
    /// is being turned, where it is heading: following the 0.15 s ease, the knob lagged the finger
    /// and a drag compared against the lagging value, a detent firing twice per notch. Keyed on
    /// the hand rather than on a warmth shift existing: with one, switching off snapped the knob
    /// instead of gliding; a turn onto the plan (no shift) lagged again. Not Settings' "Preview
    /// tonight": the knob stays at what's asked without it (the plan and the dial's shift), and rests.
    private var dialPosition: Double {
        if model.preview != nil { return model.display.dialPosition(screen, asked: model.asked) }
        return model.display.dialPosition(screen, heading: Date().timeIntervalSince(turnedAt) < 0.6)
    }
    /// The screen whose dimming the ladder shows and moves: the one the popover is open on (its
    /// menu bar's), or, switched off in Settings, the main tinted one (named, so it's clear).
    private var screen: CGDirectDisplayID {
        let tinted = model.display.displays.filter { model.strength(for: $0) > 0 }
        let here = MenuBarPanel.shared.screenID ?? CGMainDisplayID()
        if tinted.contains(where: { $0.id == here }) { return here }
        return tinted.first { $0.id == CGMainDisplayID() }?.id ?? tinted.first?.id ?? here
    }
    /// Named over the ladder when more than one screen is tinted, or when it moves another screen
    /// than the popover's own (that one is switched off in Settings): which one it moves. Two of
    /// the same model are numbered, in the order macOS lists them.
    private var screenName: String? {
        let tinted = model.display.displays.filter { model.strength(for: $0) > 0 }
        let here = MenuBarPanel.shared.screenID ?? CGMainDisplayID()
        guard tinted.count > 1 || screen != here, let mine = tinted.first(where: { $0.id == screen }) else { return nil }
        let twins = tinted.filter { $0.name == mine.name }
        guard twins.count > 1, let i = twins.firstIndex(where: { $0.id == screen }) else { return mine.name }
        return String(localized: "\(mine.name) (\(i + 1))", comment: "Two monitors of the same model: Studio Display (2)")
    }
    /// Why the ladder can't act, said in its help: every screen switched off in Settings.
    private var ladderUnavailable: String? {
        model.display.displays.contains { model.strength(for: $0) > 0 } ? nil
            : String(localized: "Every screen is switched off in Settings.")
    }
    /// Blue light reaching you once the screen gets where it is going, after its limits, rounded
    /// to 5% (the estimate is good to about that). Said as what's left ("20%") rather than what's
    /// saved ("−80%"). The destination rather than every step of a fade, so a switch reads as one
    /// change of number, faded, instead of twenty.
    /// Counted against the screen as it was by day (`lightSinceDay`), so the user's own brightness
    /// counts too, while by day it still reads 100 %. The ladder's screen: the two never disagree.
    private var blueShare: Double {
        let strength = model.display.displays.first { $0.id == screen }.map { model.strength(for: $0) } ?? 1
        return Melanopic.relative(model.display.onScreen(.mix(.neutral, model.target, strength), screen, heading: true),
                                  in: model.display.colourSpace(of: screen)) * model.display.lightSinceDay(on: screen)
    }
    /// What the popover's screen shows: the orb's glow, the panel's and the header's colours.
    private var glow: Tint { model.display.effective(on: screen) }
    private static func percent(_ share: Double) -> Int { Int((share * 20).rounded()) * 5 }
    /// The orb's number. Under 5 % it says so ("<5 %"): a plain "5 %" suggested more could be
    /// taken away, and "0 %" would claim none is left, which no screen that's on can do.
    private static func blueText(_ share: Double) -> String {
        share < 0.05 ? String(localized: "<\(Format.percent(0.05))", comment: "less than 5 %") : Format.percent(Double(percent(share)) / 100)
    }
    /// Whether the lamp is lit: Gloam is visibly tinting the screen.
    private var lampLit: Bool { !model.isHeld && Self.percent(blueShare) <= 95 }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.bottom, 12)
            // Off, the controls stay live: reaching for one means "this, now", so it turns Gloam
            // back on (disabled controls read as broken). Paused for an app or by a Focus, or during
            // Settings' preview, nothing they did would show, so they rest.
            dial
                .disabled(!canTakeOver)
            if let screenName {
                LampLabel(text: screenName, opacity: 0.5).lineLimit(1).padding(.top, 14)
                    .accessibilityHidden(true)  // the ladder says it: "Dimming, <screen>"
            }
            DimmingLadder(dimming: dimming, kelvin: glow.kelvin, core: core,
                          editable: model.display.canDim(screen),  // else nothing to dim
                          beyond: model.display.ladderPosition(screen) > 1, screenName: screenName,
                          unavailable: ladderUnavailable)
                .padding(.top, screenName == nil ? 20 : 6)
                .disabled(!canTakeOver)
            // One status row at most: something moved by hand tonight, a pause for the app in
            // front, a timed pause (before a Focus's, so its Resume stays in reach), or a Focus's
            // pause, which also ends with the Focus.
            if model.hasShifts, !model.isHeld, model.preview == nil {
                statusRow(String(localized: "Manual"), String(localized: "Auto"), "arrow.counterclockwise") { model.backToPlan() }
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
        .background(LampSurface(glow: glow, lit: max(core, 0.25)))
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
        LampDial(fraction: warmth, kelvinAt: { model.display.kelvin(share: $0, on: screen) }, shown: glow,
                 core: core, bloom: bloom, orbTitle: Self.blueText(blueShare),
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

    /// The warmth on the popover screen's own range: 0 % daylight, 100 % the warmest that screen
    /// shows at the user's brightness (its smear limit; a monitor without one, the whole scale).
    /// The plan sits at its share of it, at most 100 %: on the fixed scale a MacBook's limit sat a
    /// quarter of the way along, and the rest of the dial did nothing. Off, the dial shows
    /// daylight, and a move switches Gloam on from there (`AppModel.setWarmth`).
    private var warmth: Binding<Double> {
        Binding(get: { dialPosition },
                set: { w in
                    guard canTakeOver else { return }
                    // A step (arrows, scroll, VoiceOver) taken from where the dial is heading, not
                    // from the knob: mid-fade, not from mid-way.
                    let knob = dialPosition
                    let step = abs(w - knob) <= 0.021
                    let base = model.display.dialPosition(screen, heading: true)
                    let fromHeading = step && model.enabled && model.display.isFading
                    turnedAt = Date()
                    model.setWarmth(fromHeading ? min(1, max(0, base + w - knob)) : w, on: screen)
                })
    }

    /// This screen's position on the schedule's scale, plan plus its shift: it takes it the same
    /// share of the way to its own darkest, so 100 % is as dim as this screen goes; a key press
    /// moves it by the press alone. Below the floor (a press there) it shows 100 %.
    private var dimming: Binding<Double> {
        Binding(get: {
                    // During Settings' preview the screens show the preview: the ladder shows the
                    // plan and this screen's shift as asked.
                    min(1, model.preview == nil ? model.display.ladderPosition(screen)
                                                : model.display.ladderPosition(screen, asked: model.asked))
                },
                set: { d in
                    // Off, the ladder shows 0 and a move switches Gloam on from there
                    // (`AppModel.setDimming`).
                    guard canTakeOver else { return }
                    model.setDimming(d, on: screen)
                })
    }

    /// The controls can move: Gloam is on or can be switched on by them, and no app in front is
    /// holding it off (and Welcome is done, though the popover only exists after it).
    private var canTakeOver: Bool { model.hasOnboarded && !model.pausedAside && model.preview == nil }

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
                // Off is by hand here (`run(.off)`): on again, the evening starts on Auto.
                PowerSwitch(on: Binding(get: { model.enabled }, set: { $0 ? (model.enabled = true) : model.run(.off) }),
                            kelvin: glow.kelvin)
            }
        }
        .overlay {
            // The word rolls into the next as the orb's numbers do (a fade read as a flicker beside
            // them); the dot glides along as its width changes. Reduce Motion: no roll.
            HStack(spacing: 6) {
                Circle().fill(Color.kelvin(glow.kelvin)).frame(width: 5, height: 5)
                    .shadow(color: .kelvin(glow.kelvin), radius: 3)
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
