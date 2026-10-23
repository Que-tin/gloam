import Foundation
import Testing
@testable import GloamCore

@Suite struct BacklightReportsTests {
    static let t0 = Date(timeIntervalSinceReferenceDate: 0)
    static func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    // Gloam's own light writes come back as plain steps and are nothing; several close together
    // may come back as one.
    @Test func ownWritesAreEchoes() {
        var r = BacklightReports()
        for i in 0..<5 { r.wrote(at: Self.at(Double(i) * 0.016), level: false) }
        r.step(byUser: false, at: Self.at(0.08))
        #expect(!r.holds(at: Self.at(0.1)) && !r.broken(at: Self.at(60)))
        #expect(r.settled(.user) == nil)
    }

    // A press during a fade is the user's, never an echo: writes wait, and its settled report counts.
    @Test func aPressDuringAFadeIsTheUsers() {
        var r = BacklightReports()
        r.wrote(at: Self.at(0), level: false)
        r.step(byUser: true, at: Self.at(0.01))
        #expect(r.holds(at: Self.at(1)) && r.moving?.by == .user)
        #expect(r.settled(.user) == .user)
        #expect(!r.holds(at: Self.at(1.1)))
    }

    // Plain steps with no write before them are auto-brightness; a ramp holds writes while it
    // runs, up to 2.5 s past its last step, never past 30 s in all.
    @Test func aRampHoldsWritesUntilItSettles() {
        var r = BacklightReports()
        for i in 0..<100 { r.step(byUser: false, at: Self.at(Double(i) * 0.1)) }
        #expect(r.holds(at: Self.at(11)) && !r.holds(at: Self.at(12.5)))
        var long = BacklightReports()
        for i in 0..<400 { long.step(byUser: false, at: Self.at(Double(i) * 0.1)) }
        #expect(!long.holds(at: Self.at(30)))
        #expect(r.settled(.macOS) == .macOS)
    }

    // A settled report with nothing of its source behind it is acted on by nobody: the release's
    // own "user" report, or a state with no ramp.
    @Test func aSettledReportNeedsAMoveBehindIt() {
        var r = BacklightReports()
        r.wrote(at: Self.at(0), level: true)
        r.step(byUser: true, at: Self.at(0.05))
        r.step(byUser: false, at: Self.at(0.06))
        #expect(!r.holds(at: Self.at(0.1)))
        #expect(r.settled(.user) == nil)
        #expect(r.settled(.macOS) == nil)
    }

    // A hold that runs out without its report is the user's if they moved; plain steps that never
    // settled were late echoes, and are nobody's.
    @Test func anExpiredHoldKnowsWhoseItWas() {
        var r = BacklightReports()
        r.step(byUser: false, at: Self.at(0))
        #expect(r.expired(at: Self.at(1)) == nil)
        #expect(r.expired(at: Self.at(3)) == nil && r.moving == nil)
        r.step(byUser: false, at: Self.at(10))
        r.step(byUser: true, at: Self.at(10.5))
        r.step(byUser: false, at: Self.at(10.6))
        #expect(r.expired(at: Self.at(14)) == .user)
    }

    // A fade's echoes arriving late are still echoes: no hold, nothing for macOS. A write long
    // past swallows nothing: the next plain step is a ramp.
    @Test func lateEchoesAreEchoesAndOldWritesAreNot() {
        var r = BacklightReports()
        for i in 0..<10 { r.wrote(at: Self.at(Double(i) * 0.016), level: false) }
        r.step(byUser: false, at: Self.at(0.2))
        r.step(byUser: false, at: Self.at(0.3))
        #expect(r.moving == nil && r.settled(.user) == nil)
        r.step(byUser: false, at: Self.at(120))
        #expect(r.moving?.by == .macOS)
    }

    // auto-brightness settling under a press waits for the press's report; another reason (a
    // thermal cap) adopts nothing and ends the hold.
    @Test func aPressUnderARampIsTheUsersAndOtherReasonsAdoptNothing() {
        var r = BacklightReports()
        r.step(byUser: false, at: Self.at(0))
        r.step(byUser: true, at: Self.at(0.5))
        #expect(r.settled(.macOS) == nil && r.holds(at: Self.at(1)))
        #expect(r.settled(.user) == .user)
        r.step(byUser: false, at: Self.at(10))
        #expect(r.settled(nil) == nil && !r.holds(at: Self.at(10.1)))
    }

    // Auto-brightness during a fade: its steps pass for echoes, its settled report still counts
    // (the controller checks the panel moved).
    @Test func aRampUnderAFadeStillSettles() {
        var r = BacklightReports()
        r.wrote(at: Self.at(0), level: false)
        r.step(byUser: false, at: Self.at(0.1))
        #expect(r.settled(.macOS) == .macOS)
        #expect(r.settled(.macOS) == nil)
    }

    // Writes nobody reports back, five of them over five seconds: the reports stopped.
    @Test func silentWritesMeanTheReportsBroke() {
        var r = BacklightReports()
        for i in 0..<4 { r.wrote(at: Self.at(Double(i) * 2), level: false) }
        #expect(!r.broken(at: Self.at(20)))
        r.wrote(at: Self.at(8), level: false)
        #expect(!r.broken(at: Self.at(4)) && r.broken(at: Self.at(8.1)))
        r.step(byUser: false, at: Self.at(9))
        #expect(!r.broken(at: Self.at(9.1)))
    }
}
