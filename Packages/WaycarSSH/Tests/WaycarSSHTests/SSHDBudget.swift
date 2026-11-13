import Foundation

extension Duration {
    /// A real-sshd operation budget of `seconds`, stretched by
    /// `WAYCAR_SSH_E2E_TIMEOUT_SCALE` when the fixture runs on a loaded host.
    ///
    /// The literals are what an idle machine needs. CI can share its
    /// runner with the developer's own workload, and at load averages in the
    /// hundreds sshd has been seen taking 5-9 s just to fork and reap
    /// `sh -c 'exit 7'`, so a fixed 5 s budget measured the host rather than
    /// the code under test. Tests that expect `.timedOut` pass sub-second or
    /// injected deadlines and stay unscaled.
    static func sshdBudget(_ seconds: Int) -> Duration {
        .seconds(seconds) * sshdBudgetScale
    }
}

private let sshdBudgetScale: Double = {
    guard
        let text = ProcessInfo.processInfo.environment["WAYCAR_SSH_E2E_TIMEOUT_SCALE"],
        let scale = Double(text), scale >= 1
    else { return 1 }
    return scale
}()
