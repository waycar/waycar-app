/// One Queued Launch's lifecycle (CONTEXT.md **Queued Launch**), first
/// message handover included: it waits for its Host, its replay starts it,
/// and its messages move to the Agent that started, each once, in order,
/// across restarts.
///
/// Its state is the record's own fields (`QueuedLaunch.lifecycle`), so the
/// on-disk format is the one older builds wrote. Two facts outlive a try
/// whatever the phase, and ride every state as its `Recovery`:
///
/// - **The started Agent** (`startedPaneID`, `joinedRunningAgent`), recorded
///   before any post-start await can accept a Send on the real pane. Its
///   presence means a handover is outstanding: restore and every later
///   replay finish it, never start the Agent again. A persisted Starting can
///   already carry it. The handover itself is one synchronous step
///   (`ConsoleStore.handOverPendingMessages`); when it cannot finish, the
///   moved prefix of the messages belongs to the real pane, the rest stays
///   pending, and the real pane holds its queue until a later handover
///   finishes or Delete removes both halves. A joined Agent's messages wait
///   for Send Anyway.
/// - **May have started**: an earlier try may have reached the Host, so the
///   next one checks the Launch Tag before starting anything missing.
struct QueuedLaunchMachine: StateMachine {
    struct StartedAgent: Equatable, Sendable {
        let paneID: String
        /// An adopted checkout already had an Agent: its messages are held
        /// for Send Anyway.
        let joinedRunningAgent: Bool?
    }

    struct Recovery: Equatable, Sendable {
        var startedAgent: StartedAgent?
        var mayHaveStarted: Bool?
    }

    enum State: Equatable, Sendable {
        /// Waiting for its Host's verified connection.
        case waiting(Recovery)
        /// Its replay is under way, saved before anything goes to the Host.
        case starting(Recovery)
        /// Its replay failed after it may have reached the Host, or its
        /// messages could not be kept or moved; only the user retries or
        /// deletes it. The message is user-facing.
        case failed(String, Recovery)
        /// Legacy records only, until restored.
        case uncertain(Recovery)
    }

    enum Event: Equatable, Sendable {
        /// Read from the device when the app starts.
        case restored
        /// Its messages could not be kept on the device, or a recorded
        /// handover could not finish during a replay.
        case messagesNotKept
        case retry
        /// The replay is about to send its start.
        case dispatching
        /// The replay's start reported its Agent, before its answer.
        case agentStarted(paneID: String, joinedRunningAgent: Bool)
        /// The replay's answer: its Agent started.
        case started(paneID: String, joinedRunningAgent: Bool?)
        case handoverFailed
        /// Nothing reached the Host.
        case notSent
        /// The answer was lost after the start may have reached the Host.
        case answerLost
        case refused(String)
    }

    enum Effect: Equatable, Sendable {
        /// Write the record; saves that must land before the next step stop
        /// the owner when they fail.
        case save
        /// Hold the real pane's queue behind the launch's messages.
        case holdRecipient(paneID: String)
        /// Move the pending messages to the started pane, then remove the
        /// launch.
        case handOver(paneID: String)
        /// Let the Host's drain replay it.
        case drain
    }

    static let messagesNotKeptMessage =
        "Waycar couldn't keep this launch's messages. Retry to try again."
    static let handoverFailedMessage =
        "The Agent started, but its messages couldn't be moved. Retry to finish sending them."

    private(set) var state: State

    init(state: State) {
        self.state = state
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.starting(var recovery), .restored), (.uncertain(var recovery), .restored):
            // The app ended mid-replay: it may have launched.
            recovery.mayHaveStarted = true
            state = .waiting(recovery)
            return [.save]
        case (.waiting, .restored), (.failed, .restored):
            return []
        case (_, .messagesNotKept):
            state = .failed(Self.messagesNotKeptMessage, state.recovery)
            return [.save]
        case (.failed(_, let recovery), .retry):
            state = .waiting(recovery)
            return [.save, .drain]
        case (.waiting, .retry), (.starting, .retry), (.uncertain, .retry):
            return []
        case (.waiting(let recovery), .dispatching):
            state = .starting(recovery)
            return [.save]
        case (.starting, .dispatching), (.failed, .dispatching), (.uncertain, .dispatching):
            return []
        case (_, .agentStarted(let paneID, let joined)):
            state = state.with(StartedAgent(paneID: paneID, joinedRunningAgent: joined))
            return [.save, .holdRecipient(paneID: paneID)]
        case (.starting, .started(let paneID, let joined)):
            state = state.with(StartedAgent(paneID: paneID, joinedRunningAgent: joined))
            return [.save, .handOver(paneID: paneID)]
        case (.starting(let recovery), .handoverFailed):
            state = .failed(Self.handoverFailedMessage, recovery)
            return [.save]
        case (.starting(let recovery), .notSent):
            state = .waiting(recovery)
            return [.save]
        case (.starting(var recovery), .answerLost):
            recovery.mayHaveStarted = true
            state = .waiting(recovery)
            return [.save]
        case (.starting(let recovery), .refused(let message)):
            state = .failed(message, recovery)
            return [.save]
        case (.waiting, .started), (.failed, .started), (.uncertain, .started),
            (.waiting, .handoverFailed), (.failed, .handoverFailed), (.uncertain, .handoverFailed),
            (.waiting, .notSent), (.failed, .notSent), (.uncertain, .notSent),
            (.waiting, .answerLost), (.failed, .answerLost), (.uncertain, .answerLost),
            (.waiting, .refused), (.failed, .refused), (.uncertain, .refused):
            return []
        }
    }
}

extension QueuedLaunchMachine.State {
    var recovery: QueuedLaunchMachine.Recovery {
        switch self {
        case .waiting(let recovery), .starting(let recovery), .failed(_, let recovery),
            .uncertain(let recovery):
            recovery
        }
    }

    /// The Agent a try started whose messages still move to it.
    var pendingHandover: QueuedLaunchMachine.StartedAgent? { recovery.startedAgent }

    /// Waiting for its Host: the drain replays it.
    var awaitsReplay: Bool {
        if case .waiting = self { return true }
        return false
    }

    /// Its replay is under way: past deleting, and its pending Composer
    /// takes no Send.
    var isStarting: Bool {
        if case .starting = self { return true }
        return false
    }

    /// After a replay: whether the Host's next launch may go. Not once
    /// nothing reached the Host or its link failed.
    var letsNextReplayGo: Bool {
        switch self {
        case .waiting, .uncertain: false
        case .starting, .failed: true
        }
    }

    fileprivate func with(_ agent: QueuedLaunchMachine.StartedAgent) -> Self {
        var updated = self.recovery
        updated.startedAgent = agent
        return switch self {
        case .waiting: .waiting(updated)
        case .starting: .starting(updated)
        case .failed(let message, _): .failed(message, updated)
        case .uncertain: .uncertain(updated)
        }
    }
}

extension QueuedLaunch {
    /// The record's lifecycle fields as the machine's state, and back. A
    /// record without a started pane keeps whatever `joinedRunningAgent`
    /// it had, so every record maps back exactly.
    var lifecycle: QueuedLaunchMachine.State {
        get {
            let recovery = QueuedLaunchMachine.Recovery(
                startedAgent: startedPaneID.map {
                    .init(paneID: $0, joinedRunningAgent: joinedRunningAgent)
                },
                mayHaveStarted: mayHaveStarted)
            return switch state {
            case .waiting: .waiting(recovery)
            case .starting: .starting(recovery)
            case .uncertain: .uncertain(recovery)
            case .failed(let message): .failed(message, recovery)
            }
        }
        set {
            switch newValue {
            case .waiting: state = .waiting
            case .starting: state = .starting
            case .uncertain: state = .uncertain
            case .failed(let message, _): state = .failed(message)
            }
            let recovery = newValue.recovery
            if let agent = recovery.startedAgent {
                startedPaneID = agent.paneID
                joinedRunningAgent = agent.joinedRunningAgent
            } else {
                startedPaneID = nil
            }
            mayHaveStarted = recovery.mayHaveStarted
        }
    }

    /// Feeds the launch's machine one event.
    mutating func handle(_ event: QueuedLaunchMachine.Event) -> [QueuedLaunchMachine.Effect] {
        var machine = QueuedLaunchMachine(state: lifecycle)
        let effects = machine.handle(event)
        lifecycle = machine.state
        return effects
    }
}
