// Settings: one page of things you set once. Everyday, for-tonight controls live in the popover.
// The lamp's dark surface runs under the transparent title bar; the forms stay native
// (precise, familiar, accessible). No explanatory footers: labels carry the meaning.

import GloamCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable var model: AppModel
    /// "Preview tonight" is on: the screen shows the night the limits allow until "Done".
    @State private var previewing = false

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
        .frame(width: 500, height: 790)  // fits every section with one display and no app exceptions
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
    /// Both read the same way, None … Full, and Full (the right end) is the default. Dimming
    /// rather than "Night brightness": the cap limits how far Gloam goes, the word the popover's
    /// ladder uses too.
    private var evening: some View {
        Section {
            // Like Welcome's "Tonight": what the evening will do, and a way to see it on the
            // real screen while setting the limits, by day too.
            HStack(alignment: .firstTextBaseline) {
                Text(model.schedule.evening(around: model.now, model.place.coordinate).plan)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(previewing ? String(localized: "Done") : String(localized: "Preview Tonight")) {
                    previewing.toggle()
                    previewNight(false)
                }
            }
            LabeledContent("Warmth") {
                HStack {
                    Slider(value: $model.schedule.warmthAllowance, in: 0...1, onEditingChanged: previewNight).frame(width: 150)
                        .accessibilityLabel("Warmth").accessibilityValue(warmthText)
                    allowanceLabel(warmthText)
                }
            }
            LabeledContent("Dimming") {
                HStack {
                    Slider(value: $model.schedule.dimmingAllowance, in: 0...1, onEditingChanged: previewNight).frame(width: 150)
                        .accessibilityLabel("Dimming").accessibilityValue(dimmingText)
                    allowanceLabel(dimmingText)
                }
            }
            if model.roomLight.isAvailable {
                Toggle("Auto dimming", isOn: $model.autoDimming)
            }
        } header: {
            Text("Evening")
        }
        .onChange(of: model.schedule) { if model.preview != nil { model.preview = night } }
        .onDisappear { if previewing { model.preview = nil } }
    }

    private var warmthText: String {
        allowance(model.schedule.warmthAllowance) { Light.name(model.schedule.warmest) }  // names, like the dial
    }
    private var dimmingText: String {
        allowance(model.schedule.dimmingAllowance) { Format.percent(model.schedule.dimmingAllowance) }
    }

    private func allowance(_ a: Double, _ value: () -> String) -> String {
        a >= 0.999 ? String(localized: "Full") : a <= 0.001 ? String(localized: "None") : value()
    }

    private func allowanceLabel(_ text: String) -> some View {
        Text(text)
            .monospacedDigit().foregroundStyle(.secondary).frame(width: 84, alignment: .trailing)
    }

    /// While a limit is dragged, or while "Preview Tonight" is on, the screen shows the night it
    /// allows, so it's never set blind (by day, or while a hand setting is on). A drag alone
    /// leaves the screen alone while Gloam is off; asking for the preview shows it anyway.
    private func previewNight(_ editing: Bool) {
        model.preview = previewing || (editing && model.enabled) ? night : nil
    }

    private var night: Tint { model.schedule.limited(model.schedule.night.tint) }

    private var location: some View {
        Section {
            Picker("Location", selection: Binding(
                get: { model.customPlace == nil },
                set: { model.customPlace = $0 ? nil : model.place })
            ) {
                Text("Automatic").tag(true)
                Text("Choose a city").tag(false)
            }
            LabeledContent("Place", value: String(localized: "\(model.place.name) · \(Geo.describe(model.place.coordinate))"))
            if model.customPlace != nil {
                CitySearch { model.customPlace = $0 }
            }
        } header: {
            Text("Sunset")
        }
    }

    private var displays: some View {
        Section {
            let several = model.display.displays.count > 1
            ForEach(model.display.displays) { display in
                // On/off rather than a strength: the one real need is leaving a colour-
                // calibrated monitor untouched, and a 0–100% scale read as brightness. With one
                // screen, a per-screen switch would just be a second Gloam switch.
                if several {
                    Toggle(display.name, isOn: Binding(get: { model.strength(for: display) > 0 },
                                                       set: { model.displayStrength[display.uuid] = $0 ? nil : 0 }))
                }
                // Built-in panels are always held to the smear floor; a monitor only on request,
                // since nothing macOS reports says whether its panel smears (see `Smear`).
                if !display.isBuiltin, model.strength(for: display) > 0 {
                    Toggle(several ? String(localized: "Avoid smearing on \(display.name)") : String(localized: "Avoid smearing"),
                           isOn: Binding(get: { model.smearGuarded.contains(display.uuid) },
                                         set: { on in if on { model.smearGuarded.insert(display.uuid) } else { model.smearGuarded.remove(display.uuid) } }))
                        .help("When light text on a dark background leaves trails on this display in the evening: the tint stops short of the range that causes them (less dimming; at full brightness, less warmth).")
                }
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
            LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? String(localized: "dev"))
            LabeledContent("Source and help") {
                Link("github.com/Que-tin/gloam", destination: URL(string: "https://github.com/Que-tin/gloam")!)
            }
        }
    }

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
