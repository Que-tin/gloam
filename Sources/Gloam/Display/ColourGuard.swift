// Clears the colour layer when Gloam ends however it ends. The layer outlives the process that
// set it (measured: a tint stayed after `kill -9`, until a restart), so a crash would otherwise
// leave the screen warm until the next launch, which clears it first thing (`ColourLayer.clearAll`).
//
// Gloam starts a second copy of itself, `Gloam --guard <pid>`, that only waits: the kernel tells
// it the moment that pid exits (a crash, a force quit, a kill), and it clears the layer back to
// the system Color Filter, draws a frame on every screen (a still screen showed the cleared layer
// only when something moved: measured, it stayed warm) and exits. It is no running application
// until then, and the single-instance check also skips it by its argument; Gloam starts it again
// if it ends first. Both killed together (logout, shutdown) leaves the layer to the next
// launch or the restart. macOS offers no "clear when the setter exits" option that anyone has
// documented, and other users of this layer clear it only on a normal quit.

import AppKit

enum ColourGuard {
    static let flag = "--guard"

    /// In the guard process: waits for `pid` to end, then clears the layer. Never returns.
    static func run(watching pid: pid_t) -> Never {
        // Its own session: a terminal closing (SIGHUP to `swift run`'s group) took it with Gloam.
        setsid()
        let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        exit.setEventHandler { @Sendable in MainActor.assumeIsolated { clear() } }
        exit.resume()
        // Gone before the watch began: no exit event would come.
        if kill(pid, 0) != 0 { clear() }
        RunLoop.main.run()
        Foundation.exit(0)
    }

    /// Clears the layer, shows it cleared, and ends the guard.
    private static func clear() {
        ColourLayer.clearAll()
        NSApplication.shared.setActivationPolicy(.prohibited)
        let redraw = Redraw()
        redraw.everyScreen()
        // The dots' frame drawn, then the process ends, taking them with it (another frame).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { _ = redraw; Foundation.exit(0) }
    }

    /// In Gloam: the guard for this process, started again a few seconds after it ends.
    static func start() {
        guard let executable = Bundle.main.executableURL else { return }
        let guardProcess = Process()
        guardProcess.executableURL = executable
        guardProcess.arguments = [flag, String(ProcessInfo.processInfo.processIdentifier)]
        guard (try? guardProcess.run()) != nil else { return }
        let ended = DispatchSource.makeProcessSource(identifier: guardProcess.processIdentifier, eventMask: .exit, queue: .main)
        ended.setEventHandler { @Sendable in
            MainActor.assumeIsolated {
                watcher?.cancel()
                watcher = nil
            }
            // Not at once: a guard that can't start (a moved app) mustn't be restarted in a loop.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { MainActor.assumeIsolated { start() } }
        }
        ended.resume()
        watcher = ended
    }

    /// Kept, so the exit watch lives as long as the guard does.
    private static var watcher: DispatchSourceProcess?
}
