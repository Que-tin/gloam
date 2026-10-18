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
        // Fits every section with one display and no app exceptions; on a short screen (older
        // 13" Macs) the window stops at the screen and the form scrolls.
        .frame(width: 500, height: min(1000, (NSScreen.main?.visibleFrame.height ?? 900) - 60))
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
    /// Set in the graph, named in the legend as the warmest and dimmest the evening may get (by
    /// default the night stage itself), in the units of the popover's dial and ladder.
    private var evening: some View {
        Section {
            // Tonight as a graph, which is also where the limits and the clock times are set
            // (`EveningGraph`); the line below names the limits and shows the night on the real
            // screen, by day too.
            EveningGraph(schedule: $model.schedule, place: model.place.coordinate, now: model.now,
                         onEditing: previewNight)
            HStack(spacing: 14) {
                // In the graph's own units: warmth by name (its left axis), dimming in percent
                // as the popover's ladder counts it (its right axis).
                LegendKey(title: String(localized: "Warmest"), value: Light.name(model.schedule.warmest),
                          spoken: Format.percent(model.schedule.warmthAllowance),
                          color: Color.kelvin(2400), allowance: $model.schedule.warmthAllowance)
                LegendKey(title: String(localized: "Dimmest"), value: Format.percent(Light.dimming(model.schedule.darkest)),
                          spoken: Format.percent(Light.dimming(model.schedule.darkest)),
                          color: Color(white: 0.82), allowance: $model.schedule.dimmingAllowance)
                Spacer()
                Button(previewing ? String(localized: "Done") : String(localized: "Preview Tonight")) {
                    previewing.toggle()
                    previewNight(false)
                }
            }
            // Wind-down starts 3 h and night 1 h before bedtime; daylight is back by wake. Also
            // draggable in the graph; the pickers stay for exact times and VoiceOver.
            Picker("Bedtime", selection: $model.schedule.bedtime) {
                ForEach(ClockTime.all(in: Schedule.bedtimes), id: \.self) { Text(Format.time($0)).tag($0) }
            }
            Picker("Wake up", selection: $model.schedule.wake) {
                ForEach(ClockTime.all(in: Schedule.wakes), id: \.self) { Text(Format.time($0)).tag($0) }
            }
            if model.roomLight.isAvailable {
                Toggle("Adapt to room light", isOn: $model.autoDimming)  // "Auto dimming" read as all of it
            }
        } header: {
            Text("Evening")
        }
        .onChange(of: model.schedule) { if model.preview != nil { model.preview = night } }
        .onDisappear { model.preview = nil }  // whatever started it, a preview ends with Settings
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
                Text("From time zone").tag(true)
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
                Text("Gamma (best quality)").tag(Engine.gamma)  // "true colour" means an app exception elsewhere
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

/// A graph curve's key and its limit. The lines are set by dragging; this is the same setting
/// for the keyboard (focus it, then the arrow keys) and VoiceOver (swipe up or down).
private struct LegendKey: View {
    let title: String
    let value: String
    /// What VoiceOver adds to the name, so a step that keeps the same name still sounds like one.
    let spoken: String
    let color: Color
    @Binding var allowance: Double
    @FocusState private var focused: Bool
    @State private var ring = false  // keyboard focus only: it also takes focus as Settings opens

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title)
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(color.opacity(ring ? 0.8 : 0)))
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onChange(of: focused) { _, now in ring = now && Lamp.focusFromKeyboard }
        .onMoveCommand { direction in
            ring = true
            switch direction {
            case .right, .up: allowance += 0.05
            case .left, .down: allowance -= 0.05
            @unknown default: break
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value == spoken ? value : "\(value), \(spoken)")
        .accessibilityAdjustableAction { direction in allowance += direction == .increment ? 0.05 : -0.05 }
        .help("Drag its dashed line in the graph, or focus here and use the arrow keys")
    }
}
