import Foundation

/// Open Terminal from an Agent detail (ATTACH-21, `AgentDetailView`): pick a
/// Workspace shell, or create one and wait for its row, then open it with
/// the shell keyboard handoff this opening captured.
///
/// - The handoff token is the one `TerminalKeyboardHandoff` held when Open
///   Terminal was tapped; every outcome consumes or cancels exactly that
///   token, so a newer opening's handoff survives an older one finishing.
/// - One creation runs at a time; a tap meanwhile only gives its own token
///   back. A created terminal is remembered, so a later Open Terminal
///   refreshes the inventory for it instead of creating a duplicate.
/// - The attempt is a single Task whose steps (create or refresh, then wait
///   for the row) the machine hands out one at a time; it is resolving until
///   that Task has run every effect of its last step.
struct ShellOpeningMachine: StateMachine {
    /// One await of a creation attempt, performed by the owner's Task.
    enum Step: Equatable, Sendable {
        case create(attempt: UInt64, ShellTerminalCreationRequest)
        case refresh(attempt: UInt64)
        case awaitRow(attempt: UInt64, ConsoleAgent.ID)
    }

    struct CreatedTerminal: Equatable, Sendable {
        let identity: ShellTerminalIdentity
        let row: ConsoleAgent.ID
    }

    enum Attempt: Equatable, Sendable {
        case idle
        case resolving(attempt: UInt64, handoffToken: UUID?)
    }

    struct State: Equatable, Sendable {
        var handoffToken: UUID?
        var created: CreatedTerminal?
        var attempt = Attempt.idle
    }

    enum Event: Equatable, Sendable {
        /// Open Terminal: the handoff token it captured, the Workspace's other
        /// shell rows, the request a New Terminal would send, and whether a
        /// Sample connects instead.
        case openTapped(
            handoffToken: UUID?, shells: [ConsoleAgent.ID],
            request: ShellTerminalCreationRequest?, runsSample: Bool)
        case shellChosen(ConsoleAgent.ID)
        case chooserCancelled
        /// New Terminal from the chooser.
        case createRequested(request: ShellTerminalCreationRequest?, runsSample: Bool)
        case created(attempt: UInt64, ShellTerminalIdentity, row: ConsoleAgent.ID)
        case creationFailed(attempt: UInt64, message: String)
        case refreshed(attempt: UInt64)
        /// `visible` is read only when the row was found.
        case rowAwaited(attempt: UInt64, found: Bool, visible: Bool)
        case attemptFinished(attempt: UInt64)
    }

    enum Effect: Equatable, Sendable {
        case presentChooser
        /// Re-arm the shell handoff for `row` in its mode, then switch to it.
        case openShell(ConsoleAgent.ID, handoffToken: UUID?)
        case cancelShellHandoff(UUID?)
        case connectSample
        /// Start the attempt's Task with its first step.
        case startAttempt(attempt: UInt64, Step)
        /// The attempt's Task goes on with this step.
        case continueAttempt(Step)
        case presentFailure(String)
    }

    static let rowNotRefreshedMessage =
        "The terminal was created, but its Workspace hasn't refreshed yet. Try Open Terminal again to refresh it."

    private(set) var state = State()
    private var lastToken: UInt64 = 0

    init() {}

    var isResolving: Bool { state.attempt != .idle }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .openTapped(let token, let shells, let request, let runsSample):
            state.handoffToken = token
            if state.created != nil { return requestCreation(request, runsSample: runsSample) }
            switch shells.count {
            case 0: return requestCreation(request, runsSample: runsSample)
            case 1: return [.openShell(shells[0], handoffToken: token)]
            default: return [.presentChooser]
            }

        case .shellChosen(let row):
            return [.openShell(row, handoffToken: state.handoffToken)]

        case .chooserCancelled:
            return [.cancelShellHandoff(state.handoffToken)]

        case .createRequested(let request, let runsSample):
            return requestCreation(request, runsSample: runsSample)

        case .created(let attempt, let identity, let row):
            guard case .resolving(attempt, _) = state.attempt else { return [] }
            state.created = CreatedTerminal(identity: identity, row: row)
            return [.continueAttempt(.awaitRow(attempt: attempt, row))]

        case .refreshed(let attempt):
            guard case .resolving(attempt, _) = state.attempt, let created = state.created
            else { return [] }
            return [.continueAttempt(.awaitRow(attempt: attempt, created.row))]

        case .creationFailed(let attempt, let message):
            guard case .resolving(attempt, let token) = state.attempt else { return [] }
            return [.cancelShellHandoff(token), .presentFailure(message)]

        case .rowAwaited(let attempt, let found, let visible):
            guard case .resolving(attempt, let token) = state.attempt,
                  let created = state.created
            else { return [] }
            guard found else {
                return [.cancelShellHandoff(token), .presentFailure(Self.rowNotRefreshedMessage)]
            }
            return visible
                ? [.openShell(created.row, handoffToken: token)]
                : [.cancelShellHandoff(token)]

        case .attemptFinished(let attempt):
            guard case .resolving(attempt, _) = state.attempt else { return [] }
            state.attempt = .idle
            return []
        }
    }

    /// New Terminal, or a retry of the terminal this detail created.
    private mutating func requestCreation(
        _ request: ShellTerminalCreationRequest?, runsSample: Bool
    ) -> [Effect] {
        let token = state.handoffToken
        if runsSample { return [.cancelShellHandoff(token), .connectSample] }
        guard !isResolving, let request else { return [.cancelShellHandoff(token)] }
        lastToken += 1
        state.attempt = .resolving(attempt: lastToken, handoffToken: token)
        let step: Step = state.created == nil
            ? .create(attempt: lastToken, request)
            : .refresh(attempt: lastToken)
        return [.startAttempt(attempt: lastToken, step)]
    }
}
