// Makes a screen draw a new frame now. A gamma table written to a still screen may show only at
// its next redraw (a known Apple silicon quirk), the likely cause of a dark blink
// on a DDC monitor as a fade settled: the monitor's brightness step landed at once while the
// signal that evens it out (`DisplayController.signalShare`) waited for a frame. The fix:
// a dot in a corner whose opacity flips between two values too faint to see, which
// the window server must composite.

import AppKit

final class Redraw {
    private var dots: [CGDirectDisplayID: NSPanel] = [:]
    private var flip = false

    /// A new frame on each of these displays; dots on other displays go.
    func nudge(_ ids: Set<CGDirectDisplayID>) {
        for (id, dot) in dots where !ids.contains(id) {
            dot.orderOut(nil)
            dots[id] = nil
        }
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
    }

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
