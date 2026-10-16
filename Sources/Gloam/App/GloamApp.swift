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
            NSMenuItem(title: "Settings…", action: #selector(AppDelegate.showSettings), keyEquivalent: ","),
            .separator(),
            NSMenuItem(title: "Quit Gloam", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"),
        ])
        submenu("Edit", [
            NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"),
            NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"),
            .separator(),
            NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"),
            NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
            NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
            NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"),
        ])
        submenu("Window", [
            NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"),
        ])
        return menu
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @objc func showSettings() { Windows.showSettings() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let others = Bundle.main.bundleIdentifier.map {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0)
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        } ?? []
        // `Gloam --uninstall`: forget everything (login item, settings) for a clean slate.
        if CommandLine.arguments.contains("--uninstall") {
            guard let id = Bundle.main.bundleIdentifier else {
                print("Gloam: --uninstall needs the app bundle (run .build/Gloam.app/Contents/MacOS/Gloam).")
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
            print("Gloam: \(others.isEmpty ? "" : "quit the running copy; ")login item \(login == .enabled ? "removed" : "was not set"); settings cleared.")
            exit(0)
        }
        // One Gloam at a time: two would fight over the screen's colour table. A second launch
        // opens the running one's panel and quits.
        if !others.isEmpty {
            NSWorkspace.shared.open(URL(string: "gloam://open")!)
            exit(0)
        }
        // Also covers `swift run`, where there is no Info.plist to say LSUIElement.
        NSApp.setActivationPolicy(.accessory)
        Debug.applyLaunchArguments()
        // The menu-bar icon arrives with Start: until then Welcome is the whole app.
        if AppModel.shared.hasOnboarded || Debug.isShowcase { MenuBarPanel.shared.install() } else { Windows.showWelcome() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for command in urls.compactMap(Command.init(url:)) {
            if command != .open { AppModel.shared.run(command) }
            else if AppModel.shared.hasOnboarded { MenuBarPanel.shared.open() }
            else { Windows.showWelcome() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.flushSave()
        AppModel.shared.display.restore()
    }
}

/// The Settings and Welcome windows, created on demand and reused.
enum Windows {
    private static var settings: NSWindow?
    fileprivate static var welcome: NSWindow?

    static func showSettings() {
        AppModel.shared.refreshLoginStatus()
        settings = settings ?? make(SettingsView(model: .shared), title: "Gloam Settings")
        present(settings!)
    }

    /// Closing the window before Start quits without saving (the next launch shows Welcome
    /// again); Start saves, then shows the menu-bar icon with its popover open beneath it.
    static func showWelcome() {
        welcome = welcome ?? make(WelcomeView(model: .shared) { welcome?.close() }, title: "Welcome to Gloam")
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
    /// there's no grey system strip above the panel.
    private static func make(_ view: some View, title: String) -> NSWindow {
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = [.preferredContentSize]  // windows follow their content (Welcome's preview sliders)
        let window = NSWindow(contentViewController: controller)
        window.title = title
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(Lamp.surface)
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    static var anyVisible: Bool { [settings, welcome].contains { $0?.isVisible == true } }

    #if DEBUG
    static var all: [NSWindow] { [settings, welcome].compactMap { $0 } }
    #endif

    /// `activate()` is only a request since macOS 14 and is refused for an app launched in
    /// the background (login, Finder while busy), which left Welcome hidden behind other
    /// windows; ordering front regardless keeps the window visible either way.
    private static func present(_ window: NSWindow) {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}

/// Debug-build launch flags for screenshots and UI work; inert in release builds.
///   --capture DIR     photograph the real popover, Welcome and Settings windows, then quit
///   --at HH:MM        run the app's clock at that time of day
///   --onboarded, --off   start as if set up / switched off
///   --showcase [welcome]  show the popover (or the welcome view) in an ordinary window
///   --snapshot PATH   render the showcase to PATH and quit (never touches the screen)
enum Debug {
    #if DEBUG
    static let isSnapshot = CommandLine.arguments.contains("--snapshot")
    static let isCapture = CommandLine.arguments.contains("--capture")
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
        if let dir = value("--capture") { capture(into: dir); return }
        guard args.contains("--showcase") else { return }
        let welcome = value("--showcase") == "welcome"
        if let path = value("--snapshot") {
            // Rendered off-screen: snapshot runs never flash a window on the developer's screen.
            Task {
                try? await Task.sleep(for: .seconds(1))
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
        func shoot(_ window: NSWindow, _ name: String) {
            guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                                      [.bestResolution]) else { return }
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("window-\(name).png"))
        }
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
                shoot(window, window.title == "Gloam Settings" ? "settings" : "welcome")
            }
            exit(0)  // skip the termination handshake; nothing to save in a capture run
        }
    }

    private static func showcaseView(welcome: Bool) -> AnyView {
        welcome ? AnyView(WelcomeView(model: .shared) {}) : AnyView(PopoverView(model: .shared))
    }

    /// SwiftUI-native render; AppKit-backed controls (menus, switches) draw as placeholders.
    private static func snapshot(_ view: some View, to path: String) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let tiff = renderer.nsImage?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
    #endif
}
