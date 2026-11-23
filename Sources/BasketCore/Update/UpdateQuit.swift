import Foundation

/// Quits Basket once the swap helper runs (docs/updates.md, "Quitting to install"). The helper
/// waits for this process to exit and gives up after 2 minutes, so Basket must never stay alive
/// with it armed — but AppKit refuses to terminate while a window has a sheet attached ("App
/// termination blocked by modal sheet") or a modal session runs. So, in order:
/// 1. close the update sheet and wait (up to `sheetTimeout`) until no window has a sheet;
/// 2. terminate; if Basket still runs `grace` later, end every sheet and modal session, wait for
///    the sheets to go and terminate once more;
/// 3. if it still runs another `grace` later, run the quit cleanup and exit.
/// The steps are injected so the order can be tested without AppKit (`UpdateController` wires
/// them to NSApp).
@MainActor
public enum UpdateQuit {
    public struct Steps {
        /// Drives the update sheet's presentation state to nil.
        public var dismissUpdateSheet: () -> Void
        /// Whether any window still has a sheet attached.
        public var hasAttachedSheet: () -> Bool
        /// Asks the app to terminate. Must not block: a modal session it starts would stall the
        /// sequence (the app defers `NSApp.terminate` to the next turn of the main queue).
        public var terminate: () -> Void
        /// Whether the app still runs. In the app this is always true — once it terminates, no
        /// code runs any more.
        public var isAlive: () -> Bool
        /// Ends every attached sheet and aborts a running modal session.
        public var endSheetsAndModals: () -> Void
        /// The quit cleanup, then `exit(0)`.
        public var exit: () -> Void
        public var log: (String) -> Void

        public init(dismissUpdateSheet: @escaping () -> Void, hasAttachedSheet: @escaping () -> Bool,
                    terminate: @escaping () -> Void, isAlive: @escaping () -> Bool,
                    endSheetsAndModals: @escaping () -> Void, exit: @escaping () -> Void,
                    log: @escaping (String) -> Void) {
            self.dismissUpdateSheet = dismissUpdateSheet
            self.hasAttachedSheet = hasAttachedSheet
            self.terminate = terminate
            self.isAlive = isAlive
            self.endSheetsAndModals = endSheetsAndModals
            self.exit = exit
            self.log = log
        }
    }

    public struct Timing: Sendable {
        /// How long a closing sheet may take to detach (its animation is a fraction of this).
        public var sheetTimeout: Duration
        /// How long the app may take to quit after `terminate` before the next step.
        public var grace: Duration
        public var poll: Duration

        public init(sheetTimeout: Duration = .seconds(2), grace: Duration = .milliseconds(2500),
                    poll: Duration = .milliseconds(50)) {
            self.sheetTimeout = sheetTimeout
            self.grace = grace
            self.poll = poll
        }
    }

    public enum Outcome: Equatable, Sendable {
        /// The app quit after the first (1) or the second, escalated (2) `terminate`.
        case terminated(attempt: Int)
        /// Neither `terminate` worked: the app cleaned up and exited.
        case exited
    }

    @discardableResult
    public static func run(_ steps: Steps, timing: Timing = Timing()) async -> Outcome {
        steps.dismissUpdateSheet()
        if await !waitUntil(timing.sheetTimeout, poll: timing.poll, { !steps.hasAttachedSheet() }) {
            steps.log("a sheet is still attached after \(seconds(timing.sheetTimeout)) s; terminating anyway")
        }
        for attempt in 1...2 {
            steps.terminate()
            if await waitUntil(timing.grace, poll: timing.poll, { !steps.isAlive() }) {
                return .terminated(attempt: attempt)
            }
            guard attempt == 1 else { break }
            steps.log("still running \(seconds(timing.grace)) s after terminating; ending sheets and modal sessions, then terminating again")
            steps.endSheetsAndModals()
            _ = await waitUntil(timing.sheetTimeout, poll: timing.poll) { !steps.hasAttachedSheet() }
        }
        steps.log("still running \(seconds(timing.grace)) s after terminating again; exiting so the update can install")
        steps.exit()
        return .exited
    }

    /// Polls until `condition` holds (true) or `timeout` passed (false). The pauses don't end
    /// early when the task is cancelled, so the sequence keeps its timing whatever happens to the
    /// task that started it.
    static func waitUntil(_ timeout: Duration, poll: Duration, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while true {
            if condition() { return true }
            if ContinuousClock.now >= deadline { return false }
            await pause(poll)
        }
    }

    /// Resumes from the main queue, which also runs during modal sessions (common run-loop modes).
    private static func pause(_ duration: Duration) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds(duration)) { continuation.resume() }
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        let (whole, fraction) = duration.components
        return Double(whole) + Double(fraction) / 1e18
    }
}
