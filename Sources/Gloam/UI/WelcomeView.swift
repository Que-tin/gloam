// First launch only. A menu-bar app is otherwise invisible until someone finds its icon. It
// asks nothing that most people need to answer: sunset comes from the time zone (shown, and
// changeable here, because "how does it know where I am?" is the first question people ask),
// and the evening is timed from a fixed 23:00 bedtime that fits most people; anyone it
// doesn't suit sets limits in Settings.
// Nothing tints until Start, or the window is closed.

import GloamCore
import SwiftUI

struct WelcomeView: View {
    @Bindable var model: AppModel
    let close: () -> Void
    @State private var openAtLogin = true
    @State private var previewing = false
    @State private var changingCity = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
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
                        Text("\(model.place.name) · sunset today at \(Format.time(model.evening.sunset))")
                            .foregroundStyle(Lamp.ink)
                        Text(model.customPlace == nil
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
                    CitySearch { place in
                        model.customPlace = place
                        changingCity = false
                    }
                    .padding(.top, 8)
                }
            }

            section("Tonight", top: 20) {
                Text(plan)
                    .foregroundStyle(Lamp.ink.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    LampPill(title: previewing ? "Previewing…" : "Preview tonight", symbol: "eye", action: previewNight)
                        .fixedSize()
                        .disabled(previewing)
                    Text("Too dark or too warm? Settings has limits.")
                        .font(.system(size: 11))
                        .foregroundStyle(Lamp.ink.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 8)
            }

            HStack {
                Text("Open Gloam at login").foregroundStyle(Lamp.ink.opacity(0.85))
                Spacer()
                Toggle("Open Gloam at login", isOn: $openAtLogin)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    // Applied immediately, so closing the window keeps the choice too.
                    .onChange(of: openAtLogin) { _, on in model.setLaunchAtLogin(on) }
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
        .onAppear { if !model.hasOnboarded { model.setLaunchAtLogin(openAtLogin) } }
        .onDisappear { model.preview = nil }
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
        model.hasOnboarded = true
        close()
    }

    /// Shows the night stage on the real screen for a few seconds, then eases back.
    private func previewNight() {
        previewing = true
        model.preview = model.schedule.limited(model.schedule.night.tint)
        Task {
            try? await Task.sleep(for: .seconds(3))
            model.preview = nil
            previewing = false
        }
    }

    /// Tonight's steps in the order they happen.
    private var plan: String {
        let e = model.evening
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
