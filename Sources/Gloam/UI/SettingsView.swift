// Settings: one page of things you set once. Everyday, for-tonight controls live in the popover.
// The lamp's dark surface runs under the transparent title bar; the forms stay native
// (precise, familiar, accessible). No explanatory footers: labels carry the meaning.

import GloamCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            general
            evening
            location
            displays
            apps
            about
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(width: 500, height: 740)  // fits every section without scrolling
        .background(LampSurface(glow: Tint(kelvin: 2700, brightness: 0.6), lit: 0.6).ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .tint(Color.kelvin(2700))
    }

    private var general: some View {
        Section("General") {
            Toggle("Open at login", isOn: Binding(get: { model.launchesAtLogin }, set: model.setLaunchAtLogin))
        }
    }

    /// Caps rather than numbers per stage: automatic runs as designed until it would cross one.
    /// Warmth's right end ("Full") and Night brightness's left end are the defaults.
    private var evening: some View {
        Section {
            LabeledContent("Warmth") {
                HStack {
                    Slider(value: $model.schedule.warmthAllowance, in: 0...1, onEditingChanged: previewNight).frame(width: 150)
                    allowanceLabel(model.schedule.warmthAllowance) { Format.kelvin((model.schedule.warmest / 100).rounded() * 100) }
                }
            }
            // Brightness rather than "dimming": right is brighter, like every brightness control.
            LabeledContent("Night brightness") {
                HStack {
                    Slider(value: $model.schedule.darkest, in: Schedule.darkestRange, step: 0.05,
                           onEditingChanged: previewNight).frame(width: 150)
                    Text(Format.percent(model.schedule.darkest))
                        .monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
                }
            }
            if model.roomLight.isAvailable || model.display.displays.contains(where: \.isBuiltin) {
                Toggle("Auto dimming", isOn: $model.autoDimming)
            }
        } header: {
            Text("Evening")
        }
        .onChange(of: model.schedule) { if model.preview != nil { previewNight(true) } }
    }

    private func allowanceLabel(_ a: Double, _ value: () -> String) -> some View {
        Text(a >= 0.999 ? "Full" : a <= 0.001 ? "None" : value())
            .monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
    }

    /// While a limit is dragged the screen shows the night it allows, so it's never set blind
    /// (by day, or while a hand setting is on).
    private func previewNight(_ editing: Bool) {
        model.preview = editing && model.enabled ? model.schedule.limited(model.schedule.night.tint) : nil
    }


    private var location: some View {
        Section {
            Picker("Location", selection: Binding(
                get: { model.customPlace == nil },
                set: { model.customPlace = $0 ? nil : model.place })
            ) {
                Text("Automatic").tag(true)
                Text("Choose a city").tag(false)
            }
            LabeledContent("Place", value: "\(model.place.name) · \(Geo.describe(model.place.coordinate))")
            if model.customPlace != nil {
                CitySearch { model.customPlace = $0 }
            }
        } header: {
            Text("Sunset")
        }
    }

    private var displays: some View {
        Section {
            // With one screen, a per-screen switch would just be a second Gloam switch.
            ForEach(model.display.displays.count > 1 ? model.display.displays : []) { display in
                // On/off rather than a strength: the one real need is leaving a colour-
                // calibrated monitor untouched, and a 0–100% scale read as brightness.
                Toggle(display.name, isOn: Binding(get: { model.strength(for: display) > 0 },
                                                   set: { model.displayStrength[display.uuid] = $0 ? nil : 0 }))
                if display.hdrActive && model.display.resolvedEngine == .gamma {
                    Text("HDR is on for \(display.name): tints can look washed out. Turn HDR off in the evening, or use Overlay.")
                        .font(.callout).foregroundStyle(.orange)
                }
            }
            Picker(selection: $model.engine) {
                Text("Automatic").tag(Engine.auto)
                Text("Gamma (true colour)").tag(Engine.gamma)
                Text("Overlay (compatible)").tag(Engine.overlay)
            } label: {
                Text("Method")
            }
        } header: {
            Text("Displays")
        }
    }

    private var apps: some View {
        Section {
            ForEach(model.excludedApps) { app in
                LabeledContent {
                    Button("Remove", systemImage: "minus.circle.fill") { model.excludedApps.removeAll { $0 == app } }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Remove \(app.name)")
                } label: {
                    Label { Text(app.name) } icon: { Image(nsImage: icon(app)).resizable().frame(width: 18, height: 18) }
                }
            }
            LabeledContent {
                Button("Add App…", action: addApp)
            } label: {
                if model.excludedApps.isEmpty { Text("No apps yet").foregroundStyle(.secondary) }
            }
        } header: {
            Text("Apps in true colour")
        }
    }

    private var about: some View {
        Section("About") {
            LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
            LabeledContent("Source and help") {
                Link("github.com/Que-tin/gloam", destination: URL(string: "https://github.com/Que-tin/gloam")!)
            }
        }
    }

    // MARK: Helpers



    private func icon(_ app: ExcludedApp) -> NSImage {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(filePath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(model.exclude(appAt:))
    }
}
