import Foundation

// MARK: - Agent Progress on the watch

extension WatchProgress {
    /// The estimate as the iPhone's Console reads it; nil while pending.
    /// Invalid steps and unknown phases degrade like
    /// `AgentProgress.init?(steps:phase:)`, so this is nil exactly when
    /// `isPending`.
    var estimate: AgentProgress? {
        let steps = done.flatMap { done in total.map { AgentProgress.Steps(done: done, total: $0) } }
        return AgentProgress(steps: steps, phase: phase.flatMap(AgentProgress.Phase.init(rawValue:)))
    }
}

extension WatchAgentRow {
    /// What the row's progress bar shows at `now` (#199): only Working and
    /// Blocked Agents draw one; Blocked is the frozen last estimate and is
    /// never pending. Nil draws nothing, as for Done and Idle.
    func progressDisplay(at now: Date) -> AgentProgressDisplay? {
        guard let progress, status == "working" || status == "blocked" else { return nil }
        guard let estimate = progress.estimate else {
            return status == "working" ? .pending : nil
        }
        return .estimate(estimate, isStale: progress.isStale(at: now))
    }
}

extension AgentProgressDisplay {
    /// The status line's progress segment ("3/7", "Verifying"); nil while
    /// pending.
    var watchLabel: String? {
        guard case .estimate(let estimate, _) = self else { return nil }
        return estimate.label
    }

    /// What VoiceOver reads on the watch: "3 of 7 steps done", with
    /// ", out of date" once stale; nil while pending. Never a percent.
    var watchSpokenLabel: String? {
        guard case .estimate(let estimate, let isStale) = self else { return nil }
        return isStale ? "\(estimate.spokenLabel), out of date" : estimate.spokenLabel
    }
}
