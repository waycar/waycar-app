import Foundation
import Observation

/// Owns the Console's navigation path and lands Agent Notification taps on
/// the right Agent detail (#74, #179). A tap can arrive before the tapped
/// pane is known — a killed-state launch routes only once the Host's first sync
/// delivers the pane — so an unresolved target waits as pending until the
/// pane appears, the user navigates somewhere themselves, or a grace window
/// elapses. Falling back always means the Console, quietly: never an alert.
@MainActor
@Observable
final class AgentNotificationRouter {
    /// The Console's NavigationStack path; ConsoleView binds to it, so user
    /// navigation and deep links share one source of truth. Any navigation
    /// other than `retarget`'s own ends the re-key marker, and opening an
    /// Agent drops a tap still waiting for its pane: coming back to the
    /// Console later must not let that tap take the user away.
    var path: [ConsoleAgent.ID] = [] {
        didSet {
            if path.last != lastRetarget?.to { lastRetarget = nil }
            if !path.isEmpty { send(.navigated) }
        }
    }

    /// A tap still waiting for its pane to appear in the Console.
    var pendingTarget: AgentNotificationTarget? { route.pendingTarget }

    /// The tap's way to its Agent; see `NotificationRouteMachine`.
    private var route = NotificationRouteMachine()

    /// Whether the Console's latest Agent list has this row, as last fed
    /// through `agentsDidChange`.
    func isKnownAgent(_ id: ConsoleAgent.ID) -> Bool {
        knownAgentIDs.contains(id)
    }

    /// The terminal backend of a row in the latest Agent list; herdr for any other.
    /// A Codex thread's linked pane supplies its terminal-window ownership.
    /// Terminal ownership is Host-keyed for herdr rows only (ADR 0026):
    /// tmux and herdr-core rows never contend for it.
    func backend(of id: ConsoleAgent.ID) -> HostBackend {
        terminalBackendsByAgentID[id] ?? .herdr
    }

    /// The open Agent's pane was re-keyed (a move): the same Agent screen
    /// now goes by `new`. The path follows it without that counting as the
    /// user leaving one Agent and opening another; see `isRetarget`.
    func retarget(from old: ConsoleAgent.ID, to new: ConsoleAgent.ID) {
        guard path.last == old, old != new else { return }
        lastRetarget = Retarget(from: old, to: new)
        path = [new]
    }

    /// Whether the path's change from `old` to `new` was `retarget`'s.
    func isRetarget(from old: ConsoleAgent.ID?, to new: ConsoleAgent.ID?) -> Bool {
        guard let old, let new else { return false }
        return lastRetarget == Retarget(from: old, to: new)
    }

    private struct Retarget: Equatable {
        let from: ConsoleAgent.ID
        let to: ConsoleAgent.ID
    }

    /// The re-key the path is on right now; any other navigation clears it,
    /// since herdr reuses pane ids and an old pair can recur.
    @ObservationIgnored private var lastRetarget: Retarget?

    /// When a notification, Live Activity, or link tap last asked this
    /// window to show something (`open`), whether or not the path changed.
    /// The Notification Ask never comes up over what the user just opened
    /// (`AgentSessionClock.stillHolds`).
    @ObservationIgnored private(set) var lastRouteRequest: ContinuousClock.Instant?
    @ObservationIgnored private var knownAgentIDs: Set<ConsoleAgent.ID> = []
    @ObservationIgnored private var terminalBackendsByAgentID: [ConsoleAgent.ID: HostBackend] = [:]
    @ObservationIgnored private var graceTimer: Task<Void, Never>?
    @ObservationIgnored private let pendingGrace: Duration

    /// `pendingGrace` bounds how long a tap may wait for its pane: long
    /// enough for a cold launch to connect and sync its Hosts, short enough
    /// that a stale pane cannot yank the user around minutes later.
    init(pendingGrace: Duration = .seconds(15)) {
        self.pendingGrace = pendingGrace
    }

    /// Routes a tapped notification. A known pane opens its detail at once;
    /// an unknown one parks the user on the Console and follows up if the
    /// pane arrives within the grace window (killed-state launches); no
    /// target at all (unknown key id, undecryptable envelope) is the Console
    /// itself, with no alarming copy.
    func open(_ target: AgentNotificationTarget?) {
        lastRouteRequest = .now
        send(.tapped(target, paneIsKnown: target.map { knownAgentIDs.contains($0.agentID) } ?? false))
    }

    /// The Console feed: resolves a pending tap the moment its pane appears.
    /// If the user has navigated somewhere else in the meantime, the deep
    /// link is dropped instead of yanking them away.
    func agentsDidChange(_ agents: [ConsoleAgent]) {
        knownAgentIDs = Set(agents.map(\.id))
        terminalBackendsByAgentID = Dictionary(
            agents.map { ($0.id, $0.linkedTerminal?.backend ?? $0.backend) },
            uniquingKeysWith: { first, _ in first })
        send(.agentsChanged(knownAgentIDs))
    }

    private func send(_ event: NotificationRouteMachine.Event) {
        for effect in route.handle(event) {
            switch effect {
            case .showConsole:
                path = []
            case .showAgent(let id):
                path = [id]
            case .armGrace(let token):
                let grace = pendingGrace
                graceTimer = Task { [weak self] in
                    try? await Task.sleep(for: grace)
                    guard !Task.isCancelled else { return }
                    self?.graceTimer = nil
                    self?.send(.graceElapsed(token))
                }
            case .cancelGrace:
                graceTimer?.cancel()
                graceTimer = nil
            }
        }
    }
}

/// A notification tap on its way to an Agent detail (#74, #179). A tap for a
/// pane the Console knows opens it at once. A tap for one it does not know
/// yet (a killed-state launch, before the Host's first sync) shows the
/// Console and waits for that pane, until the pane appears, the user opens
/// an Agent themselves, or the grace window ends. An unresolvable tap is
/// just the Console.
///
/// While a tap waits the path is empty: the tap shows the Console, and any
/// navigation to an Agent ends the wait.
struct NotificationRouteMachine: StateMachine {
    enum State: Equatable, Sendable {
        /// No tap is waiting; the path is the user's.
        case idle
        /// A tap whose pane is not in the Console yet, until the grace timer
        /// armed with `grace` ends it.
        case waiting(AgentNotificationTarget, grace: UInt64)
    }

    enum Event: Equatable, Sendable {
        /// A tap: its target (nil when unresolvable) and whether the Console
        /// knows its pane now.
        case tapped(AgentNotificationTarget?, paneIsKnown: Bool)
        /// The Console's Agent list now has these rows.
        case agentsChanged(Set<ConsoleAgent.ID>)
        /// The path moved to an Agent, by the user or a restored route.
        case navigated
        /// The grace timer armed with this token ran out.
        case graceElapsed(UInt64)
    }

    enum Effect: Equatable, Sendable {
        /// Show the Console: an empty path.
        case showConsole
        /// Show this Agent's detail.
        case showAgent(ConsoleAgent.ID)
        /// Arm the grace timer; it comes back as `graceElapsed` with this token.
        case armGrace(UInt64)
        /// Disarm the grace timer.
        case cancelGrace
    }

    private(set) var state: State = .idle
    private var lastToken: UInt64 = 0

    /// The tap still waiting for its pane.
    var pendingTarget: AgentNotificationTarget? {
        if case .waiting(let target, _) = state { target } else { nil }
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (_, .tapped(let target, let paneIsKnown)):
            // A new tap replaces a waiting one.
            let disarm: [Effect] = pendingTarget == nil ? [] : [.cancelGrace]
            guard let target else {
                state = .idle
                return disarm + [.showConsole]
            }
            if paneIsKnown {
                state = .idle
                return disarm + [.showAgent(target.agentID)]
            }
            lastToken += 1
            state = .waiting(target, grace: lastToken)
            return disarm + [.showConsole, .armGrace(lastToken)]
        case (.waiting(let target, _), .agentsChanged(let known)):
            guard known.contains(target.agentID) else { return [] }
            state = .idle
            return [.cancelGrace, .showAgent(target.agentID)]
        case (.waiting, .navigated):
            state = .idle
            return [.cancelGrace]
        case (.waiting(_, let grace), .graceElapsed(let token)) where token == grace:
            // Stale pane: it never showed up. Stay on the Console quietly.
            state = .idle
            return []
        case (.waiting, .graceElapsed), (.idle, _):
            return []
        }
    }
}
