// Updates through Sparkle. Gloam isn't notarized, so an update downloaded by hand meets Gatekeeper
// ("Open Anyway") every time; one Sparkle installs carries no quarantine flag and just relaunches.
// The feed is the latest GitHub release's appcast.xml (Info.plist `SUFeedURL`), each update signed
// with the EdDSA key whose public half is `SUPublicEDKey` (the private half is the releaser's, and
// the Release workflow's secret). Checks are on by default (`SUEnableAutomaticChecks`), so Sparkle
// never asks on its own: onboarding asks nothing. The one switch is in Settings; checks are the only
// network use besides a city search.
//
// Sparkle does the checking, verifying and installing; what the user sees is Gloam's: no update
// window, one row in the popover (`Updates.state.status`), because every window is ours. A found update
// downloads quietly and waits there, "ready", for the user's Install; a check they asked for opens
// the popover to answer. Errors from checks nobody asked for stay silent (offline, say).

import AppKit
import Observation
import Sparkle

enum Updates {
    /// What the popover's update row shows.
    enum Status: Equatable {
        case idle, checking, upToDate, failed, installing
        /// `progress` 0…1 once the size is known.
        case downloading(version: String, progress: Double?)
        case ready(version: String)
    }

    static let state = UpdateState()

    /// nil outside a built bundle (`swift run`, showcase and capture runs): no feed, no key, no checks.
    static let updater: SPUUpdater? = {
        guard Bundle.main.bundleURL.pathExtension == "app", !Debug.isShowcase,
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return nil }
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: nil)
        do { try updater.start() } catch { return nil }
        return updater
    }()

    static func checkNow() { updater?.checkForUpdates() }

    /// Installs the update that's ready and relaunches.
    static func install() { driver.install() }

    /// Quitting to install an update: the screens aren't restored on the way out (the update
    /// relaunches at once and resumes them, `DisplayController.follow`), or an evening update
    /// flashed full brightness while it installed.
    fileprivate(set) static var installing = false

    /// Whether Sparkle looks for updates by itself (about once a day).
    static var checksAutomatically: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set { updater?.automaticallyChecksForUpdates = newValue }
    }

    private static let driver = PopoverDriver()
}

@Observable final class UpdateState {
    fileprivate(set) var status = Updates.Status.idle
}

/// Sparkle's user driver, reduced to the popover's one row.
private final class PopoverDriver: NSObject, SPUUserDriver {
    private var installReply: ((SPUUserUpdateChoice) -> Void)?
    private var version = ""
    /// The user asked for this round (Check for Updates…): its failures are shown, not swallowed.
    private var asked = false
    private var expected: UInt64 = 0, received: UInt64 = 0
    private var clearTask: Task<Void, Never>?

    private func show(_ status: Updates.Status, for seconds: Double? = nil) {
        clearTask?.cancel()
        Updates.state.status = status
        guard let seconds else { return }
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.show(.idle)
        }
    }

    func install() {
        guard let reply = installReply else { return }
        installReply = nil
        Updates.installing = true
        show(.installing)
        reply(.install)
    }

    // Never asked: automatic checks are on by default (Info.plist), and switched in Settings.
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        asked = true
        show(.checking)
        MenuBarPanel.shared.open()  // the answer appears there
    }

    /// Downloaded straight away; installing waits for the user.
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        // Information-only items (a release without a download) aren't Gloam's; never "installed".
        guard !appcastItem.isInformationOnlyUpdate else {
            show(asked ? .upToDate : .idle, for: asked ? 4 : nil)
            asked = false
            return reply(.dismiss)
        }
        version = appcastItem.displayVersionString
        show(.downloading(version: version, progress: nil))
        reply(.install)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        asked = false
        show(.upToDate, for: 4)
        acknowledgement()
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        // Only an answer to the user's own check is shown (also when its download fails); a
        // scheduled one fails quietly.
        Updates.installing = false  // an install that failed: a quit after it restores as usual
        show(asked ? .failed : .idle, for: 6)
        asked = false
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        expected = 0
        received = 0
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expected = expectedContentLength
        show(.downloading(version: version, progress: 0))
    }

    /// In whole percents: every chunk would redraw the popover hundreds of times.
    func showDownloadDidReceiveData(ofLength length: UInt64) {
        received += length
        guard expected > 0 else { return }
        let progress = (Double(min(received, expected)) / Double(expected) * 100).rounded(.down) / 100
        if Updates.state.status != .downloading(version: version, progress: progress) {
            show(.downloading(version: version, progress: progress))
        }
    }

    func showDownloadDidStartExtractingUpdate() {}
    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        asked = false
        installReply = reply
        show(.ready(version: version))
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        show(.installing)
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func showUpdateInFocus() { MenuBarPanel.shared.open() }

    func dismissUpdateInstallation() {
        // Sparkle is done with this round; a ready update stays offered until it's installed.
        Updates.installing = false
        if Updates.state.status == .installing || Updates.state.status == .checking { show(.idle) }
    }
}
