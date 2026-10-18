// The menu-bar item and its panel, in AppKit rather than SwiftUI's MenuBarExtra.
//
// Why not MenuBarExtra: it owns its window and draws system chrome (a grey/glass backdrop)
// around content that can't be styled, can't be opened from code, and so can't be checked in
// a screenshot. A borderless panel we own shows exactly the lamp: nothing grey, nothing extra.

import AppKit
import GloamCore
import Observation
import SwiftUI

final class MenuBarPanel: NSObject, NSWindowDelegate {
    static let shared = MenuBarPanel()

    /// Created on first use: before Start there is no menu-bar icon at all.
    private lazy var item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var panel: LampPanel?
    private var outsideClicks: Any?

    func install() {
        guard let button = item.button, button.target == nil else { return }
        button.target = self
        button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        refreshIcon()
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            toggle()
        }
    }

    func toggle() {
        if panel?.isVisible == true { close() } else { open() }
    }

    /// Right-click: the shortcuts people expect from a menu-bar item.
    private func showMenu() {
        close()
        let model = AppModel.shared
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Settings…"), action: #selector(openSettings), keyEquivalent: "").target = self
        if case .ready(let version) = Updates.state.status {
            menu.addItem(withTitle: String(localized: "Install Gloam \(version) and Restart"), action: #selector(installUpdate), keyEquivalent: "").target = self
        } else if Updates.updater != nil {
            menu.addItem(withTitle: String(localized: "Check for Updates…"), action: #selector(checkForUpdates), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        if model.enabled {
            menu.addItem(withTitle: String(localized: "Turn Gloam Off"), action: #selector(toggleEnabled), keyEquivalent: "").target = self
            // The pause people reach for most: each one ends by itself.
            let pause = NSMenu()
            pause.addItem(withTitle: String(localized: "For an Hour"), action: #selector(offForAnHour), keyEquivalent: "").target = self
            pause.addItem(withTitle: String(localized: "Until Morning"), action: #selector(offUntilMorning), keyEquivalent: "").target = self
            let item = menu.addItem(withTitle: String(localized: "Pause"), action: nil, keyEquivalent: "")
            menu.setSubmenu(pause, for: item)
        } else {
            let title = model.resumeAt.map { String(localized: "Resume Gloam (Paused Until \(Format.time($0)))") }
                ?? String(localized: "Turn Gloam On")
            menu.addItem(withTitle: title, action: #selector(toggleEnabled), keyEquivalent: "").target = self
        }
        // An app exception is permanent (Settings › Apps that pause Gloam), so it sits apart from
        // the timed offs, which all end by themselves.
        if let app = model.frontmost, let name = app.localizedName {
            menu.addItem(.separator())
            if model.excludedApps.contains(where: { $0.bundleID == app.bundleIdentifier }) {
                menu.addItem(withTitle: String(localized: "Stop Pausing for \(name)"), action: #selector(includeFrontmost), keyEquivalent: "").target = self
            } else {
                menu.addItem(withTitle: String(localized: "Always Pause for \(name)"), action: #selector(excludeFrontmost), keyEquivalent: "").target = self
            }
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Quit Gloam"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        item.menu = menu
        item.button?.performClick(nil)  // shows the menu attached to the item
        item.menu = nil                 // so the next left-click opens the panel again
    }

    @objc private func openSettings() { Windows.showSettings() }
    @objc private func checkForUpdates() { Updates.checkNow() }
    @objc private func installUpdate() { Updates.install() }
    @objc private func toggleEnabled() { AppModel.shared.enabled.toggle() }
    @objc private func offForAnHour() { AppModel.shared.turnOff(until: AppModel.shared.now.addingTimeInterval(3600)) }
    @objc private func offUntilMorning() { AppModel.shared.turnOff(until: AppModel.shared.nextMorning) }
    @objc private func excludeFrontmost() { AppModel.shared.excludeFrontmost() }
    @objc private func includeFrontmost() {
        let id = AppModel.shared.frontmost?.bundleIdentifier
        AppModel.shared.excludedApps.removeAll { $0.bundleID == id }
    }

    func open() {
        guard panel == nil, let button = item.button, let buttonWindow = button.window else { return }
        AppModel.shared.refreshNow()
        AppModel.shared.display.watchingClosely = true  // follow brightness keys at 2 Hz while visible
        let panel = LampPanel()
        // The controller sizes the panel to its content, so a notice appearing while it's open
        // grows it rather than clipping it (`LampPanel.top` keeps the top edge in place).
        let controller = NSHostingController(rootView: PopoverView(model: .shared))
        controller.sizingOptions = [.preferredContentSize]
        panel.contentViewController = controller
        controller.view.wantsLayer = true
        controller.view.layer?.cornerRadius = 16
        controller.view.layer?.cornerCurve = .continuous
        controller.view.layer?.masksToBounds = true
        controller.view.layoutSubtreeIfNeeded()
        panel.setContentSize(controller.view.fittingSize)
        panel.delegate = self

        // Centred under the menu-bar icon, kept on screen.
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var origin = NSPoint(x: anchor.midX - panel.frame.width / 2, y: anchor.minY - panel.frame.height - 6)
        origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - panel.frame.width - 8)
        panel.setFrameOrigin(origin)
        panel.top = origin.y + panel.frame.height

        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        button.highlight(true)
        self.panel = panel
        // Capture runs film while the developer keeps working: their clicks must not close it.
        guard !Debug.isCapture else { return }
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
    }

    func close() {
        // Nothing open (a right-click): hiding the app would hide whatever is in front.
        guard panel != nil else { return }
        AppModel.shared.display.watchingClosely = false
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        outsideClicks = nil
        item.button?.highlight(false)
        panel?.orderOut(nil)
        panel?.contentViewController = nil  // tears the popover's view down while it's hidden
        panel = nil
        // Hand focus back to the app you came from: an active Gloam with no window would
        // otherwise swallow your next ⌘, (or any shortcut) meant for that app.
        if !Windows.anyVisible { NSApp.hide(nil) }
    }

    #if DEBUG
    var panelWindow: NSWindow? { panel }
    #endif

    func windowDidResignKey(_ notification: Notification) {
        // Menus and dialogs opened from the panel keep it; anything else closes it. Capture runs
        // aren't the active app, so focus wanders and would close the panel mid-film.
        guard !Debug.isCapture, let panel, NSApp.keyWindow?.parent != panel, !(NSApp.keyWindow is LampPanel) else { return }
        if NSApp.modalWindow == nil, panel.attachedSheet == nil { close() }
    }

    /// Keeps the menu-bar glyph in step with the model, re-arming after each change.
    private func refreshIcon() {
        let model = AppModel.shared
        withObservationTracking {
            let mode: GloamGlyph.Mode = !model.enabled ? .off : model.excludedFrontmost != nil ? .aside : .running
            // Cached images: assign only when it changes (this re-runs on every model change).
            let image = GloamGlyph.cached(mode: mode, depth: model.eveningDepth)
            if item.button?.image !== image { item.button?.image = image }
            // This re-runs every tick (the depth reads the clock): set the label only when it changes.
            // A timed off says when it ends, here too: the glyph alone looks like any other off.
            let label = !model.enabled
                ? model.resumeAt.map { String(localized: "Gloam, paused until \(Format.time($0))") } ?? String(localized: "Gloam, off")
                : model.excludedFrontmost.map { String(localized: "Gloam, paused for \($0.name)") }
                    ?? String(localized: "Gloam, \(model.stage.title)")
            if item.button?.accessibilityLabel() != label { item.button?.setAccessibilityLabel(label) }
            let tip = !model.enabled ? model.resumeAt.map { String(localized: "Gloam is paused until \(Format.time($0))") } : nil
            if item.button?.toolTip != tip { item.button?.toolTip = tip }
        } onChange: {
            DispatchQueue.main.async { MenuBarPanel.shared.refreshIcon() }
        }
    }
}

/// A borderless panel that can take keyboard focus (for the dial and ladder) and
/// closes on Escape.
private final class LampPanel: NSPanel {
    /// The panel hangs from the menu bar: when its content changes height, the top edge stays
    /// put. Applied inside the resize itself; moving it back afterwards (windowDidResize) drew
    /// one frame at the old origin, a visible jump.
    var top: CGFloat?

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var frame = frameRect
        if let top { frame.origin.y = top - frame.height }
        super.setFrame(frame, display: flag)
    }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        appearance = NSAppearance(named: .darkAqua)
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        MenuBarPanel.shared.close()
    }
}
