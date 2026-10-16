// "Light as material": the popover is a lamp in a dark room. Its controls are made of the
// light they set: the orb glows in the screen's current colour and brightness, the dial's
// ticks are painted in the temperature each stands for, and the brightness ladder dims its
// own light. Dark by design: Gloam lives at night, and a light variant would fight the glow.
// By day the lamp is unlit and says when it starts; the evening is the event.

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

/// Mono caption in the lamp's label style.
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let c = Color.kelvin(kelvin)
        Button { withAnimation(reduceMotion ? nil : .snappy) { on.toggle() } } label: {
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
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(on ? "Turn Gloam off" : "Turn Gloam on")
        .accessibilityLabel("Gloam")
        .accessibilityValue(on ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
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
    /// 0 = the lamp is unlit (off, stepping aside, or daytime), 1 = lit. Animated by `PopoverView.warm`.
    let core: Double
    let bloom: Double
    let orbTitle: String
    let orbCaption: String
    /// When set, the orb is a quiet power button (Gloam is off) instead of a readout.
    var onPower: (() -> Void)?
    /// Spoken by VoiceOver: "Warmth for Wind-down".
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
                    LampLabel(text: "cool", opacity: 0.45).position(x: center.x - 78, y: center.y + 86)
                    LampLabel(text: "warm", opacity: 0.45).position(x: center.x + 78, y: center.y + 86)
                }
                .contentShape(Rectangle())
                .gesture(drag(center: center))
                .onContinuousHover { phase in
                    if case .active(let p) = phase {
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
                .accessibilityLabel("Warmth for \(stageName)")
                .accessibilityValue("\(Light.name(kelvin).lowercased()), \(Format.kelvin(kelvin))")
                .accessibilityHint("Swipe up for warmer, down for cooler")
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
        let new = min(1, max(0, fraction + delta))
        if new != fraction { fraction = new }
    }

    private func drag(center: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($dragging) { g, state, _ in
                // A press that starts off the ring (on the orb, in a corner) isn't a dial drag.
                if Self.band.contains(hypot(g.startLocation.x - center.x, g.startLocation.y - center.y)) {
                    state = true
                }
            }
            .onChanged { g in
                guard Self.band.contains(hypot(g.startLocation.x - center.x, g.startLocation.y - center.y)) else { return }
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
        .help("\(Format.kelvin((kelvin / 100).rounded() * 100)). Changing it holds until the next stage.")
    }

    private func ticks(center: CGPoint, f: Double) -> some View {
        ForEach(0..<Self.ticks, id: \.self) { i in
            let t = Double(i) / Double(Self.ticks - 1)
            let major = i % 9 == 0
            let isLit = t <= f + 0.001
            Capsule()
                .fill(Color.kelvin(kelvinAt(t)).opacity(isLit ? 0.5 + 0.35 * core : 0.22))
                .frame(width: major ? 1.6 : 1.1, height: major ? 9 : 5)
                .offset(y: -(Self.ringRadius + (major ? 10 : 8)))
                .rotationEffect(.degrees(Self.arcStart + 90 + t * Self.arcSweep))
                .position(center)
        }
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

    /// "−85%" or a time, large; a word ("aside", "off"), smaller.
    private var orbHeadline: Text {
        let size: CGFloat = orbTitle.first?.isLetter == true ? 19 : 28
        return Text(orbTitle).font(.system(size: size, weight: .medium, design: .rounded).monospacedDigit())
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
            if onPower != nil {
                Image(systemName: "power")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(Lamp.ink.opacity(0.4))
            } else {
                readoutText(r: r, ink: ink, etched: etched)
            }
        }
        .compositingGroup()
        .shadow(color: glow.opacity(0.8 * b), radius: 14)
        .shadow(color: glow.opacity(0.5 * b * bloom), radius: 40)

        return Group {
            if let onPower {
                Button(action: onPower) { face.contentShape(Circle()) }
                    .buttonStyle(.plain)
                    .help("Turn Gloam on")
                    .accessibilityLabel("Turn Gloam on")
            } else {
                face
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(orbTitle) \(orbCaption)")
                    .help("Less of the blue-rich light that keeps you alert in the evening (melanopic light), "
                        + "estimated against the same screen untinted at full brightness.")
            }
        }
    }

    private func readoutText(r: CGFloat, ink: Color, etched: Bool) -> some View {
            VStack(spacing: 2) {
                orbHeadline
                    .tracking(-1)
                    .lineLimit(1)
                    // 28 pt keeps "−100%" (~89 pt) inside this padded frame, so percentages
                    // never shrink or jump; only a 12-hour time ("10:09 PM") scales down.
                    .minimumScaleFactor(0.5)
                    .frame(maxWidth: r * 1.7)
                    .contentTransition(.numericText())
                if !orbCaption.isEmpty {
                    Text(orbCaption)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .opacity(0.85)
                        .frame(width: r * 1.8)
                }
            }
            .foregroundStyle(ink.opacity(core > 0.5 ? 0.92 : 0.75))
            .blendMode(etched ? .multiply : .normal)
            .offset(y: 2)
    }
}

// MARK: - Brightness ladder

/// Cells rising like a volume wedge; lit cells glow as bright as the level they stand for, so
/// the control dims its own light. Each cell is 5% of full brightness, so the lit cells always
/// match the number; cells below `floor` stay lit and can't be dragged away.
struct BrightnessLadder: View {
    @Binding var brightness: Double
    let floor: Double
    let title: String
    let kelvin: Double
    let core: Double
    @GestureState private var dragging = false
    @FocusState private var focused: Bool
    @State private var ring = false  // keyboard focus only
    static let cells = 20
    private var floorCells: Int { Int((floor * Double(Self.cells) - 1e-6).rounded(.up)) }

    private var litCells: Int { Int((brightness * Double(Self.cells)).rounded()) }

    var body: some View {
        let c = Color.kelvin(kelvin)
        VStack(spacing: 7) {
            HStack {
                LampLabel(text: title)
                Spacer()
                Text(Format.percent(brightness))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Lamp.ink.opacity(0.9))
                    .contentTransition(.numericText())
            }
            GeometryReader { geo in
                HStack(spacing: 3) {
                    ForEach(0..<Self.cells, id: \.self) { i in
                        let on = i < litCells
                        let level = 0.35 + 0.65 * Double(i + 1) / Double(Self.cells)
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(on ? c.opacity(level * (0.5 + 0.5 * core)) : .white.opacity(0.07))
                            .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .strokeBorder(.white.opacity(on ? 0.25 : 0.05), lineWidth: 0.5))
                            .shadow(color: on ? c.opacity(0.75 * level * core) : .clear, radius: 4)
                            .frame(height: 7 + 13 * Double(i + 1) / Double(Self.cells))
                    }
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .updating($dragging) { _, state, _ in state = true }
                    .onChanged { g in
                        set(cells: Int((g.location.x / geo.size.width * Double(Self.cells) + 0.5).rounded(.down)))
                    })
                .onHover { inside in (inside ? NSCursor.pointingHand : NSCursor.arrow).set() }
            }
            .frame(height: 20)
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Lamp.well.opacity(0.8)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(ring ? Color.kelvin(kelvin).opacity(0.8)
                                   : Color.white.opacity(0.08), lineWidth: ring ? 1.2 : 0.8))
        }
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
        .help("Drag, click or scroll to set brightness")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(Format.percent(brightness))
        .accessibilityAdjustableAction { direction in set(cells: litCells + (direction == .increment ? 1 : -1)) }
    }

    private func set(cells: Int) {
        let n = min(Self.cells, max(floorCells, cells))
        guard n != litCells else { return }
        Lamp.detent()
        brightness = Double(n) / Double(Self.cells)
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
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 8, weight: .bold)) }
                Text(title).font(Lamp.label).tracking(0.9).textCase(.uppercase)
            }
            .foregroundStyle(Lamp.ink.opacity(hovering ? 0.95 : 0.75))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(.white.opacity(hovering ? 0.08 : 0.045)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.1)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
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
                Button(action: perform) {
                    Text(title).font(Lamp.label).tracking(1).textCase(.uppercase)
                        .foregroundStyle(Color(rgb: 0xFFB070))
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(Capsule().fill(Lamp.amber.opacity(0.16)))
                        .fixedSize()
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .accessibilityElement(children: .combine)
    }
}

extension View {
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
