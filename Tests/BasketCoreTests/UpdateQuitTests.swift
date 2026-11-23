import Testing
import Foundation
@testable import BasketCore

/// `UpdateQuit` against a stand-in for AppKit: `terminate` is refused while a sheet is attached
/// or a modal session runs ("App termination blocked by modal sheet"), as NSApp does.
@MainActor
@Suite("Update quit")
struct UpdateQuitTests {
    @MainActor
    final class FakeApp {
        /// The update sheet: detaches `detachPolls` polls after it was dismissed (its animation).
        var updateSheet = true
        var detachPolls = 2
        private var dismissedAt: Int?
        /// Another sheet (an alert, a confirmation) that only `endSheetsAndModals` closes.
        var otherSheet = false
        /// A modal session `endSheetsAndModals` can't abort (the last-resort case).
        var stuckModal = false
        var alive = true
        var aliveChecks = 0
        var events: [String] = []
        var logs: [String] = []
        private var polls = 0

        var steps: UpdateQuit.Steps {
            UpdateQuit.Steps(
                dismissUpdateSheet: { [self] in
                    events.append("dismiss")
                    dismissedAt = polls
                },
                hasAttachedSheet: { [self] in
                    polls += 1
                    if let dismissedAt, updateSheet, polls - dismissedAt >= detachPolls { updateSheet = false }
                    return updateSheet || otherSheet
                },
                terminate: { [self] in
                    let refused = updateSheet || otherSheet || stuckModal
                    events.append(refused ? "terminate refused" : "terminate")
                    if !refused { alive = false }
                },
                isAlive: { [self] in
                    aliveChecks += 1
                    return alive
                },
                endSheetsAndModals: { [self] in
                    events.append("end sheets and modals")
                    updateSheet = false
                    otherSheet = false
                },
                exit: { [self] in
                    events.append("exit")
                    alive = false
                },
                log: { [self] in logs.append($0) })
        }
    }

    static let fast = UpdateQuit.Timing(sheetTimeout: .milliseconds(300), grace: .milliseconds(150), poll: .milliseconds(5))

    @Test func dismissesTheSheetAndTerminatesOnceItIsGone() async {
        let app = FakeApp()
        let outcome = await UpdateQuit.run(app.steps, timing: Self.fast)
        #expect(outcome == .terminated(attempt: 1))
        // Terminating with the sheet still attached is what left 0.0.1–0.0.3 running.
        #expect(app.events == ["dismiss", "terminate"])
        #expect(app.logs.isEmpty)
    }

    @Test func endsOtherSheetsAndTerminatesAgainWhenStillAlive() async {
        let app = FakeApp()
        app.otherSheet = true
        let outcome = await UpdateQuit.run(app.steps, timing: Self.fast)
        #expect(outcome == .terminated(attempt: 2))
        #expect(app.events == ["dismiss", "terminate refused", "end sheets and modals", "terminate"])
        #expect(app.logs.count == 2)
    }

    @Test func exitsWhenTerminatingNeverWorks() async {
        let app = FakeApp()
        app.stuckModal = true
        let outcome = await UpdateQuit.run(app.steps, timing: Self.fast)
        #expect(outcome == .exited)
        #expect(app.events == ["dismiss", "terminate refused", "end sheets and modals", "terminate refused", "exit"])
        #expect(!app.alive)
    }

    @Test func aSheetThatNeverDetachesDoesNotHoldTheQuitUp() async {
        let app = FakeApp()
        app.detachPolls = .max
        let start = ContinuousClock.now
        let outcome = await UpdateQuit.run(app.steps, timing: Self.fast)
        #expect(outcome == .terminated(attempt: 2))
        #expect(app.events == ["dismiss", "terminate refused", "end sheets and modals", "terminate"])
        // sheet timeout + grace, then the escalation: bounded, never waiting for the sheet forever.
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func keepsPollingCalmlyWhenTheStartingTaskIsCancelled() async {
        let app = FakeApp()
        app.stuckModal = true
        let task = Task { await UpdateQuit.run(app.steps, timing: Self.fast) }
        task.cancel()
        #expect(await task.value == .exited)
        // Two graces of 150 ms polled every 5 ms: about 60 checks. A pause that ended early on
        // cancellation would spin through thousands.
        #expect(app.aliveChecks < 200)
    }
}
