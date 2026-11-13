import Foundation

/// One prompt's delivery into a tmux pane once it holds the pane's turn
/// (T15, design §4.3 Input). The draft goes in on one control line with its
/// Enter, or, for a kind whose TUI drops an Enter that arrives with the
/// paste (`AgentScreen.InputReadiness.submitDelay`), without it: a raw CR
/// follows on a line of its own after the gap, and only while the one read
/// before it shows the draft still waiting in the Agent's input and nothing
/// reads Blocked (a hook's status from that read, the status last reported,
/// the kind's screen rules). A skipped CR leaves the draft typed,
/// unsubmitted.
///
/// Whoever holds the turn hands it on exactly once: the caller until its
/// line is answered, then, for a delayed Enter, the Enter itself, which
/// runs where the caller's cancellation never reaches. Nothing is retried
/// (ADR 0018).
struct TmuxPromptDeliveryMachine: StateMachine {
    enum State: Equatable, Sendable {
        /// The caller holds the turn: the gates, then the draft's line.
        case delivering
        /// The draft is in without its Enter; the delayed Enter holds the
        /// turn and waits out the gap, then reads the pane.
        case awaitingEnter
        /// The read showed the draft waiting: the CR is out.
        case entering
        /// The turn is handed on.
        case ended(Outcome)
    }

    enum Outcome: Equatable, Sendable {
        case submitted
        /// The draft is in the Agent's input, its Enter skipped.
        case typedUnsubmitted
        case failed
    }

    /// What the one read before a delayed CR saw.
    struct EnterRead: Equatable, Sendable {
        /// The pane's `@waycar_status`, read on that line.
        let hookStatus: AgentStatus?
        /// The status last reported for the pane.
        let reportedStatus: AgentStatus?
        /// The kind's screen rules' verdict on the screen read.
        let screenStatus: AgentStatus?
        /// Whether the screen still shows the draft in the Agent's input,
        /// with no approval dialog (`AgentScreen.draftAwaitsEnter`).
        let draftAwaitsEnter: Bool

        var allowsEnter: Bool {
            hookStatus != .blocked && reportedStatus != .blocked && screenStatus != .blocked
                && draftAwaitsEnter
        }
    }

    enum Event: Equatable, Sendable {
        /// The draft's line was answered; `entersAfterGap` when it carried
        /// no Enter (``entersAfterGap(hasDraft:submitDelay:)``).
        case typed(entersAfterGap: Bool)
        case read(EnterRead)
        /// The CR's line was answered.
        case entered
        /// A gate refused the prompt, or a line or read failed.
        case failed
    }

    enum Effect: Equatable, Sendable {
        /// Wait out the gap, then read the pane: the delayed Enter holds
        /// the turn from here.
        case awaitEnter
        /// Send the raw CR on its own line.
        case sendEnter
        /// Hand the pane's turn to the next prompt.
        case releaseTurn
        /// Fail the prompt `prompt_not_submitted`: the draft stays typed.
        case refuseUnsubmitted
    }

    private(set) var state: State = .delivering

    init() {}

    /// Whether the draft's line goes without its Enter: a draft to a kind
    /// with a submit delay. An empty prompt is Enter alone, at once.
    static func entersAfterGap(hasDraft: Bool, submitDelay: Duration) -> Bool {
        hasDraft && submitDelay > .zero
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.delivering, .typed(let entersAfterGap)):
            guard entersAfterGap else {
                state = .ended(.submitted)
                return [.releaseTurn]
            }
            state = .awaitingEnter
            return [.awaitEnter]
        case (.delivering, .failed):
            state = .ended(.failed)
            return [.releaseTurn]
        case (.delivering, .read), (.delivering, .entered):
            return []

        case (.awaitingEnter, .read(let read)):
            guard read.allowsEnter else {
                state = .ended(.typedUnsubmitted)
                return [.releaseTurn, .refuseUnsubmitted]
            }
            state = .entering
            return [.sendEnter]
        case (.awaitingEnter, .failed):
            state = .ended(.failed)
            return [.releaseTurn]
        case (.awaitingEnter, .typed), (.awaitingEnter, .entered):
            return []

        case (.entering, .entered):
            state = .ended(.submitted)
            return [.releaseTurn]
        case (.entering, .failed):
            state = .ended(.failed)
            return [.releaseTurn]
        case (.entering, .typed), (.entering, .read):
            return []

        case (.ended, _):
            return []
        }
    }
}
