// "Light as material": the popover is a lamp in a dark room. Its controls are made of the
// light they set: the orb glows in the screen's current colour and brightness, the dial's
// ticks are painted in the temperature each stands for, and the dimming ladder dims its
// own light. Dark by design: Gloam lives at night, and a light variant would fight the glow.
// By day the lamp is unlit at 100% blue light; the evening is the event.

import AppKit
import GloamCore
import SwiftUI

enum Lamp {
    static let surface = Color(rgb: 0x0D0B0A)
    static let well = Color(rgb: 0x050404)
    /// Warm off-white. Secondary text never drops below 0.6 (≈ 6:1 on the surface).
    static let ink = Color(rgb: 0xF4E9DC)
    static let amber = Color(rgb: 0xFF9A3C)
    static let label = Font.system(size: 10, weight: .medium, design: .monospaced)

    /// Whether focus just arrived from the keyboard (Tab, arrows). Clicking a control also
    /// focuses it, and a focus ring after a mouse click reads as a glitch, so rings show only
    /// for keyboard focus.
    static var focusFromKeyboard: Bool { NSApp.currentEvent?.type == .keyDown }

    /// A tick on a trackpad that supports it; silent elsewhere.
    static func detent() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}

/// Mono caption in the lamp's label style. Like every lamp part taking a `String`, it shows it
/// verbatim: callers pass text already localised (`String(localized:)`).
struct LampLabel: View {
    let text: String
    var opacity = 0.6
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Text(text).font(Lamp.label).tracking(1.2).textCase(.uppercase)
            .foregroundStyle(Lamp.ink.opacity(contrast == .increased ? max(opacity, 0.9) : opacity))
    }
}

/// The panel behind everything: near-black, lit from the lamp, carrying the evening's tint.
struct LampSurface: View {
    let glow: Tint
    let lit: Double

    var body: some View {
        ZStack {
            Lamp.surface
            RadialGradient(colors: [Color.kelvin(glow.kelvin).opacity(0.2 * glow.brightness * lit), .clear],
                           center: UnitPoint(x: 0.5, y: 0.28), startRadius: 0, endRadius: 330)
            LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .center, endPoint: .bottom)
            Grain().opacity(0.12)
        }
    }
}

/// Fine film grain, so the dark surface never looks 100% smooth (the way Arc grains its
/// backgrounds). One deterministic 128 px noise tile, generated once and tiled: drawing
/// thousands of dots per frame cost more and still read as sparse speckles.
struct Grain: View {
    private static let tile: NSImage = {
        let side = 128
        var seed: UInt64 = 0x9E3779B97F4A7C15
        var pixels = [UInt8](repeating: 0, count: side * side)
        for i in pixels.indices {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            pixels[i] = UInt8(truncatingIfNeeded: seed >> 56)
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: side,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        // Half-size points: one noise pixel per Retina pixel, as fine as film grain gets.
        return NSImage(cgImage: image, size: NSSize(width: side / 2, height: side / 2))
    }()

    var body: some View {
        Image(nsImage: Self.tile)
            .resizable(resizingMode: .tile)
            .blendMode(.overlay)
            .allowsHitTesting(false)
    }
}

/// A pilot light rather than a toggle: the lamp is either lit or it isn't.
struct PowerSwitch: View {
    @Binding var on: Bool
    let kelvin: Double
    /// Hover text: what clicking does. Welcome's login switch passes its own.
    var help: String?
    /// What the knob shows: follows `on` one beat later, in its own animation. Wrapping the toggle
    /// in withAnimation animated everything it changes (words morphed through each other, the
    /// popover's content slid inside a panel that resizes at once), and an animation keyed to
    /// `on` here still caught the panel's resize and dropped the switch in from above.
    @State private var shown: Bool?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let c = Color.kelvin(kelvin)
        let on = shown ?? self.on
        ZStack(alignment: on ? .trailing : .leading) {
            Capsule().fill(Lamp.well)
                .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
                .overlay(Capsule().fill(c.opacity(on ? 0.16 : 0)))
            ZStack {
                Circle().fill(LinearGradient(colors: [Color(rgb: 0x3A3532), Color(rgb: 0x1C1918)],
                                             startPoint: .top, endPoint: .bottom))
                Circle().strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                Circle().fill(on ? c : Color(rgb: 0x3A3330)).frame(width: 5, height: 5)
                    .shadow(color: on ? c : .clear, radius: 2.5)
                    .shadow(color: on ? c.opacity(0.8) : .clear, radius: 6)
            }
            .frame(width: 18, height: 18)
            .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
            .padding(3)
        }
        .frame(width: 40, height: 24)
        .lampPress(Capsule()) { self.on.toggle() }
        // Words follow the real state at once; only the knob's picture lags a beat.
        .help(help ?? (self.on ? String(localized: "Turn Gloam off") : String(localized: "Turn Gloam on")))
        .accessibilityLabel("Gloam")
        .accessibilityValue(self.on ? String(localized: "On") : String(localized: "Off"))
        .accessibilityAddTraits(.isToggle)
        .onChange(of: self.on) { _, now in
            DispatchQueue.main.async { withAnimation(reduceMotion ? nil : .snappy) { shown = now } }
        }
    }
}

// MARK: - The dial

/// The warmth dial around the glowing orb. The orb shows what the screen is doing now; the
/// dial shows and sets the warmth, 0 (cool end) … 1 (warm end); `kelvinAt` maps a position to
/// Kelvin (mired-even, so equal turns are equal visible steps).
struct LampDial: View {
    @Binding var fraction: Double
    let kelvinAt: (Double) -> Double
    /// What the orb glows with: the screen's tint this instant.
    let shown: Tint
    /// 0 = the lamp is unlit (off, paused for an app, or daytime), 1 = lit. Animated by `PopoverView.warm`.
    let core: Double
    let bloom: Double
    let orbTitle: String
    let orbCaption: String
    /// When set, the orb is a quiet power button (Gloam is off) instead of a readout.
    var onPower: (() -> Void)?
    /// False when turning the ring would change nothing (an app in front pauses Gloam): no
    /// drag, no cursor, no detents. A drag the binding ignored used to buzz the trackpad on
    /// every event.
    var editable = true
    /// Spoken by VoiceOver after the dial's name: "Warmth, Wind-down".
    let stageName: String
    /// Under the readout: what changes next and when ("Night at 22:00").
    let caption: String

    @GestureState private var dragging = false
    @State private var hovering = false
    @FocusState private var focused: Bool
    @State private var ring = false  // keyboard focus only
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let arcStart = 135.0, arcSweep = 270.0
    static let ringRadius = 88.0, orbRadius = 56.0, ticks = 49
    /// Drags and hovers count only on the ring band, not on the orb or the panel corners.
    static let band = 62.0...114.0

    /// Dial fraction for a pointer angle (degrees, screen coordinates). In the open gap at the
    /// bottom the value holds at whichever end it was nearer, so a drag that overshoots never
    /// flips from ember to daylight.
    static func fraction(angle: Double, previous: Double) -> Double {
        var a = (angle - arcStart).truncatingRemainder(dividingBy: 360)
        if a < 0 { a += 360 }
        if a > arcSweep { return previous > 0.5 ? 1 : 0 }
        return a / arcSweep
    }

    var body: some View {
        let kelvin = kelvinAt(fraction)
        let edit = Color.kelvin(kelvin)
        let f = fraction
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: Self.ringRadius + 18)
            ZStack {
                ZStack {
                    bloomLayer.position(center)
                    ticks(center: center, f: f)
                    track(center: center, f: f, color: edit)
                    knob(center: center, f: f, color: edit)
                    readout(kelvin).position(x: center.x, y: center.y + Self.ringRadius + 4)
                    // Which end is which, in words rather than Kelvin numbers.
                    LampLabel(text: String(localized: "cool")).position(x: center.x - 78, y: center.y + 86)
                    LampLabel(text: String(localized: "warm")).position(x: center.x + 78, y: center.y + 86)
                }
                .contentShape(Rectangle())
                .gesture(drag(center: center))
                .onContinuousHover { phase in
                    if case .active(let p) = phase, editable {
                        let inBand = Self.band.contains(hypot(p.x - center.x, p.y - center.y))
                        if inBand != hovering {
                            hovering = inBand
                            (inBand ? NSCursor.openHand : NSCursor.arrow).set()
                        }
                    } else if hovering {
                        hovering = false
                        NSCursor.arrow.set()
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Warmth, \(stageName)")
                .accessibilityValue("\(Light.name(kelvin).lowercased()), \(Format.kelvin(kelvin))")
                .accessibilityAdjustableAction { direction in nudge(direction == .increment ? 0.02 : -0.02) }

                orb
                    .frame(width: Self.orbRadius * 2, height: Self.orbRadius * 2)
                    .position(center)
            }
        }
        .frame(height: 2 * Self.ringRadius + 42)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onChange(of: focused) { _, now in ring = now && Lamp.focusFromKeyboard }
        .onMoveCommand { direction in
            ring = true
            switch direction {
            case .left, .down: nudge(-0.02)
            case .right, .up: nudge(0.02)
            @unknown default: break
            }
        }
        .onScrollWheel { delta in nudge(delta > 0 ? 0.01 : -0.01) }
        .help("Drag the ring or scroll to set warmth")
        .onChange(of: dragging) { _, now in
            if !now {
                hovering = false
                NSCursor.arrow.set()
            }
        }
    }

    /// Steps warmer (+) or cooler (−).
    private func nudge(_ delta: Double) {
        guard editable else { return }
        let new = min(1, max(0, fraction + delta))
        if new != fraction { fraction = new }
    }

    private func drag(center: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($dragging) { g, state, _ in
                // A press that starts off the ring (on the orb, in a corner) isn't a dial drag.
                if editable, Self.band.contains(hypot(g.startLocation.x - center.x, g.startLocation.y - center.y)) {
                    state = true
                }
            }
            .onChanged { g in
                guard editable, Self.band.contains(hypot(g.startLocation.x - center.x, g.startLocation.y - center.y)) else { return }
                NSCursor.closedHand.set()
                let angle = atan2(g.location.y - center.y, g.location.x - center.x) * 180 / .pi
                let new = Self.fraction(angle: angle, previous: fraction)
                guard new != fraction else { return }
                let tick = { (f: Double) in Int(f * Double(Self.ticks - 1)) }
                if tick(new) != tick(fraction) { Lamp.detent() }
                fraction = new
            }
    }

    private var bloomLayer: some View {
        let glow = Color.kelvin(shown.kelvin)
        let b = shown.brightness * bloom
        return Circle()
            .fill(RadialGradient(colors: [glow.opacity(0.55 * b), glow.opacity(0.12 * b), .clear],
                                 center: .center, startRadius: Self.orbRadius * 0.6, endRadius: 132))
            .frame(width: 264, height: 264)
            .scaleEffect(0.96 + 0.04 * bloom)
            .blur(radius: 6)
            .drawingGroup()
            .allowsHitTesting(false)
    }

    /// The light's name tight under the ring, a tracked caption beneath. No Kelvin number:
    /// equal turns are equal perceived steps, which in Kelvin read as wildly uneven jumps.
    private func readout(_ kelvin: Double) -> some View {
        VStack(spacing: 3) {
            Text(Light.name(kelvin))
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(Lamp.ink)
                .shadow(color: Color.kelvin(kelvin).opacity(0.6), radius: 6)
                .contentTransition(.opacity)
            if !caption.isEmpty { LampLabel(text: caption) }
        }
        .fixedSize()
        .help("\(Format.kelvin(kelvin)). Changing it holds until morning (or, by day, until evening).")
    }

    /// Flattened into one layer: 49 capsules redrawn every frame of a fade or drag.
    private func ticks(center: CGPoint, f: Double) -> some View {
        ZStack { ForEach(0..<Self.ticks, id: \.self) { i in
            let t = Double(i) / Double(Self.ticks - 1)
            let major = i % 9 == 0
            let isLit = t <= f + 0.001
            Capsule()
                .fill(Color.kelvin(kelvinAt(t)).opacity(isLit ? 0.5 + 0.35 * core : 0.22))
                .frame(width: major ? 1.6 : 1.1, height: major ? 9 : 5)
                .offset(y: -(Self.ringRadius + (major ? 10 : 8)))
                .rotationEffect(.degrees(Self.arcStart + 90 + t * Self.arcSweep))
                .position(center)
        } }
        .drawingGroup()
    }

    private func track(center: CGPoint, f: Double, color: Color) -> some View {
        ZStack {
            Circle().trim(from: 0, to: Self.arcSweep / 360)
                .stroke(.white.opacity(0.06), style: StrokeStyle(lineWidth: 6, lineCap: .round))
            Circle().trim(from: 0, to: f * Self.arcSweep / 360)
                .stroke(AngularGradient(colors: [Color.kelvin(6500).opacity(0.25), color], center: .center,
                                        startAngle: .degrees(0), endAngle: .degrees(max(1, f * Self.arcSweep))),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .shadow(color: color.opacity(0.9 * max(core, 0.4)), radius: 4)
                .opacity(0.5 + 0.5 * core)
        }
        .rotationEffect(.degrees(Self.arcStart))
        .frame(width: Self.ringRadius * 2, height: Self.ringRadius * 2)
        .position(center)
    }

    private func knob(center: CGPoint, f: Double, color: Color) -> some View {
        let a = (Self.arcStart + f * Self.arcSweep) * .pi / 180
        let active = dragging || ring
        return ZStack {
            Circle().fill(color.opacity(ring ? 0.7 : 0.4)).frame(width: ring ? 36 : 30, height: ring ? 36 : 30).blur(radius: 6)
            Circle().fill(RadialGradient(colors: [.white, color], center: .center, startRadius: 0, endRadius: 8))
                .frame(width: 14, height: 14)
                .overlay(Circle().strokeBorder(.white.opacity(ring ? 1 : 0.7), lineWidth: ring ? 1.5 : 0.6))
                .shadow(color: color, radius: 5)
                .scaleEffect(active && !reduceMotion ? 1.2 : 1)
                .animation(reduceMotion ? nil : .snappy, value: active)
        }
        // While the lamp is unlit: present, but not glowing.
        .opacity(0.55 + 0.45 * max(core, active ? 1 : 0))
        .position(x: center.x + cos(a) * Self.ringRadius, y: center.y + sin(a) * Self.ringRadius)
    }

    /// The reading, "20%" or "<5%".
    private var orbHeadline: Text {
        Text(orbTitle).font(.system(size: 28, weight: .medium, design: .rounded).monospacedDigit())
    }

    /// The lamp face: colour is the screen's warmth now, light is its brightness.
    private var orb: some View {
        let k = shown.kelvin
        let glow = Color.kelvin(k)
        let b = shown.brightness * core
        // Ink etched dark into a bright lens, or light on a dim one. Measured on the core,
        // which is far brighter than the rim.
        let hot = Kelvin.swatch(k)
        let white = { (v: Double) in v + (1 - v) * 0.45 }  // the core's whitened colour, as drawn
        let coreLuma = (0.2126 * white(hot.red) + 0.7152 * white(hot.green) + 0.0722 * white(hot.blue)) * (0.5 + 0.5 * shown.brightness)
        let etched = core > 0.5 && coreLuma > 0.45
        let ink = etched ? Color(rgb: 0x3B1A06) : Lamp.ink
        let r = Self.orbRadius
        let face = ZStack {
            Circle().fill(Color(rgb: 0x14100E))
            Circle()
                .fill(RadialGradient(colors: [Color.kelvin(k, whiten: 0.45), Color.kelvin(k, whiten: 0.08), glow,
                                              Color.kelvin(k, scale: 0.78)],
                                     center: UnitPoint(x: 0.5, y: 0.45), startRadius: 0, endRadius: r))
                .opacity(core * (0.5 + 0.5 * shown.brightness))
            ForEach(1..<9) { i in
                Circle().stroke(.black.opacity(0.03), lineWidth: 0.6)
                    .frame(width: r * 2 * Double(i) / 9, height: r * 2 * Double(i) / 9)
            }
            Ellipse()
                .fill(LinearGradient(colors: [.white.opacity(0.06 + 0.16 * core), .clear], startPoint: .top, endPoint: .bottom))
                .frame(width: r * 1.1, height: r * 0.55)
                .offset(y: -r * 0.5)
                .blur(radius: 3)
            Circle().fill(RadialGradient(colors: [.clear, .black.opacity(0.06)], center: .center,
                                         startRadius: r * 0.8, endRadius: r))
            Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.45), .clear, glow.opacity(0.05 + 0.35 * core)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 0.8)
            // Off, it reads 100 % and a click turns Gloam on. (A power icon or an "off" swapped in
            // here broke up the lamp's own decay; the reading fading in place is the motion.)
            readoutText(r: r, ink: ink, etched: etched)
        }
        .compositingGroup()
        .shadow(color: glow.opacity(0.8 * b), radius: 14)
        .shadow(color: glow.opacity(0.5 * b * bloom), radius: 40)

        return face
            .contentShape(Circle())
            .onTapGesture { onPower?() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(onPower == nil ? "\(orbTitle), \(orbCaption)" : String(localized: "Turn Gloam on"))
            .accessibilityAddTraits(onPower == nil ? [] : .isButton)
            .accessibilityAction { onPower?() }
            .help(onPower == nil
                ? String(localized: "How much of the blue-rich light that keeps you alert in the evening (melanopic light) still reaches you, compared with this screen untinted at its daytime brightness.")
                : String(localized: "Turn Gloam on"))
    }

    private func readoutText(r: CGFloat, ink: Color, etched: Bool) -> some View {
            // Numbers roll from one to the next (numericText), on a switch and while dragging alike.
            // Only numbers belong here: a word rolling into a number overprints.
            VStack(spacing: 2) {
                orbHeadline
                    .tracking(-1)
                    .lineLimit(1)
                    // 28 pt keeps "100%" inside this padded frame, so percentages never shrink
                    // or jump.
                    .minimumScaleFactor(0.5)
                    .frame(maxWidth: r * 1.7)
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .snappy, value: orbTitle)
                if !orbCaption.isEmpty {
                    Text(orbCaption)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .lineLimit(2)  // "paused for Adobe Lightroom Classic"
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.8)
                        .opacity(0.85)
                        .frame(width: r * 1.8)
                        .contentTransition(.opacity)  // "blue light" ↔ "paused for …"
                        .animation(reduceMotion ? nil : .default, value: orbCaption)
                }
            }
            .foregroundStyle(ink.opacity(core > 0.5 ? 0.92 : 0.75))
            .blendMode(etched ? .multiply : .normal)
            .offset(y: 2)
    }
}

/// Replaces content when `key` changes by fading the old out, then the new in: a crossfade of
/// two words overprints them halfway. Changes in quick succession (a drag) swap instantly, so
/// the reading keeps up instead of stacking fades. Reduce Motion: always instant.
struct SwapFade: ViewModifier {
    let key: String
    /// When the key last changed, kept outside SwiftUI's state so the body can tell, for the
    /// very change it renders, whether it came quickly after the previous one. (State updated
    /// in onChange arrives one change late.)
    private final class Pace {
        var key: String?, last = Date.distantPast, rapid = false
        func note(_ new: String) -> Bool {
            guard let key, key != new else {
                // Settled again: any redraw after a pause re-arms the fade, so the reading on
                // screen leaves with a fade too, not with the instant swap of the last drag.
                if Date().timeIntervalSince(last) > 0.4 { rapid = false }
                key = new
                return rapid
            }
            rapid = Date().timeIntervalSince(last) < 0.4
            (self.key, last) = (new, Date())
            return rapid
        }
    }
    @State private var pace = Pace()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let rapid = pace.note(key)
        return ZStack {
            content
                .id(key)
                .transition(reduceMotion || rapid ? .identity : .asymmetric(
                    insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.15)),
                    removal: .opacity.animation(.easeIn(duration: 0.15))))
        }
        .animation(reduceMotion || rapid ? nil : .default, value: key)
    }
}

extension View {
    func swapFade(_ key: String) -> some View { modifier(SwapFade(key: key)) }
}

// MARK: - Dimming ladder

/// Cells rising like a volume wedge, 0 (full brightness) … 1 (as dim as this screen goes);
/// each lit cell glows as bright as the screen it stands for, so the further the ladder goes
/// the dimmer its own light. Each cell is 5%: the lit cells match the number to half a cell.
/// "Dimming" rather than "brightness": what the control does is take light away, and the
/// screen's own brightness is a different setting.
struct DimmingLadder: View {
    @Binding var dimming: Double
    let kelvin: Double
    let core: Double
    @GestureState private var dragging = false
    @FocusState private var focused: Bool
    @State private var ring = false  // keyboard focus only
    @Environment(\.isEnabled) private var isEnabled
    static let cells = 20

    private var litCells: Int { Int((dimming * Double(Self.cells)).rounded()) }

    var body: some View {
        let c = Color.kelvin(kelvin)
        VStack(spacing: 7) {
            HStack {
                LampLabel(text: String(localized: "Dimming"))
                Spacer()
                // Changes directly: it follows every frame of a screen fade, where rolling digits
                // never settle long enough to read (the orb, which rolls, shows the destination).
                Text(Format.percent(dimming))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Lamp.ink.opacity(0.9))
            }
            GeometryReader { geo in
                HStack(spacing: 3) {
                    ForEach(0..<Self.cells, id: \.self) { i in
                        let on = i < litCells
                        let level = 1 - 0.65 * Double(i + 1) / Double(Self.cells)
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(on ? c.opacity(level * (0.5 + 0.5 * core)) : .white.opacity(0.07))
                            .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .strokeBorder(.white.opacity(on ? 0.25 : 0.05), lineWidth: 0.5))
                            .frame(height: 7 + 13 * Double(i + 1) / Double(Self.cells))
                    }
                }
                // One glow for the row rather than 20 shadows; it follows each lit cell's light.
                .compositingGroup()
                .shadow(color: c.opacity(0.75 * core), radius: 4)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .updating($dragging) { _, state, _ in state = true }
                    .onChanged { g in
                        set(cells: Int((g.location.x / geo.size.width * Double(Self.cells) + 0.5).rounded(.down)))
                    })
                .onHover { inside in (inside && isEnabled ? NSCursor.pointingHand : NSCursor.arrow).set() }
            }
            .frame(height: 20)
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Lamp.well.opacity(0.8)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(ring ? Color.kelvin(kelvin).opacity(0.8)
                                   : Color.white.opacity(0.08), lineWidth: ring ? 1.2 : 0.8))
        }
        .opacity(isEnabled ? 1 : 0.5)  // a disabled ladder must not look like a live one
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onChange(of: focused) { _, now in ring = now && Lamp.focusFromKeyboard }
        .onMoveCommand { direction in
            ring = true
            switch direction {
            case .left, .down: set(cells: litCells - 1)
            case .right, .up: set(cells: litCells + 1)
            @unknown default: break
            }
        }
        .onScrollWheel { delta in set(cells: litCells + (delta > 0 ? 1 : -1)) }
        .help("How far Gloam dims below your own brightness: 0% leaves your screen as you set it; 100% is as dim as it goes. Drag, click, scroll or use the arrow keys.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Dimming")
        .accessibilityValue(Format.percent(dimming))
        .accessibilityAdjustableAction { direction in set(cells: litCells + (direction == .increment ? 1 : -1)) }
    }

    private func set(cells: Int) {
        let n = min(Self.cells, max(0, cells))
        // Scrolling reaches here even while disabled (an AppKit view catches it): no detent then.
        guard isEnabled, n != litCells else { return }
        dimming = Double(n) / Double(Self.cells)
        // A detent only for a step that happened (a screen that can't dim stays full).
        if litCells == n { Lamp.detent() }
    }
}

// MARK: - Small parts

/// A quiet pill button in the lamp's style.
struct LampPill: View {
    let title: String
    var symbol: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).font(.system(size: 8, weight: .bold)) }
            Text(title).font(Lamp.label).tracking(0.9).textCase(.uppercase)
        }
        .foregroundStyle(Lamp.ink.opacity(hovering ? 0.95 : 0.75))
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Capsule().fill(.white.opacity(hovering ? 0.08 : 0.045)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.1)))
        .lampPress(Capsule(), action: action)
        .onHover { hovering = $0 }
    }
}

/// The lamp's primary action: a lit capsule.
struct LampButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let c = Color.kelvin(2700)
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(rgb: 0x2A1405))
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(Capsule().fill(LinearGradient(colors: [Color.kelvin(3000, scale: 1.1), c],
                                                          startPoint: .top, endPoint: .bottom)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 0.6))
                .shadow(color: c.opacity(hovering ? 0.6 : 0.35), radius: hovering ? 14 : 10)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A one-line heads-up with an optional action, lit by a small amber LED.
struct LampNotice: View {
    let text: String
    var action: (String, () -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Lamp.amber).frame(width: 5, height: 5).shadow(color: Lamp.amber, radius: 4)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Lamp.ink.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let (title, perform) = action {
                Text(title).font(Lamp.label).tracking(1).textCase(.uppercase)
                    .foregroundStyle(Color(rgb: 0xFFB070))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Capsule().fill(Lamp.amber.opacity(0.16)))
                    .fixedSize()
                    .lampPress(Capsule(), action: perform)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .accessibilityElement(children: .combine)
    }
}

/// A lamp part as a button that Tab always reaches. A SwiftUI `Button` gets keyboard focus only
/// when the Mac's Keyboard navigation setting is on, which left the popover's switch and gear out
/// of reach while the dial and ladder (focusable views) were not. Space or Return presses it; the
/// ring shows for keyboard focus only, like the dial's.
private struct LampPress<S: Shape>: ViewModifier {
    let shape: S
    let action: () -> Void
    @FocusState private var focused: Bool
    @State private var ring = false

    func body(content: Content) -> some View {
        content
            .contentShape(shape)
            .onTapGesture(perform: action)
            .overlay(shape.stroke(Lamp.ink.opacity(ring ? 0.8 : 0), lineWidth: 1.5).padding(-3))
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onChange(of: focused) { _, now in ring = now && Lamp.focusFromKeyboard }
            .onKeyPress(keys: [.space, .return]) { _ in
                action()
                return .handled
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }
}

extension View {
    func lampPress(_ shape: some Shape, action: @escaping () -> Void) -> some View {
        modifier(LampPress(shape: shape, action: action))
    }

    /// Vertical scroll-wheel / two-finger swipe over a control, as a step up or down.
    /// Skipped in debug snapshots, where AppKit-backed views can't be rendered.
    @ViewBuilder func onScrollWheel(_ handler: @escaping (CGFloat) -> Void) -> some View {
        if Debug.isSnapshot { self } else { background(ScrollCatcher(handler: handler)) }
    }
}

/// SwiftUI has no scroll-wheel event on macOS 14; a transparent NSView catches it.
private struct ScrollCatcher: NSViewRepresentable {
    let handler: (CGFloat) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.handler = handler
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) { view.handler = handler }

    final class CatcherView: NSView {
        var handler: ((CGFloat) -> Void)?
        private var accumulated: CGFloat = 0

        override func scrollWheel(with event: NSEvent) {
            accumulated += event.scrollingDeltaY
            guard abs(accumulated) >= (event.hasPreciseScrollingDeltas ? 12 : 1) else { return }
            handler?(accumulated > 0 ? 1 : -1)
            accumulated = 0
        }
    }
}
