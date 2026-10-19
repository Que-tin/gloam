// Entry point: a menu-bar item (MenuBarPanel), no Dock icon. Plain AppKit, not SwiftUI's App:
// every window here (popover, Settings, Welcome) is our own AppKit-hosted window, and a SwiftUI
// App must declare a scene. The only one that fits, an empty `Settings` scene, is a real window
// that macOS opens by itself (an empty grey "Settings" window behind the popover). MenuBarExtra
// is out too: it draws chrome we can't style, open from code, or capture.

import AppKit
import GloamCore
import ServiceManagement
import SwiftUI

@main
enum GloamMain {
    private static let delegate = AppDelegate()  // NSApplication holds its delegate weakly

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.mainMenu = mainMenu()
        app.run()
    }

    /// Never visible (no Dock icon), but it is what makes ⌘C/⌘V in text fields and ⌘W/⌘Q work.
    private static func mainMenu() -> NSMenu {
        let menu = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = NSMenu(title: title)
            items.forEach(holder.submenu!.addItem)
            menu.addItem(holder)
        }
        submenu("Gloam", [
            NSMenuItem(title: String(localized: "Settings…"), action: #selector(AppDelegate.showSettings), keyEquivalent: ","),
            .separator(),
            NSMenuItem(title: String(localized: "Quit Gloam"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"),
        ])
        submenu(String(localized: "Edit"), [
            NSMenuItem(title: String(localized: "Undo"), action: Selector(("undo:")), keyEquivalent: "z"),
            NSMenuItem(title: String(localized: "Redo"), action: Selector(("redo:")), keyEquivalent: "Z"),
            .separator(),
            NSMenuItem(title: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"),
            NSMenuItem(title: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
            NSMenuItem(title: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
            NSMenuItem(title: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"),
        ])
        submenu(String(localized: "Window"), [
            NSMenuItem(title: String(localized: "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"),
        ])
        return menu
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @objc func showSettings() { Windows.showSettings() }
    private var signals: [DispatchSourceSignal] = []

    /// Other running copies: the bundled app by its identifier, and any copy by name (a `swift
    /// run` build has no identifier, and the bundled app must not run beside one that tints).
    /// Copies run with a showcase flag never touch the screen and are left out, read from their
    /// arguments: matching by name alone made the bundled app quit for a snapshot run.
    private static func otherCopies() -> [NSRunningApplication] {
        let me = ProcessInfo.processInfo.processIdentifier
        let byID = Bundle.main.bundleIdentifier.map(NSRunningApplication.runningApplications(withBundleIdentifier:)) ?? []
        let byName = Debug.isShowcase ? [] : NSWorkspace.shared.runningApplications.filter {
            $0.executableURL?.lastPathComponent == "Gloam" && !Self.isShowcase($0.processIdentifier)
        }
        return (byID + byName).filter { $0.processIdentifier != me }
            .reduce(into: []) { all, app in if !all.contains(app) { all.append(app) } }
    }

    /// `kill`, `pkill` and Ctrl-C quit like ⌘Q, so the backlight is restored: unlike a gamma
    /// table, a dimmed backlight outlives the process. A main thread too stuck to quit gets five
    /// seconds, then the process exits anyway (the next launch restores what was saved).
    private func quitOnSignals() {
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler {
                DispatchQueue.main.async { NSApp.terminate(nil) }
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) { exit(1) }
            }
            source.resume()
            signals.append(source)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let others = Self.otherCopies()
        // `Gloam --uninstall`: forget everything (login item, settings) for a clean slate.
        if CommandLine.arguments.contains("--uninstall") {
            guard let id = Bundle.main.bundleIdentifier else {
                print("Gloam: --uninstall needs the app bundle: run Gloam.app/Contents/MacOS/Gloam --uninstall")
                exit(1)
            }
            // A running copy would write its settings back as it quits, so wait for it first.
            others.forEach { $0.terminate() }
            let deadline = Date().addingTimeInterval(5)
            while !others.allSatisfy(\.isTerminated) && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
            let login = SMAppService.mainApp.status
            try? SMAppService.mainApp.unregister()
            UserDefaults.standard.removePersistentDomain(forName: id)
            // And every file Gloam leaves in the Library (Sparkle's downloads and web storage, the
            // settings file itself), so nothing of it stays behind.
            let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            for path in ["Caches/\(id)", "HTTPStorages/\(id)", "HTTPStorages/\(id).binarycookies", "Preferences/\(id).plist"] {
                try? FileManager.default.removeItem(at: library.appendingPathComponent(path))
            }
            print("Gloam: \(others.isEmpty ? "" : "running copy quit; ")\(login == .enabled ? "login item removed" : "no login item to remove"); settings and caches cleared.")
            exit(0)
        }
        // One Gloam at a time: two would fight over the screen's colour table. A later launch
        // opens the earlier one's panel and quits. "Earlier" by the process's own start time
        // (`launchDate` is nil for a copy started from a shell, which then ranked itself oldest),
        // then pid, so two copies started together (login item and a click) don't both leave; the
        // URL goes to that copy's own bundle, not whichever one LaunchServices would pick.
        let key = { (pid: pid_t) in (Self.startTime(pid), pid) }
        let me = key(ProcessInfo.processInfo.processIdentifier)
        if let elder = others.filter({ key($0.processIdentifier) < me }).min(by: { key($0.processIdentifier) < key($1.processIdentifier) }) {
            // From here this copy only forwards: a URL arriving now must not build the model and
            // dim the screen in a process about to exit without restoring.
            handingOver = elder.bundleURL.flatMap { $0.pathExtension == "app" ? $0 : nil }.map { .bundle($0) } ?? .launchServices
            forward([URL(string: "gloam://open")!]) { exit(0) }
            return
        }
        // Also covers `swift run`, where there is no Info.plist to say LSUIElement.
        NSApp.setActivationPolicy(.accessory)
        if !Debug.isShowcase { quitOnSignals() }  // showcase runs are killed by their watchdog
        Debug.applyLaunchArguments()
        _ = Updates.updater
        if !Debug.isShowcase {  // showcase runs share the real app's settings; they leave these alone
            ToggleShortcut.shared.register(AppModel.shared.toggleShortcut)
            // A Focus that pauses Gloam may already be on: its filter only runs again when it changes.
            Task { if (try? await GloamFocusFilter.current)?.pause == true { AppModel.shared.pausedByFocus = true } }
        }
        // The menu-bar icon arrives with Start: until then Welcome is the whole app.
        if AppModel.shared.hasOnboarded || Debug.isShowcase { MenuBarPanel.shared.install() } else { Windows.showWelcome() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard handingOver == nil else { return forward(urls) {} }
        for command in urls.compactMap(Command.init(url:)) {
            if command != .open { AppModel.shared.run(command) }
            else if AppModel.shared.hasOnboarded { MenuBarPanel.shared.open() }
            else { Windows.showWelcome() }
        }
    }

    /// Where a copy that is handing over to an earlier one sends its URLs; nil when it isn't.
    private enum HandOver { case bundle(URL), launchServices }
    private var handingOver: HandOver?

    /// This copy only forwards to an earlier one (see above): an intent run here hands its
    /// command over as a URL, as a click would, instead of acting in a process about to exit.
    var isHandingOver: Bool { handingOver != nil }
    func handOver(_ url: URL) { forward([url]) {} }

    private func forward(_ urls: [URL], then done: @escaping @MainActor @Sendable () -> Void) {
        switch handingOver {
        case .bundle(let app)?:
            NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: .init()) { _, _ in
                DispatchQueue.main.async(execute: done)
            }
        default:
            urls.forEach { NSWorkspace.shared.open($0) }
            done()
        }
    }

    /// Whether another process was started with a flag that keeps it off the screen.
    private static func isShowcase(_ pid: pid_t) -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid], size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return false }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return false }
        let args = buffer.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        return args.contains { ["--showcase", "--snapshot", "--capture", "--film"].contains($0) }
    }

    /// When a process started, from the kernel: unlike `launchDate`, set however it was started.
    private static func startTime(_ pid: pid_t) -> Date {
        var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return .distantFuture }
        let t = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_usec) / 1e6)
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.flushSave()
        AppModel.shared.display.restore()
    }
}

/// The Settings and Welcome windows, created on demand and reused.
enum Windows {
    fileprivate static var settings: NSWindow?
    fileprivate static var welcome: NSWindow?

    static func showSettings() {
        AppModel.shared.refreshLoginStatus()
        settings = settings ?? make(SettingsView(model: .shared), title: String(localized: "Gloam Settings"))
        settings!.delegate = settingsCloser
        present(settings!)
    }

    /// Settings is let go on close: kept, its view tree stayed alive and observing the model
    /// all day for a window opened once.
    private static let settingsCloser = SettingsCloser()

    private final class SettingsCloser: NSObject, NSWindowDelegate {
        func windowWillClose(_ notification: Notification) {
            // "Preview tonight" never outlives the window.
            AppModel.shared.preview = nil
            DispatchQueue.main.async { Windows.settings = nil }
        }
    }

    /// Closing the window before Start quits without saving (the next launch shows Welcome
    /// again); Start saves, then shows the menu-bar icon with its popover open beneath it.
    static func showWelcome() {
        welcome = welcome ?? make(WelcomeView(model: .shared) { welcome?.close() }, title: String(localized: "Welcome to Gloam"))
        welcome!.delegate = welcomeCloser
        present(welcome!)
    }

    private static let welcomeCloser = WelcomeCloser()

    private final class WelcomeCloser: NSObject, NSWindowDelegate {
        func windowWillClose(_ notification: Notification) {
            AppModel.shared.preview = nil
            DispatchQueue.main.async {
                Windows.welcome = nil
                guard AppModel.shared.hasOnboarded else { return NSApp.terminate(nil) }
                MenuBarPanel.shared.install()
                MenuBarPanel.shared.open()
            }
        }
    }

    #if DEBUG
    private static var showcaseWindow: NSWindow?
    static func showcase(_ view: some View) {
        showcaseWindow = make(view, title: "Gloam Showcase")
        present(showcaseWindow!)
    }
    #endif

    /// Lamp-styled chrome: the dark surface runs full-bleed under a transparent title bar, so
    /// there's no grey system strip above the panel (Settings adds one only once it scrolls).
    private static func make(_ view: some View, title: String) -> NSWindow {
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = [.preferredContentSize]  // windows follow their content (Welcome's city results)
        let window = TopAnchoredWindow(contentViewController: controller)
        window.title = title
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(Lamp.surface)
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        return window
    }

    /// Grows and shrinks from its top edge, as a sheet of paper would. AppKit keeps the bottom
    /// edge, so Welcome's city results made the title bar jump as you typed.
    private final class TopAnchoredWindow: NSWindow {
        override func setFrame(_ frameRect: NSRect, display flag: Bool) {
            var frame = frameRect
            if isVisible, frame.origin == self.frame.origin { frame.origin.y = self.frame.maxY - frame.height }
            super.setFrame(frame, display: flag)
        }
    }

    /// Any ordinary window up (Settings, Welcome, Sparkle's update alert…), not the popover or the
    /// menu bar's own. Counting only ours hid Sparkle's window when the popover closed.
    static var anyVisible: Bool { NSApp.windows.contains { $0.isVisible && $0.level == .normal } }

    #if DEBUG
    static var all: [NSWindow] { [settings, welcome].compactMap { $0 } }
    #endif

    /// `activate()` is only a request since macOS 14 and is refused for an app launched in
    /// the background (login, Finder while busy), which left Welcome hidden behind other
    /// windows; ordering front regardless keeps the window visible either way.
    private static func present(_ window: NSWindow) {
        // Sized before centring: SwiftUI reports its size late, and a window centred while
        // still tiny grew from that point and opened towards the bottom right.
        if !window.isVisible, let view = window.contentViewController?.view {
            view.layoutSubtreeIfNeeded()
            window.setContentSize(view.fittingSize)
            window.center()
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}

/// Debug-build launch flags for screenshots and UI work; inert in release builds.
///   --capture DIR     photograph the real popover, Welcome and Settings windows, then quit
///   --film DIR        frames of the real popover switching off and on again, then quit
///   --at HH:MM        run the app's clock at that time of day
///   --onboarded, --off   start as if set up / switched off
///   --focus-paused       start as if a Focus filter paused Gloam
///   --showcase [welcome]  show the popover (or the welcome view) in an ordinary window
///   --snapshot PATH   render the showcase to PATH and quit (never touches the screen)
///   --floor F         built-in smear floor as a signal fraction (default 0.8; 0 = none), to
///                     calibrate it: scroll light-on-dark text and move the dial and ladder
///   --exit-after S    quit normally after S seconds (restoring the screen), for scripted checks
enum Debug {
    #if DEBUG
    static let isSnapshot = CommandLine.arguments.contains("--snapshot")
    static let isCapture = CommandLine.arguments.contains("--capture") || CommandLine.arguments.contains("--film")
    /// Showcase and capture runs never tint the real screen.
    static let isShowcase = CommandLine.arguments.contains("--showcase") || isSnapshot || isCapture
    #else
    static let isSnapshot = false
    static let isCapture = false
    static let isShowcase = false
    #endif

    static func applyLaunchArguments() {
        #if DEBUG
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
        if let at = value("--at") {
            let p = at.split(separator: ":").compactMap { Int($0) }
            if p.count == 2, let d = Calendar.current.date(bySettingHour: p[0], minute: p[1], second: 0, of: Date()) {
                AppModel.clockOffset = d.timeIntervalSinceNow
                AppModel.shared.update(fade: 0)
            }
        }
        if args.contains("--onboarded") { AppModel.shared.hasOnboarded = true }
        if args.contains("--off") { AppModel.shared.enabled = false }
        if args.contains("--focus-paused") { AppModel.shared.pausedByFocus = true }  // as a Focus filter would
        if let floor = value("--floor").flatMap(Double.init) {
            DisplayController.smearFloor = pow((0.0...1.0).clamp(floor), Kelvin.displayGamma)
            AppModel.shared.update(fade: 0)
        }
        if let seconds = value("--exit-after").flatMap(Double.init) {
            Task { try? await Task.sleep(for: .seconds(seconds)); NSApp.terminate(nil) }
        }
        if let dir = value("--capture") { capture(into: dir); return }
        if let dir = value("--film") { film(into: dir); return }
        guard args.contains("--showcase") else { return }
        let welcome = value("--showcase") == "welcome"
        if let path = value("--snapshot") {
            // Rendered off-screen: snapshot runs never flash a window on the developer's screen.
            Task {
                try? await Task.sleep(for: .seconds(2.5))  // past the 2 s launch fade
                snapshot(showcaseView(welcome: welcome), to: path)
                exit(0)
            }
            return
        }
        // Same chrome as the real windows: dark, transparent title bar.
        Windows.showcase(showcaseView(welcome: welcome))
        #endif
    }

    #if DEBUG
    /// `--capture DIR`: opens the real popover, Welcome and Settings windows, photographs
    /// them with their chrome, and quits. An app may capture its own windows without Screen
    /// Recording permission, so this shows exactly what users see.
    private static func capture(into dir: String) {
        func shoot(_ window: NSWindow, _ name: String) { writePNG(window, to: "\(dir)/window-\(name).png") }
        Task {
            // The popover alone first: it closes as soon as another window takes focus.
            MenuBarPanel.shared.open()
            try? await Task.sleep(for: .seconds(1.5))
            if let panel = MenuBarPanel.shared.panelWindow { shoot(panel, "popover") }
            MenuBarPanel.shared.close()
            Windows.showWelcome()
            Windows.showSettings()
            try? await Task.sleep(for: .seconds(1.5))
            for window in Windows.all {
                shoot(window, window === Windows.settings ? "settings" : "welcome")
            }
            // Settings scrolled too: its title strip only shows once the form is under it.
            if let settings = Windows.settings, let scroll = settings.contentView?.firstScrollView {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.origin.y + 160))
                scroll.reflectScrolledClipView(scroll.contentView)
                try? await Task.sleep(for: .seconds(0.8))
                shoot(settings, "settings-scrolled")
            }
            exit(0)  // skip the termination handshake; nothing to save in a capture run
        }
    }

    /// Frames of the real popover while Gloam is switched off and on again, as the switch does
    /// it, with a hand setting on first (its footer goes with the switch): animation work is
    /// checked frame by frame instead of by eye. Frames are ~40 ms apart, numbered in order.
    private static func film(into dir: String) {
        Task {
            MenuBarPanel.shared.open()
            try? await Task.sleep(for: .seconds(1.5))
            let model = AppModel.shared
            model.hasOnboarded = true
            model.manual = Tint(kelvin: 2400, brightness: 0.8)
            try? await Task.sleep(for: .seconds(1.5))
            var frame = 0
            @MainActor func roll(_ seconds: Double) async {
                let end = Date().addingTimeInterval(seconds)
                while Date() < end, let panel = MenuBarPanel.shared.panelWindow {
                    writePNG(panel, to: "\(dir)/" + String(format: "frame-%03d.png", frame))
                    frame += 1
                    try? await Task.sleep(for: .milliseconds(40))
                }
            }
            model.enabled = false
            await roll(2.2)
            model.enabled = true
            await roll(1.6)
            exit(0)
        }
    }

    private static func showcaseView(welcome: Bool) -> AnyView {
        welcome ? AnyView(WelcomeView(model: .shared) {}) : AnyView(PopoverView(model: .shared))
    }

    /// SwiftUI-native render; AppKit-backed controls (menus, switches) draw as placeholders.
    /// Framed like the real panel (16 pt continuous corners, the edge and shadow macOS draws
    /// round a window) on a transparent canvas: a plain rectangle read as a crop, not a window.
    /// Drawn, not photographed, so the pictures are the same on any Mac and whatever is plugged in.
    private static func snapshot(_ view: some View, to path: String) {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let framed = view
            .clipShape(shape)
            .overlay(shape.strokeBorder(.white.opacity(0.1), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
            .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
            .padding(.horizontal, 20)  // room for the shadow, no more
            .padding(.top, 14)
            .padding(.bottom, 28)
        let renderer = ImageRenderer(content: framed)
        renderer.scale = 2
        guard let tiff = renderer.nsImage?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
        write(rep, to: path)
    }

    /// A window as it is on screen, chrome included.
    /// In sRGB: a capture carries the screen's own colour profile, which names the panel down to
    /// its serial number, and these images are published (docs/screenshots).
    private static func writePNG(_ window: NSWindow, to path: String) {
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                                  [.bestResolution]),
              let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let converted = context.makeImage() else { return }
        write(NSBitmapImageRep(cgImage: converted), to: path)
    }

    private static func write(_ rep: NSBitmapImageRep, to path: String) {
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
    #endif
}
