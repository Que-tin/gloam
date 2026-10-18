// First launch only. A menu-bar app is otherwise invisible until someone finds its icon. It
// asks nothing that most people need to answer: sunset comes from the time zone (shown, and
// changeable here, because "how does it know where I am?" is the first question people ask),
// and the evening is timed from a fixed 23:00 bedtime that fits most people; anyone it
// doesn't suit turns Warmth or Dimming down in the preview, or later in Settings.
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

            section(String(localized: "Where you are"), top: 26) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "location").foregroundStyle(Color.kelvin(2700)).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(evening.sunset.map { String(localized: "\(shownPlace.name) · sunset today at \(Format.time($0))") }
                             ?? String(localized: "\(shownPlace.name) · no sunset today"))
                            .foregroundStyle(Lamp.ink)
                        Text(place == nil
                             ? String(localized: "Estimated from your Mac's time zone, and worked out on this Mac. No location access needed.")
                             : String(localized: "Worked out on this Mac from the city you chose."))
                            .font(.system(size: 11))
                            .foregroundStyle(Lamp.ink.opacity(0.6))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    LampPill(title: changingCity ? String(localized: "Cancel") : String(localized: "Change")) { changingCity.toggle() }
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

            section(String(localized: "Tonight"), top: 20) {
                Text(evening.plan)
                    .foregroundStyle(Lamp.ink.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                LampPill(title: previewing ? String(localized: "Done") : String(localized: "Preview tonight"),
                         symbol: previewing ? "checkmark" : "eye", action: togglePreview)
                    .fixedSize()
                    .padding(.top, 10)
                // Seeing tonight is the moment to say "a bit less": the same two sliders as
                // Settings, live on the real screen while the preview is on.
                if previewing {
                    VStack(spacing: 8) {
                        slider(String(localized: "Warmth"), $schedule.warmthAllowance, in: 0...1, step: nil)
                        slider(String(localized: "Dimming"), $schedule.dimmingAllowance, in: 0...1, step: nil)
                    }
                    .padding(.top, 12)
                }
            }

            HStack {
                Text("Open Gloam at login").foregroundStyle(Lamp.ink.opacity(0.85))
                Spacer()
                PowerSwitch(on: $openAtLogin, kelvin: 2700, help: String(localized: "Open Gloam at login"))
                    .accessibilityLabel("Open Gloam at login")
            }
            .padding(.top, 22)

            LampButton(title: String(localized: "Start"), action: start)
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
            // Named for VoiceOver; the visible Text beside it is the label people see.
            Group {
                if let step { Slider(value: value, in: range, step: step) { Text(title) } }
                else { Slider(value: value, in: range) { Text(title) } }
            }
            .labelsHidden()
            .accessibilityValue(value.wrappedValue >= 0.999 ? String(localized: "Full")
                : value.wrappedValue <= 0.001 ? String(localized: "None") : Format.percent(value.wrappedValue))
        }
    }
}
