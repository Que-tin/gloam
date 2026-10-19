// Gloam in Shortcuts, Spotlight, Siri and Focus (App Intents): set it on, off or toggle it, pause it
// for an hour or until morning, and pause it while a Focus is on. Shortcuts is how most Mac users
// automate (a CLI would reach few), and through it Raycast, Alfred and keyboard shortcuts too.
//
// macOS finds these from the app's Metadata.appintents, which Xcode builds and SwiftPM doesn't:
// `build-app.sh` runs Apple's extractor on the compiler's const values. Without it, a build
// still runs but its actions don't show up in Shortcuts.

import AppIntents
import GloamCore
import AppKit

/// Whether an intent may act in this process: not in a copy that is handing over to a running
/// Gloam (it forwards `url` there instead, if the command has one; the model mustn't even be
/// built, it would dim the screen with nothing to restore it), and not before Welcome's Start.
@MainActor private func mayAct(forwarding url: String? = nil) throws -> Bool {
    if let app = NSApp.delegate as? AppDelegate, app.isHandingOver {
        if let url = url.flatMap(URL.init(string:)) { app.handOver(url) }
        return false
    }
    guard AppModel.shared.hasOnboarded else { throw NotSetUp() }
    return true
}

private struct NotSetUp: Error, CustomLocalizedStringResourceConvertible {
    var localizedStringResource: LocalizedStringResource { "Finish setting up Gloam first." }
}

/// A pause reaching a copy that is handing over: no URL carries it, so it says so, not "done".
private struct HandingOver: Error, CustomLocalizedStringResourceConvertible {
    var localizedStringResource: LocalizedStringResource { "Gloam was just starting; run the shortcut again." }
}

enum GloamPower: String, AppEnum {
    case on, off, toggle
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Gloam"
    static let caseDisplayRepresentations: [GloamPower: DisplayRepresentation] = [
        .on: "On", .off: "Off", .toggle: "On or Off",  // "Turn Gloam On or Off": a toggle
    ]
}

/// "Set Gloam", as Shortcuts' own "Set Night Shift" works.
struct SetGloamIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Gloam"
    static let description = IntentDescription("Turns Gloam on or off, or toggles it.",
                                               searchKeywords: ["night shift", "blue light", "warm", "dim", "screen"])
    @Parameter(title: "State", default: .toggle) var state: GloamPower
    static var parameterSummary: some ParameterSummary { Summary("Turn Gloam \(\.$state)") }

    @MainActor func perform() async throws -> some IntentResult {
        let command: Command = state == .on ? .on : state == .off ? .off : .toggle
        if try mayAct(forwarding: "gloam://\(state.rawValue)") { AppModel.shared.run(command) }
        return .result()
    }
}

enum PauseLength: String, AppEnum {
    case hour, morning
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Pause"
    static let caseDisplayRepresentations: [PauseLength: DisplayRepresentation] = [
        .hour: "For an Hour", .morning: "Until Morning",
    ]
}

/// The menu's timed pause: ends by itself.
struct PauseGloamIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause Gloam"
    static let description = IntentDescription("Turns Gloam off for an hour or until morning; it comes back by itself.",
                                               searchKeywords: ["night shift", "blue light", "disable", "screen"])
    @Parameter(title: "For", default: .hour) var length: PauseLength
    static var parameterSummary: some ParameterSummary { Summary("Pause Gloam \(\.$length)") }

    @MainActor func perform() async throws -> some IntentResult {
        guard try mayAct() else { throw HandingOver() }
        let model = AppModel.shared
        model.turnOff(until: length == .hour ? model.now.addingTimeInterval(3600) : model.nextMorning)
        return .result()
    }
}

/// Settings › Focus › (a Focus) › Focus filters › Gloam. macOS runs it again when the Focus ends,
/// with defaults or (reported for non-optional values) not at all: optional, and unset means no
/// pause, so a Focus ending always hands Gloam back.
struct GloamFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Pause Gloam"
    static let description = IntentDescription("Pauses Gloam while this Focus is on, for photo editing or watching a film.")
    @Parameter(title: "Pause Gloam") var pause: Bool?
    var displayRepresentation: DisplayRepresentation {
        pause == true ? "Gloam paused" : "Gloam as usual"
    }

    @MainActor func perform() async throws -> some IntentResult {
        // Before Start too: it only holds the tint, and Start then begins as the Focus has it.
        if let app = NSApp.delegate as? AppDelegate, app.isHandingOver { return .result() }
        AppModel.shared.pausedByFocus = pause == true
        return .result()
    }
}

/// Ready-made in Spotlight and Shortcuts, no setup: "Turn Gloam off", "Pause Gloam".
struct GloamShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SetGloamIntent(), phrases: [
            "Toggle \(.applicationName)",
            "Turn \(.applicationName) \(\.$state)",
        ], shortTitle: "Set Gloam", systemImageName: "power")
        AppShortcut(intent: PauseGloamIntent(), phrases: [
            "Pause \(.applicationName)",
            "Pause \(.applicationName) \(\.$length)",
        ], shortTitle: "Pause Gloam", systemImageName: "pause.circle")
    }
}
