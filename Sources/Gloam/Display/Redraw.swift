// Makes a screen draw a new frame now. A colour layer written to a still screen shows only at its
// next frame (measured: a monitor showed it 5–10 s late, its reversal not at all), and so did the
// signal evening out a DDC monitor's brightness step (`DisplayController.signalShare`): a dark
// blink as a fade settled. The fix: a dot in a corner whose opacity flips between two values too
// faint to see, which the window server must composite. Ordered out a moment later: left up, a
// window above everything stayed on every tinted screen all evening (and can keep full-screen
// video from going straight to the display), and came back as a new window each time.

import AppKit

final class Redraw {
    private var dots: [CGDirectDisplayID: NSPanel] = [:]
    private var flip = false
    private var hide: DispatchWorkItem?

    /// A new frame on each of these displays.
    func nudge(_ ids: Set<CGDirectDisplayID>) {
        guard !ids.isEmpty else { return }
        flip.toggle()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for screen in NSScreen.screens {
            guard let id = screen.displayID, ids.contains(id) else { continue }
            let dot = dots[id] ?? Self.makeDot(on: screen)
            dots[id] = dot
            dot.contentView?.layer?.opacity = flip ? 0.01 : 0.02
            if !dot.isVisible { dot.orderFrontRegardless() }
        }
        CATransaction.commit()
        // Its frame drawn, the dot goes (another frame), until the next nudge: a fade's frames
        // keep it up while it runs.
        hide?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.dots.values.forEach { $0.orderOut(nil) } }
        hide = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: item)
    }

    /// A new frame on every screen: a change made for all of them (the layer cleared) shows now.
    func everyScreen() { nudge(Set(NSScreen.screens.compactMap(\.displayID))) }

    /// Screens moved: dots are placed afresh on the next nudge.
    func displaysChanged() {
        dots.values.forEach { $0.orderOut(nil) }
        dots.removeAll()
    }

    private static func makeDot(on screen: NSScreen) -> NSPanel {
        let frame = NSRect(x: screen.frame.minX, y: screen.frame.minY, width: 2, height: 2)
        let panel = NSPanel.clickThrough(frame: frame)
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        panel.contentView = view
        return panel
    }
}

extension NSPanel {
    /// A borderless panel above everything (the shielding level), on every Space, that never
    /// takes clicks or focus and stays out of screenshots: `Redraw`'s dots.
    static func clickThrough(frame: NSRect) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.sharingType = .none
        panel.hidesOnDeactivate = false
        return panel
    }
}
