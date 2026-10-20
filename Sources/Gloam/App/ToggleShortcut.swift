// One global keyboard shortcut that turns Gloam on or off from anywhere, set in Settings ›
// General. Carbon's RegisterEventHotKey: it needs no Accessibility permission (watching every key
// press would) and is what every hotkey tool builds on. Asked for exclusively first, which tells
// whether another app's global shortcut uses the same keys; then it's registered shared and the
// recorder warns (someone may want both to react). System shortcuts (System Settings › Keyboard)
// and apps' menu commands can't be detected this way.

import AppKit
import Carbon.HIToolbox

/// A key with at least one of ⌃⌥⌘, or a function key alone (Carbon's modifier bits), and how it
/// reads ("⌃⌥G").
struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var label: String

    /// From a key press in the recorder; nil for a plain key without ⌃, ⌥ or ⌘ (it would swallow
    /// typing everywhere). Function keys may stand alone, as in other apps.
    init?(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .option, .control]).isEmpty || Self.functionKeys.contains(Int(event.keyCode))
        else { return nil }
        var carbon: UInt32 = 0
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        keyCode = UInt32(event.keyCode)
        modifiers = carbon
        label = Self.symbols(flags) + Self.name(of: event)
    }

    /// ⌃⌥⇧⌘ as held now, in Apple's order: the recorder shows them while you press.
    static func symbols(_ flags: NSEvent.ModifierFlags) -> String {
        [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { flags.contains($0.0) }.map(\.1).joined()
    }

    private static let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8,
                                       kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15]

    private static func name(of event: NSEvent) -> String {
        let named: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋", kVK_Delete: "⌫",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        ]
        if let name = named[Int(event.keyCode)] { return name }
        if let f = functionKeys.firstIndex(of: Int(event.keyCode)) { return "F\(f + 1)" }
        // The key's own character, without Shift's: ⇧⌘1 reads "⇧⌘1", not "⇧⌘!".
        return (event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? "?").uppercased()
    }
}

/// The registered shortcut; pressing it toggles Gloam.
final class ToggleShortcut {
    /// How a registration went: Gloam's alone, shared with another app's global shortcut (both
    /// react), or refused altogether (nothing registered).
    enum Outcome { case alone, shared, failed }

    static let shared = ToggleShortcut()
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    /// Registers `combo` in place of the current one (nil clears it).
    @discardableResult func register(_ combo: KeyCombo?) -> Outcome {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        guard let combo else { return .alone }
        installHandler()
        let id = EventHotKeyID(signature: OSType(0x474C_4D20), id: 1)  // "GLM "
        let target = GetApplicationEventTarget()
        if RegisterEventHotKey(combo.keyCode, combo.modifiers, id, target, OptionBits(kEventHotKeyExclusive), &hotKey) == noErr {
            return .alone
        }
        hotKey = nil
        return RegisterEventHotKey(combo.keyCode, combo.modifiers, id, target, 0, &hotKey) == noErr ? .shared : .failed
    }

    private func installHandler() {
        guard handler == nil else { return }
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Not before Welcome's Start (a shortcut left from an earlier install): Start would begin off.
                    if AppModel.shared.hasOnboarded { AppModel.shared.run(.toggle) }
                }
            }
            return noErr
        }, 1, &pressed, nil, &handler)
    }
}
