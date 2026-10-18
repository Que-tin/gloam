// First launch only. A menu-bar app is otherwise invisible until someone finds its icon. It
// asks nothing that most people need to answer: sunset comes from the time zone (shown, and
// changeable here, because "how does it know where I am?" is the first question people ask),
// and the evening is timed from a 23:00 bedtime that fits most people (moved in Settings, never
// asked here); anyone it doesn't suit turns Warmest or Dimmest down in the preview.
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
    private var evening: Schedule.Evening { schedule.evening(around: model.eveningWake.addingTimeInterval(-3600), shownPlace.coordinate) }

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
                Text("Gloam warms your screen as the sun goes down and dims it later in the evening, so it gives off less of the light that keeps you alert.")
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
                             ? String(localized: "Estimated from your Mac's time zone and worked out on this Mac; no location access needed.")
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
                // Where "deepest around 22:00" comes from, and that it can move.
                Text("Timed for a \(Format.time(schedule.bedtime)) bedtime, which you can change in Settings.")
                    .font(.system(size: 11))
                    .foregroundStyle(Lamp.ink.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                LampPill(title: previewing ? String(localized: "Done") : String(localized: "Preview tonight"),
                         symbol: previewing ? "checkmark" : "eye", action: togglePreview)
                    .fixedSize()
                    .padding(.top, 10)
                // Seeing tonight is the moment to say "a bit less": the same two sliders as
                // Settings, live on the real screen while the preview is on.
                if previewing {
                    VStack(spacing: 8) {
                        // Values named as in Settings (without its Kelvin), so the two places speak alike.
                        slider(String(localized: "Warmest"), Light.name(schedule.warmest), $schedule.warmthAllowance, max: Schedule().warmthAllowance)
                        slider(String(localized: "Dimmest"), Format.percent(Light.dimming(schedule.darkest)), $schedule.dimmingAllowance, max: Schedule().dimmingAllowance)
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

            Text("Gloam lives in the menu bar. Click its icon any time; right-click for more.")
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
        model.preview = previewing ? schedule.limitedNight : nil
    }

    private func slider(_ title: String, _ shown: String, _ value: Binding<Double>, max: Double) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 12)).foregroundStyle(Lamp.ink.opacity(0.75)).frame(width: 72, alignment: .leading)
            // Named for VoiceOver; the visible Text beside it is the label people see.
            // Up to the recommended night only: deeper is a Settings choice, beside its warning.
            Slider(value: value, in: 0...max) { Text(title) }
                .labelsHidden()
                .accessibilityValue(shown)
            Text(shown).font(.system(size: 12)).monospacedDigit().foregroundStyle(Lamp.ink.opacity(0.6))
                .frame(width: 84, alignment: .trailing)
        }
    }
}
