// Updates through Sparkle. Gloam isn't notarized, so an update downloaded by hand meets Gatekeeper
// ("Open Anyway") every time; one Sparkle installs carries no quarantine flag and just relaunches.
// The feed is the latest GitHub release's appcast.xml (Info.plist `SUFeedURL`), each update signed
// with the EdDSA key whose public half is `SUPublicEDKey` (the private half stays in the
// releaser's Keychain). Checks are on by default (`SUEnableAutomaticChecks`), so Sparkle never asks
// on its own: onboarding asks nothing. The one switch is in Settings; checks are the only network
// use besides a city search.

import AppKit
import Sparkle

enum Updates {
    /// nil outside a built bundle (`swift run`, showcase and capture runs): no feed, no key, no checks.
    static let controller: SPUStandardUpdaterController? = {
        guard Bundle.main.bundleURL.pathExtension == "app", !Debug.isShowcase,
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return nil }
        return SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: reminders)
    }()

    static func checkNow() { controller?.checkForUpdates(nil) }

    /// Whether Sparkle looks for updates by itself (about once a day).
    static var checksAutomatically: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    /// A menu-bar app has no Dock icon to badge, so a scheduled update's window is brought to the
    /// front instead of waiting behind other apps' windows.
    private static let reminders = Reminders()
    private final class Reminders: NSObject, SPUStandardUserDriverDelegate {
        var supportsGentleScheduledUpdateReminders: Bool { true }
        func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                       state: SPUUserUpdateState) {
            if handleShowingUpdate { NSApp.activate() }
        }
    }
}
