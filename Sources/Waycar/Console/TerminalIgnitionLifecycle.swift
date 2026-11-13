import Foundation

/// What the New Agent sheet leaves for the terminal it opens (#96).
struct AgentLaunchNote: Equatable, Sendable {
    /// The sheet's last launch step line, such as "Opening Claude".
    let lastStep: String?
}

/// What the Ignition loader is told about the attach under it.
enum TerminalIgnitionSignal: Equatable {
    case waiting
    case live
    case failed
    /// Stopped, ended, or released to another window: nothing to wait for.
    case idle

    init(presentation: TerminalStatusPresentation?, isLive: Bool) {
        switch presentation?.kind {
        case .connecting: self = .waiting
        case .hostUnavailable: self = .failed
        // No dialog goes with an ended attach, so there is nothing for a
        // frozen loader to sit under: the terminal shows as it is.
        case .ended: self = .idle
        case nil: self = isLive ? .live : .idle
        }
    }
}

/// Ignition's timeline, as a value so it can be tested without a screen:
/// nothing shows for `grace` (a fast attach just paints), then the loader
/// fades in. The first paint after that starts the reveal `paintSettle`
/// later, from whatever opacity the fade had reached; it lands on the live
/// terminal and ends. A failure while showing freezes the loader at that
/// opacity under the status dialog. No minimum hold: content is never
/// delayed.
struct TerminalIgnitionLifecycle: Equatable {
    enum Phase: Equatable {
        case hidden
        /// Waiting since `since`; shows from `visibleAt`.
        case waiting(since: Date, visibleAt: Date)
        /// Revealing from `start`, at the opacity `from` the fade-in reached,
        /// after a wait of `waited`.
        case revealing(start: Date, from: Double, waited: TimeInterval)
        case done
        /// Stopped at `at` under a failure dialog, having waited since
        /// `since`, at the opacity `from` the fade-in reached.
        case frozen(since: Date, at: Date, from: Double)
    }

    static let grace: TimeInterval = 0.25
    static let fadeIn: TimeInterval = 0.3
    // ponytail: a fixed settle between `.live` (the first bytes) and the
    // reveal, because Ghostty draws them a frame or three later and its
    // post-render hook (`TerminalSurfaceCoordinator.onPostRender`) is
    // internal to GhosttyTerminal; ceiling: a slower first draw still shows
    // a blank cell or two at the start of the wipe; upgrade: a public
    // first-render callback on `UITerminalView`.
    static let paintSettle: TimeInterval = 0.09
    /// When the wait is long enough to say what it is waiting on.
    static let slowLineDelay: TimeInterval = 3

    var revealDuration: TimeInterval
    private(set) var phase: Phase = .hidden

    init(revealDuration: TimeInterval = 0.38) {
        self.revealDuration = revealDuration
    }

    mutating func connect(at now: Date) {
        switch phase {
        case .waiting:
            return
        case .frozen:
            // A reattach keeps the frozen loader up rather than blinking it
            // out for the grace period.
            phase = .waiting(since: now, visibleAt: now.addingTimeInterval(-Self.fadeIn))
        case .hidden, .revealing, .done:
            phase = .waiting(since: now, visibleAt: now.addingTimeInterval(Self.grace))
        }
    }

    /// The attach painted. Returns when the wait it ends began, or nil when
    /// nothing was waiting. A paint over a freeze ends the loader, so it
    /// never covers a live terminal.
    @discardableResult
    mutating func paint(at now: Date) -> Date? {
        if case .frozen = phase {
            phase = .done
            return nil
        }
        guard case .waiting(let since, _) = phase else { return nil }
        phase =
            isVisible(at: now)
            ? .revealing(
                start: now.addingTimeInterval(Self.paintSettle), from: opacity(at: now),
                waited: now.timeIntervalSince(since))
            : .done
        return since
    }

    mutating func fail(at now: Date) {
        switch phase {
        case .waiting(let since, _):
            phase =
                isVisible(at: now) ? .frozen(since: since, at: now, from: opacity(at: now)) : .done
        case .revealing:
            phase = .done
        case .hidden, .done, .frozen:
            return
        }
    }

    /// Ends a reveal that has run its course.
    mutating func tick(at now: Date) {
        guard case .revealing(let start, _, _) = phase,
            now.timeIntervalSince(start) >= revealDuration
        else { return }
        phase = .done
    }

    mutating func reset() {
        phase = .hidden
    }

    func isVisible(at now: Date) -> Bool {
        switch phase {
        case .waiting(_, let visibleAt): now >= visibleAt
        case .revealing, .frozen: true
        case .hidden, .done: false
        }
    }

    /// The fade-in, eased out; a reveal or a freeze holds where it stopped.
    func opacity(at now: Date) -> Double {
        switch phase {
        case .waiting(_, let visibleAt):
            Self.easeOut(now.timeIntervalSince(visibleAt) / Self.fadeIn)
        case .revealing(_, let from, _), .frozen(_, _, let from): from
        case .hidden, .done: 0
        }
    }

    /// How far the reveal has gone, eased in and out so its first frames
    /// grow slowly from the cursor, or nil outside one. Zero during the
    /// settle before it starts.
    func revealProgress(at now: Date) -> Double? {
        guard case .revealing(let start, _, _) = phase else { return nil }
        let progress = min(max(now.timeIntervalSince(start) / revealDuration, 0), 1)
        return progress < 0.5 ? 4 * pow(progress, 3) : 1 - pow(2 - 2 * progress, 3) / 2
    }

    /// How long the attach has waited, held through a reveal or a freeze,
    /// or nil when there is no wait to speak of.
    func waited(at now: Date) -> TimeInterval? {
        switch phase {
        case .waiting(let since, _): now.timeIntervalSince(since)
        case .revealing(_, _, let waited): waited
        case .frozen(let since, let at, _): at.timeIntervalSince(since)
        case .hidden, .done: nil
        }
    }

    var frozenAt: Date? {
        if case .frozen(_, let at, _) = phase { at } else { nil }
    }

    /// When the wait began, while waiting or frozen.
    var waitStart: Date? {
        switch phase {
        case .waiting(let since, _), .frozen(let since, _, _): since
        case .hidden, .revealing, .done: nil
        }
    }

    private static func easeOut(_ progress: Double) -> Double {
        let clamped = min(max(progress, 0), 1)
        return 1 - pow(1 - clamped, 3)
    }
}

/// Who is coming up: the Agent's title and where it runs.
struct TerminalIgnitionIdentity: Equatable {
    let title: String
    let hostName: String
    /// `host · repo-or-workspace`.
    let caption: String
    /// The New Agent sheet's last step, when it opened this terminal.
    let launchStep: String?
    let isLaunch: Bool

    @MainActor
    init(agent: ConsoleAgent, launch: AgentLaunchNote?) {
        title = AgentTerminalView.displayTitle(for: agent)
        hostName = agent.hostName
        caption = [agent.hostName, agent.repoName ?? agent.workspaceLabel]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        launchStep = launch?.lastStep
        isLaunch = launch != nil
    }
}
