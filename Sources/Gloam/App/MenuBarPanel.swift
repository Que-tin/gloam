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

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var panel: LampPanel?
    private var outsideClicks: Any?
    /// The panel hangs from the menu bar: when it changes height its top edge stays put.
    private var top: CGFloat = 0

    func install() {
        guard let button = item.button else { return }
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
        // Until setup is finished the icon leads back to Welcome, wherever that window went.
        if !AppModel.shared.hasOnboarded { return Windows.showWelcome() }
        if panel?.isVisible == true { close() } else { open() }
    }

    /// Right-click: the shortcuts people expect from a menu-bar item.
    private func showMenu() {
        close()
        let model = AppModel.shared
        let menu = NSMenu()
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: "").target = self
        menu.addItem(withTitle: model.enabled ? "Turn Gloam Off" : "Turn Gloam On", action: #selector(toggleEnabled), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Gloam", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        item.menu = menu
        item.button?.performClick(nil)  // shows the menu attached to the item
        item.menu = nil                 // so the next left-click opens the panel again
    }

    @objc private func openSettings() { Windows.showSettings() }
    @objc private func toggleEnabled() { AppModel.shared.enabled.toggle() }

    func open() {
        guard panel == nil, let button = item.button, let buttonWindow = button.window else { return }
        let panel = LampPanel()
        // The controller sizes the panel to its content, so a notice appearing while it's open
        // grows it rather than clipping it (windowDidResize keeps the top edge in place).
        let controller = NSHostingController(rootView: PopoverView(model: .shared))
        controller.sizingOptions = [.preferredContentSize]
        panel.contentViewController = controller
        controller.view.wantsLayer = true
        controller.view.layer?.cornerRadius = 16
        controller.view.layer?.cornerCurve = .continuous
        controller.view.layer?.masksToBounds = true
        panel.setContentSize(controller.view.fittingSize)
        panel.delegate = self

        // Centred under the menu-bar icon, kept on screen.
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var origin = NSPoint(x: anchor.midX - panel.frame.width / 2, y: anchor.minY - panel.frame.height - 6)
        origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - panel.frame.width - 8)
        panel.setFrameOrigin(origin)
        top = origin.y + panel.frame.height

        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        button.highlight(true)
        self.panel = panel
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
    }

    func close() {
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

    func windowDidResize(_ notification: Notification) {
        guard let panel, abs(panel.frame.maxY - top) > 0.5 else { return }
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: top - panel.frame.height))
    }

    func windowDidResignKey(_ notification: Notification) {
        // Menus (the gear) and dialogs opened from the panel keep it; anything else closes it.
        guard let panel, NSApp.keyWindow?.parent != panel, !(NSApp.keyWindow is LampPanel) else { return }
        if NSApp.modalWindow == nil, panel.attachedSheet == nil { close() }
    }

    /// Keeps the menu-bar glyph in step with the model, re-arming after each change.
    private func refreshIcon() {
        let model = AppModel.shared
        withObservationTracking {
            let mode: GloamGlyph.Mode = !model.enabled ? .off : model.excludedFrontmost != nil ? .aside : .running
            item.button?.image = GloamGlyph.cached(mode: mode, depth: model.eveningDepth)
            item.button?.setAccessibilityLabel(!model.enabled ? "Gloam, off"
                : mode == .aside ? "Gloam, stepping aside" : "Gloam, \(model.stage.title)")
        } onChange: {
            DispatchQueue.main.async { MenuBarPanel.shared.refreshIcon() }
        }
    }
}

/// A borderless panel that can take keyboard focus (for the dial and ladder) and
/// closes on Escape.
private final class LampPanel: NSPanel {
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
