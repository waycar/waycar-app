import Foundation

/// The Console's swiped Closes: each counts down its undo window, then
/// closes its row's tab. One tab gets one `tab.close`: a countdown that runs
/// out while a sibling on the same tab is closing rides along, and a Close
/// that succeeds stops every sibling still counting on its tab. Tabs are the
/// rows' tabs now (`liveTabs`, from the listed rows), since herdr can move
/// a pane mid-countdown. A failed Close releases its row and every rider on
/// its tab. A sent Close stays `closing` until its row leaves the list.
///
/// A countdown is its own: it keeps the Agent it was swiped with, and runs
/// out whether or not its row still shows a Close (a failure releases by
/// row, so an older Close in flight can clear a newer one's). The owner
/// holds one countdown Task per row, the latest swiped; only that one can be
/// undone or stopped, and any countdown running out drops it.
///
/// A swiped Close is a user-requested Close: its `tab.close` may close the
/// Workspace's worktree group (`WaycarSSHTransport.closeTab`).
struct PendingTabCloseMachine: StateMachine {
    typealias ID = ConsoleAgent.ID
    typealias Close = ConsoleStore.PendingTabClose

    struct State: Equatable, Sendable {
        /// Every swiped Close, as the Console renders it.
        var closes: [ID: Close] = [:]
        /// Every countdown still running, by token, with the Agent it was
        /// swiped with.
        var countdowns: [UInt64: ConsoleAgent] = [:]
        /// The countdown whose Task the owner holds for each row.
        var held: [ID: UInt64] = [:]
    }

    enum Event: Equatable, Sendable {
        case schedule(ConsoleAgent, deadline: Date)
        /// `liveTabs`: the tab each listed row is on now.
        case countdownEnded(token: UInt64, liveTabs: [ID: String])
        case closed(ConsoleAgent, tabID: String, liveTabs: [ID: String])
        case closeFailed(ConsoleAgent, tabID: String, liveTabs: [ID: String])
        case undo(ID)
        /// These Closes' rows left the list.
        case rowsGone([ID])
    }

    enum Effect: Equatable, Sendable {
        /// Start the row's countdown Task, replacing (not cancelling) any
        /// Task held for it.
        case startCountdown(ConsoleAgent, token: UInt64)
        case cancelCountdown(ID)
        /// Drop the row's held countdown Task without cancelling it.
        case dropCountdown(ID)
        /// Send `tab.close` for the countdown that just ran out.
        case close(tabID: String)
    }

    private(set) var state = State()
    private var lastToken: UInt64 = 0

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .schedule(let agent, let deadline):
            guard state.closes[agent.id] == nil else { return [] }
            lastToken &+= 1
            state.closes[agent.id] = Close(agent: agent, deadline: deadline, phase: .counting)
            state.countdowns[lastToken] = agent
            state.held[agent.id] = lastToken
            return [.startCountdown(agent, token: lastToken)]
        case .countdownEnded(let token, let liveTabs):
            guard let agent = state.countdowns.removeValue(forKey: token) else { return [] }
            state.held[agent.id] = nil
            state.closes[agent.id]?.phase = .closing
            let tabID = liveTab(of: agent, in: liveTabs)
            // A sibling's close already covers this tab: stay `closing`
            // until the resync drops the row (or that close fails).
            guard others(of: agent, tabID: tabID, in: .closing, liveTabs: liveTabs).isEmpty else {
                return [.dropCountdown(agent.id)]
            }
            return [.dropCountdown(agent.id), .close(tabID: tabID)]
        case .closed(let agent, let tabID, let liveTabs):
            // Siblings on the closed tab went with it: stop their own
            // countdowns so none sends a doomed `tab.close`.
            var effects: [Effect] = []
            for sibling in others(of: agent, tabID: tabID, in: .counting, liveTabs: liveTabs) {
                effects += stopCountdown(of: sibling)
                state.closes[sibling]?.phase = .closing
            }
            return effects
        case .closeFailed(let agent, let tabID, let liveTabs):
            // Every rider goes back to a plain card with it: nothing else
            // would ever take them out of `closing`.
            state.closes[agent.id] = nil
            for rider in others(of: agent, tabID: tabID, in: .closing, liveTabs: liveTabs) {
                state.closes[rider] = nil
            }
            return []
        case .undo(let id):
            // Once `tab.close` is in flight there is nothing left to undo.
            guard state.held[id] != nil else { return [] }
            state.closes[id] = nil
            return stopCountdown(of: id)
        case .rowsGone(let gone):
            var effects: [Effect] = []
            for id in gone {
                effects += stopCountdown(of: id)
                state.closes[id] = nil
            }
            return effects
        }
    }

    /// Cancels the countdown held for `id`, if any.
    private mutating func stopCountdown(of id: ID) -> [Effect] {
        guard let token = state.held.removeValue(forKey: id) else { return [] }
        state.countdowns[token] = nil
        return [.cancelCountdown(id)]
    }

    private func liveTab(of agent: ConsoleAgent, in liveTabs: [ID: String]) -> String {
        liveTabs[agent.id] ?? agent.agent.tabID
    }

    /// Other Closes in `phase` on `agent`'s Host and `tabID`.
    private func others(
        of agent: ConsoleAgent, tabID: String, in phase: Close.Phase, liveTabs: [ID: String]
    ) -> [ID] {
        state.closes.values
            .filter {
                $0.agent.id != agent.id && $0.phase == phase
                    && $0.agent.hostID == agent.hostID && liveTab(of: $0.agent, in: liveTabs) == tabID
            }
            .map(\.agent.id)
    }
}
