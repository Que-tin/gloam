// First launch only. A menu-bar app is otherwise invisible until someone finds its icon. It
// asks nothing that most people need to answer: sunset comes from the time zone (shown, and
// changeable here, because "how does it know where I am?" is the first question people ask),
// and the evening is timed from a fixed 23:00 bedtime that fits most people; anyone it
// doesn't suit turns Warmth or Night brightness down in the preview, or later in Settings.
// Everything here is a draft until Start: closing the window first quits Gloam without saving
// anything, so the next launch lands here again. Nothing tints until Start (Preview aside).

import GloamCore
import SwiftUI

struct WelcomeView: View {
    @Bindable var model: AppModel
    let close: () -> Void
    @State private var openAtLogin = true
    @State private var previewing = false
    @State private var changingCity = false
    /// Drafts, applied on Start.
    @State private var place: Place?
    @State private var schedule = Schedule()

    private var shownPlace: Place { place ?? model.timeZonePlace }
    private var evening: Schedule.Evening { schedule.evening(around: model.now, shownPlace.coordinate) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 10) {
                Image(nsImage: Self.icon)
                    .resizable()
                    .frame(width: 76, height: 76)
                    .shadow(color: .kelvin(2700).opacity(0.35), radius: 22)
                Text("Evenings, a little softer.")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(Lamp.ink)
                Text("Gloam warms your screen as the sun goes down and dims it later in the evening, so it gives off less of the light that keeps you awake.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Lamp.ink.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)

            section("Where you are", top: 26) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "location").foregroundStyle(Color.kelvin(2700)).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(shownPlace.name) · sunset today at \(Format.time(evening.sunset))")
                            .foregroundStyle(Lamp.ink)
                        Text(place == nil
                             ? "Estimated from your Mac's time zone, and worked out on this Mac. No location access needed."
                             : "Worked out on this Mac from the city you chose.")
                            .font(.system(size: 11))
                            .foregroundStyle(Lamp.ink.opacity(0.6))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    LampPill(title: changingCity ? "Cancel" : "Change") { changingCity.toggle() }
                        .fixedSize()
                }
                if changingCity {
                    CitySearch { picked in
                        place = picked
                        changingCity = false
                    }
                    .padding(.top, 8)
                }
            }

            section("Tonight", top: 20) {
                Text(plan)
                    .foregroundStyle(Lamp.ink.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                LampPill(title: previewing ? "Done" : "Preview tonight",
                         symbol: previewing ? "checkmark" : "eye", action: togglePreview)
                    .fixedSize()
                    .padding(.top, 10)
                // Seeing tonight is the moment to say "a bit less": the same two sliders as
                // Settings, live on the real screen while the preview is on.
                if previewing {
                    VStack(spacing: 8) {
                        slider("Warmth", $schedule.warmthAllowance, in: 0...1, step: nil)
                        slider("Brightness", $schedule.darkest, in: Schedule.darkestRange, step: 0.05)
                    }
                    .padding(.top, 12)
                }
            }

            HStack {
                Text("Open Gloam at login").foregroundStyle(Lamp.ink.opacity(0.85))
                Spacer()
                PowerSwitch(on: $openAtLogin, kelvin: 2700)
                    .accessibilityLabel("Open Gloam at login")
            }
            .padding(.top, 22)

            LampButton(title: "Start", action: start)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 14)

            Text("Gloam lives in the menu bar. Click its icon any time; right-click for Settings.")
                .font(.caption)
                .foregroundStyle(Lamp.ink.opacity(0.6))
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
        }
        .padding(.horizontal, 30)
        .padding(.top, 8)
        .padding(.bottom, 24)
        .frame(width: 440)
        .background(LampSurface(glow: Tint(kelvin: 2700, brightness: 0.8), lit: 1).ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .tint(Color.kelvin(2700))
        .onDisappear { model.preview = nil }
        .onChange(of: schedule) { if previewing { showNight() } }
    }

    private func section(_ title: String, top: CGFloat, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LampLabel(text: title, opacity: 0.7)
            VStack(alignment: .leading, spacing: 0, content: content)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.08)))
        }
        .padding(.top, top)
    }

    private func start() {
        model.preview = nil
        model.customPlace = place
        model.schedule = schedule
        model.setLaunchAtLogin(openAtLogin)
        model.hasOnboarded = true
        close()
    }

    /// The app icon; a source run (no bundle) falls back to the README's copy.
    private static let icon: NSImage = {
        if Bundle.main.bundleIdentifier != nil { return NSApp.applicationIconImage }
        return NSImage(contentsOfFile: "docs/icon.png") ?? NSApp.applicationIconImage
    }()

    /// Shows the night on the real screen until "Done", following the sliders.
    private func togglePreview() {
        previewing.toggle()
        showNight()
    }

    private func showNight() {
        model.preview = previewing ? schedule.limited(schedule.night.tint) : nil
    }

    private func slider(_ title: String, _ value: Binding<Double>, in range: ClosedRange<Double>, step: Double?) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 12)).foregroundStyle(Lamp.ink.opacity(0.75)).frame(width: 72, alignment: .leading)
            if let step { Slider(value: value, in: range, step: step) } else { Slider(value: value, in: range) }
        }
    }

    /// Tonight's steps in the order they happen.
    private var plan: String {
        let e = evening
        let steps: [(Date?, String)] = [
            (e.sunset, "warmer from sunset"),
            (e.windDown, "dimmer from \(Format.time(e.windDown))"),
            (e.night, "deepest around \(Format.time(e.night))"),
        ]
        let sorted = steps.compactMap { date, text in date.map { ($0, text) } }.sorted { $0.0 < $1.0 }.map(\.1)
        return sorted.isEmpty ? "" : sorted.joined(separator: ", ").capitalizedFirst + "."
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
