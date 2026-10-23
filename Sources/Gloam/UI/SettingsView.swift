// Settings: one page of things you set once. Everyday, for-tonight controls live in the popover.
// The lamp's dark surface runs under the transparent title bar; the forms stay native
// (precise, familiar, accessible). No explanatory footers: labels carry the meaning.

import GloamCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable var model: AppModel
    private static let titleBarHeight: CGFloat = 28
    /// The form has scrolled under the title bar (`ScrollWatcher`).
    @State private var scrolled = false
    /// "Choose a city…" picked, no city found yet.
    @State private var choosingCity = false
    /// Sparkle keeps the setting; this mirrors it for the switch.
    @State private var checksForUpdates = Updates.checksAutomatically

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
        // Shorter than everything, by choice: the form scrolls rather than the window filling a
        // laptop screen; on a short screen (older 13" Macs) it stops at the screen.
        .frame(width: 500, height: min(620, (NSScreen.main?.visibleFrame.height ?? 900) - 60))
        .background(LampSurface(glow: Tint(kelvin: 2700, brightness: 0.6), lit: 0.6).ignoresSafeArea())
        // The title bar is see-through until the form scrolls under the window buttons; then a
        // strip of the surface's colour comes in behind them (a permanent strip looked heavy).
        .background(ScrollWatcher { now in if now != scrolled { scrolled = now } })
        .overlay(alignment: .top) {
            // The form's frame starts below the title bar while its content scrolls up under it,
            // so the strip is lifted above the form's top. Frosted and tinted with the surface,
            // fading out below the buttons rather than ending in a hard edge.
            Rectangle().fill(.ultraThinMaterial)
                .overlay(Lamp.surface.opacity(0.55))
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.6),
                                             .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                .frame(height: Self.titleBarHeight + 18)
                .offset(y: -Self.titleBarHeight)
                .opacity(scrolled ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: scrolled)
                .allowsHitTesting(false)
        }
        .environment(\.colorScheme, .dark)
        .tint(Color.kelvin(2700))
    }

    private var general: some View {
        Section("General") {
            Toggle("Open at login", isOn: Binding(get: { model.launchesAtLogin }, set: model.setLaunchAtLogin))
            if Updates.updater != nil {
                Toggle("Check for updates automatically", isOn: $checksForUpdates)
                    .onChange(of: checksForUpdates) { _, on in Updates.checksAutomatically = on }
            }
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
            EveningGraph(schedule: $model.schedule, place: model.place.coordinate, wake: model.eveningWake)
            HStack(spacing: 14) {
                // In the graph's own units: warmth by name and Kelvin (its left axis), dimming in
                // percent of the schedule's fixed scale (its right axis, the popover ladder's too).
                LegendKey(title: String(localized: "Warmest"), value: "\(Light.name(model.schedule.warmest)) · \(Format.kelvin(model.schedule.warmest))",
                          spoken: Format.percent(model.schedule.warmthAllowance),
                          color: EveningGraph.warm, allowance: $model.schedule.warmthAllowance,
                          recommended: Schedule().warmthAllowance)
                LegendKey(title: String(localized: "Dimmest"), value: Format.percent(Light.dimming(model.schedule.darkest)),
                          color: EveningGraph.dim, allowance: $model.schedule.dimmingAllowance,
                          recommended: Schedule().dimmingAllowance)
                Spacer(minLength: 0)
            }
            // Past the recommended night, a word on what it costs; nothing before.
            if let note = deeperNote {
                Label(note, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Bedtime and wake are set in the graph only: its markers, by drag, keyboard or VoiceOver.
            if RoomLight.isAvailable {
                Toggle("Adapt to room light", isOn: $model.autoDimming)  // "Auto dimming" read as all of it
            }
        } header: {
            // The lamp's pill, as in Welcome: a system button looked foreign beside the graph,
            // and up here it leaves the legend its width.
            HStack {
                Text("Evening")
                Spacer()
                // While on, the screen shows the night the limits allow, so they're never set blind
                // (by day, with a shift, even with Gloam off). Only this starts it: a preview
                // that also jumped in mid-drag of a limit was confusing.
                LampPill(title: model.preview != nil ? String(localized: "Done") : String(localized: "Preview tonight"),
                         symbol: model.preview != nil ? "checkmark" : "eye") {
                    model.preview = model.preview == nil ? night : nil
                }
                .fixedSize()
            }
        } footer: {
            // Everything the graph sets, back to the evidence-based defaults; only offered when
            // something differs. A plain push button at the bottom left, as macOS settings offer
            // it: a pill beside Done (and then by the title) was pressed by mistake, as small grey
            // text it went unseen, and a pill at the bottom read as a second Preview.
            if !isDefault {
                HStack {
                    Button(String(localized: "Restore Defaults")) { model.schedule = Schedule() }
                        .buttonStyle(.bordered)
                        .help(String(localized: "Back to a \(Format.time(Schedule().bedtime)) bedtime, \(Format.time(Schedule().wake)) wake-up and the recommended Warmest and Dimmest"))
                    Spacer()
                }
                .padding(.top, 4)
            }
        }
        .onChange(of: model.schedule) { if model.preview != nil { model.preview = night } }
    }

    /// What going warmer than the recommended night may cost, said once Warmest goes there (the
    /// smear floor eases off with it, `Schedule.pastRecommended`). Dimmer needs no note: a dim
    /// screen is plainly dim.
    private var deeperNote: String? {
        guard Kelvin.mired(model.schedule.warmest) > Kelvin.mired(Schedule.recommendedNight.kelvin) + 1 else { return nil }
        // Tentative on purpose: what happens depends on the screen, which Gloam can't know.
        return String(localized: "Warmer than recommended: colours may begin to fade, and moving text may smear.")
    }

    private var isDefault: Bool {
        let (s, d) = (model.schedule, Schedule())
        // Within a hair: a dragged limit snaps onto it through floating-point arithmetic.
        return abs(Kelvin.mired(s.warmest) - Kelvin.mired(d.warmest)) < 0.5 && abs(s.darkest - d.darkest) < 0.002
            && s.bedtime == d.bedtime && s.wake == d.wake
    }

    private var night: Tint { model.schedule.night.tint }

    private var location: some View {
        Section {
            // One row: where sunset is worked out for, and how. (A separate read-only "Place"
            // row looked like a second setting.)
            // "Choose a city…" opens the search and changes nothing until a city is picked; the
            // pick closes it again. A chosen city carries its coordinates, so two of the same name
            // can be told apart.
            Picker("Location", selection: Binding(
                get: { choosingCity ? LocationChoice.choose : model.customPlace == nil ? .timeZone : .city },
                set: { choice in
                    choosingCity = choice == .choose
                    if choice == .timeZone { model.customPlace = nil }
                })
            ) {
                Text("\(model.timeZonePlace.name) (time zone)").tag(LocationChoice.timeZone)
                if let city = model.customPlace {
                    Text("\(city.name) · \(Geo.describe(city.coordinate))").tag(LocationChoice.city)
                }
                Text(model.customPlace == nil ? String(localized: "Choose a city…") : String(localized: "Choose another city…"))
                    .tag(LocationChoice.choose)
            }
            if let city = model.customPlace, !model.customPlaceInUse, !choosingCity {
                Text("\(city.name) keeps another time than your Mac, so sunset follows \(model.timeZonePlace.name) until the clocks match again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if choosingCity {
                CitySearch { picked in
                    model.customPlace = picked
                    choosingCity = false
                }
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
                    Toggle(display.name, isOn: Binding(get: { model.isTinted(display) },
                                                       set: { _ in model.untintedDisplays.formSymmetricDifference([display.uuid]) }))
                }
                // Built-in panels are always held to the smear floor; a monitor only on request,
                // since nothing macOS reports says whether its panel smears (see `Smear`).
                if !display.isBuiltin, model.isTinted(display) {
                    Toggle(several ? String(localized: "Avoid smearing on \(display.name)") : String(localized: "Avoid smearing"),
                           isOn: Binding(get: { model.smearGuarded.contains(display.uuid) },
                                         set: { on in if on { model.smearGuarded.insert(display.uuid) } else { model.smearGuarded.remove(display.uuid) } }))
                        .help("Turn on if light text on dark backgrounds leaves trails on this display in the evening. Gloam then stops short of the darkest tints: less dimming, and at full brightness less warmth.")
                }
                if display.hdrActive && model.display.resolvedEngine == .gamma {
                    Text("HDR is on for \(display.name), so the tint may look washed out. Turn HDR off in the evening, or use Overlay.")
                        .font(.callout).foregroundStyle(.orange)
                }
            }
            Picker(selection: $model.engine) {
                Text("Automatic").tag(Engine.auto)
                Text("Colour signal (best quality)").tag(Engine.gamma)
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
            Text("Apps that pause Gloam")
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
    var spoken: String? = nil
    let color: Color
    @Binding var allowance: Double
    /// The recommended night on this scale: a step landing within half a step of it lands on it
    /// (the 5 % grid misses it, and the way back must not need Reset).
    let recommended: Double
    // Keyboard focus only: it also takes focus as Settings opens, unseen, so an arrow pressed
    // then (to scroll) first shows the ring rather than changing the setting.
    @State private var ring = false

    private func nudge(_ step: Double) {
        let next = allowance + step
        allowance = abs(next - recommended) < 0.025 ? recommended : next
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title)
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(color.opacity(ring ? 0.8 : 0)))
        .keyboardRing($ring)
        .onMoveCommand { direction in
            guard ring else { ring = true; return }
            switch direction {
            case .right, .up: nudge(0.05)
            case .left, .down: nudge(-0.05)
            @unknown default: break
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(spoken.map { "\(value), \($0)" } ?? value)
        .accessibilityAdjustableAction { direction in nudge(direction == .increment ? 0.05 : -0.05) }
        .help("Drag the dashed line in the graph, or select this and use the arrow keys.")
    }
}

private enum LocationChoice { case timeZone, city, choose }

/// Reports whether the window's form has scrolled from the top. SwiftUI on macOS 14 has no
/// scroll-offset callback, so it watches the form's NSScrollView, found from the window: a
/// watcher placed inside a form row made the form open scrolled. It also keeps that scroll view on
/// thin overlay scrollers (a narrow thumb, no track, shown while scrolling) whatever "Show scroll
/// bars" says: a boxed bar down the edge of a small dark window was all chrome.
private struct ScrollWatcher: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> NSView { Watcher(onChange: onChange) }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Watcher: NSView {
        let onChange: (Bool) -> Void
        nonisolated(unsafe) private var token: NSObjectProtocol?
        nonisolated(unsafe) private var styleToken: NSObjectProtocol?

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }

        deinit { [token, styleToken].compactMap { $0 }.forEach(NotificationCenter.default.removeObserver) }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            [token, styleToken].compactMap { $0 }.forEach(NotificationCenter.default.removeObserver)
            token = nil
            styleToken = nil
            // A beat later: the form's scroll view may not be in the window yet.
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }

        /// Overlay, at the smallest size AppKit draws (a style change can bring a new scroller).
        private static func thin(_ scroll: NSScrollView) {
            scroll.scrollerStyle = .overlay
            scroll.verticalScroller?.controlSize = .mini
        }

        private func attach() {
            guard token == nil, let scroll = window?.contentView?.firstScrollView else { return }
            Self.thin(scroll)
            // AppKit puts the system's style back when that preference changes: overlay again.
            styleToken = NotificationCenter.default.addObserver(forName: NSScroller.preferredScrollerStyleDidChangeNotification,
                                                                object: nil, queue: .main) { [weak scroll] _ in
                // A beat later, after AppKit's own handling of the same notice.
                DispatchQueue.main.async { MainActor.assumeIsolated { scroll.map(Self.thin) } }
            }
            scroll.contentView.postsBoundsChangedNotifications = true
            let report: @MainActor @Sendable () -> Void = { [weak self, weak scroll] in
                guard let self, let scroll else { return }
                self.onChange(scroll.contentView.bounds.origin.y + scroll.contentInsets.top > 2)
            }
            report()
            token = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                                           object: scroll.contentView, queue: .main) { _ in
                MainActor.assumeIsolated(report)
            }
        }
    }
}

extension NSView {
    /// The first scroll view at or below this view, depth first (Settings' form).
    var firstScrollView: NSScrollView? {
        self as? NSScrollView ?? subviews.lazy.compactMap(\.firstScrollView).first
    }
}
