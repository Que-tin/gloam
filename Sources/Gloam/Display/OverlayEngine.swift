// Fallback for Macs where gamma tables silently do nothing (see EnginePolicy).
//
// A click-through panel per screen, above everything, painting a warm veil and a black dim
// layer. A window can only alpha-blend over what is behind it (a CALayer multiply filter
// never reaches other apps' pixels), so this lifts blacks slightly instead of truly
// removing blue: honest second best. Panels are excluded from screenshots to match the
// gamma path, whose tint never appears in captures either.

import AppKit
import GloamCore

final class OverlayEngine: TintEngine {
    private var panels: [CGDirectDisplayID: NSPanel] = [:]
    private static let maxVeil = 0.45

    func apply(_ tints: [CGDirectDisplayID: Tint]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            guard let tint = tints[id], !tint.isNeutral else {
                panels[id]?.orderOut(nil)
                continue
            }
            let panel = panels[id] ?? Self.makePanel(for: screen)
            panels[id] = panel
            guard let layers = panel.contentView?.layer?.sublayers, layers.count == 2 else { continue }
            let swatch = Kelvin.swatch(tint.kelvin)
            layers[0].backgroundColor = CGColor(srgbRed: swatch.red, green: swatch.green, blue: swatch.blue, alpha: 1)
            layers[0].opacity = Float(Self.maxVeil * (1 - Kelvin.linearGain(tint.kelvin).blue))
            layers[1].opacity = Float(1 - tint.brightness)
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
        CATransaction.commit()
    }

    func reset() {
        panels.values.forEach { $0.orderOut(nil) }
    }

    func displaysChanged() {
        reset()
        panels.removeAll()
    }

    private static func makePanel(for screen: NSScreen) -> NSPanel {
        let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.sharingType = .none
        panel.hidesOnDeactivate = false
        panel.setFrame(screen.frame, display: false)

        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        for color in [NSColor.orange.cgColor, NSColor.black.cgColor] {
            let layer = CALayer()
            layer.frame = view.bounds
            layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            layer.backgroundColor = color
            layer.opacity = 0
            view.layer?.addSublayer(layer)
        }
        panel.contentView = view
        return panel
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }
}
