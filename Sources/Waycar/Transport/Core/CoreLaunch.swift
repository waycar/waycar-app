import Foundation

/// The pure parts of starting an agent on herdr-core (design §9): the PATH a
/// launch sends, the folder rules, the labels, and when a launch's first
/// prompt may go. Foundation only.
enum CoreLaunch {
    /// The labels every terminal Waycar starts carries. They are Waycar's
    /// own (`herdr.space` and `herdr.tab` belong to the Herdr app and are
    /// never written).
    static let markerLabel = "waycar"
    static let kindLabel = "waycar.kind"
    /// The name the Agent was launched with. Core's own terminal name must
    /// be unique among live terminals and has its own grammar, so Waycar
    /// leaves the terminal unnamed (design §9) and keeps the name here.
    static let nameLabel = "waycar.name"

    /// The Launch Tag survives a lost `terminal.run` answer and reconnect.
    static let launchLabel = "waycar.launch"

    static func labels(kind: String, name: String = "", launchID: UUID? = nil) -> [String: String] {
        var labels = [markerLabel: "1", kindLabel: kind]
        if !name.isEmpty { labels[nameLabel] = name }
        if let launchID { labels[launchLabel] = launchID.uuidString }
        return labels
    }

    /// What a launch of a program core could not find says. `spawn_failed`
    /// is core's one answer for a missing program, a program that cannot run
    /// and a bad folder; the folder is checked first, so by the time it
    /// arrives the program is the cause.
    static func notInstalledMessage(kind: String) -> String {
        "\(kind) is not installed on this Host, or is not on its PATH"
    }

    /// `folder` as an absolute path core can use: `~` and `~/…` expand from
    /// the Host's home (core never expands `~`); anything else must already
    /// be absolute. Nil for a relative folder, an empty one, one with a
    /// control character, or `~user`.
    static func absoluteFolder(
        _ folder: String, home: @Sendable () async throws -> String
    ) async throws -> String? {
        let trimmed = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
            !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        if trimmed == "~" || trimmed.hasPrefix("~/") {
            let base = try await home()
            guard base.hasPrefix("/") else { return nil }
            let rest = trimmed.dropFirst()
            return base.hasSuffix("/") && rest.hasPrefix("/")
                ? String(base.dropLast()) + rest : base + rest
        }
        return trimmed.hasPrefix("/") ? trimmed : nil
    }

    // MARK: The PATH of a launch

    private static let launchPathMarker = "@@WAYCAR-LAUNCH-PATH@@"

    /// The exec that turns the login PATH into the literal PATH a launch
    /// sends as `env.PATH`: the login PATH (the SSH session's own when there
    /// is none), then the usual directories the connect line also appends
    /// (a directory that did not exist when the login PATH was resolved,
    /// `~/.local/bin` before the first install, is still searched, C22).
    /// `env.PATH` is taken literally by core, so `$HOME` and the mise
    /// expansions are evaluated here, by the Host's `sh`.
    static func launchPathCommand(loginPATH: String?) -> String {
        "/bin/sh -c 'p=\"$1\"; [ -n \"$p\" ] || p=\"$PATH\"; "
            + "printf \"%s\" \"\(launchPathMarker)$p:\(HerdrHostPath.extraPATH):"
            + "\(HerdrHostPath.coreExtraPATH)\(launchPathMarker)\"' launch "
            + ShellWord.quoted(loginPATH ?? "")
    }

    /// The PATH between the markers; nil when there is none, or it holds a
    /// newline or control character.
    static func parseLaunchPath(_ output: String) -> String? {
        guard let start = output.range(of: launchPathMarker),
            let end = output.range(of: launchPathMarker, range: start.upperBound..<output.endIndex)
        else { return nil }
        let value = String(output[start.upperBound..<end.lowerBound])
        guard value.contains("/"),
            !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return value
    }

    // MARK: First prompt

    /// What the gate on a launch's first prompt decides from the terminal's
    /// record.
    enum Readiness: Equatable, Sendable {
        /// Let the prompt through.
        case ready
        /// Not yet: the prompt fails `agent_not_ready` and is retried.
        case waiting
        /// The agent has not reported and the wait is over: read its screen
        /// and call ``screenDecision(kind:screen:elapsed:unreportedWait:)``.
        case readScreen
    }

    /// The first step of the gate (design §9 step 4). A program that has
    /// reported its status through OSC 7501 is ready: `idle` is what it
    /// reports when it takes input, `working` and `done` mean it already
    /// has, and `blocked` is core's own refusal to make. One that has not
    /// reported is left alone for `unreportedWait`, then read. A terminal
    /// the inventory does not list yet (its `created` event is in flight)
    /// waits the same time; a finished one is ready, because the prompt
    /// fails on its own with `agent_not_found`.
    static func readiness(
        of terminal: CoreTerminal?, elapsed: Duration, unreportedWait: Duration
    ) -> Readiness {
        if let terminal {
            if terminal.isFinished || terminal.reported { return .ready }
        }
        return elapsed >= unreportedWait ? .readScreen : .waiting
    }

    /// The second step, for an agent that never reported: with a marker the
    /// kind's input must be on screen (the opencode/kilo/cline rule,
    /// `AgentScreen.inputIsOnScreen`); a kind with no marker needs the
    /// kind's own `minimumDelay` out and something drawn. Sign-in and
    /// folder-trust screens are refused before the gate is asked.
    static func screenDecision(
        kind: String, screen: String, elapsed: Duration, unreportedWait: Duration
    ) -> Readiness {
        let readiness = AgentScreen.readiness(kind: kind)
        if let marker = readiness.marker {
            return AgentScreen.inputIsOnScreen(marker, screen: screen) ? .ready : .waiting
        }
        let drawn = !screen.allSatisfy(\.isWhitespace)
        return drawn && elapsed >= max(unreportedWait, readiness.minimumDelay) ? .ready : .waiting
    }
}

/// A launch whose first prompt is held until the agent takes input.
struct CoreLaunchGate: Sendable, Equatable {
    let kind: String
    let launchedAt: ContinuousClock.Instant
}

/// The first-prompt gate of the launches Waycar made on one connection
/// (design §9 step 4): each terminal address is open (no gate, also every
/// terminal Waycar did not launch) or holding its launch's first prompt.
///
/// A prompt's check starts from the gate it found and reads the record
/// (`recordRead`), then, for an agent that never reported, its screen
/// (`screenRead`). Several checks may run at once. A check that lets its
/// prompt through opens the address, whichever gate holds it by then: a
/// tagged retry that re-armed the address while the check read is opened
/// too, as before the machine (the terminal is the same one).
struct CoreLaunchGateMachine: StateMachine {
    struct State: Equatable, Sendable {
        fileprivate(set) var gates: [String: CoreLaunchGate] = [:]
    }

    enum Event: Sendable {
        /// Waycar launched, or adopted by its Launch Tag, the terminal at
        /// `address`.
        case launched(address: String, kind: String, at: ContinuousClock.Instant)
        /// A check found `gate`, `elapsed` after its launch, and read the
        /// terminal's record (nil when it is not listed yet).
        case recordRead(
            address: String, gate: CoreLaunchGate, record: CoreTerminal?, elapsed: Duration,
            unreportedWait: Duration)
        /// The check's screen read, after `readScreen`.
        case screenRead(
            address: String, gate: CoreLaunchGate, screen: String, elapsed: Duration,
            unreportedWait: Duration)
    }

    enum Effect: Equatable, Sendable {
        /// The prompt goes; the address is open from now on.
        case letThrough
        /// The prompt fails `agent_not_ready` and is retried by its sender.
        case hold
        /// Read the visible screen and send `screenRead`.
        case readScreen
    }

    private(set) var state = State()

    init() {}

    /// The gate holding `address`; nil when its prompts go.
    func gate(at address: String) -> CoreLaunchGate? {
        state.gates[address]
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .launched(let address, let kind, let at):
            state.gates[address] = CoreLaunchGate(kind: kind, launchedAt: at)
            return []
        case .recordRead(let address, _, let record, let elapsed, let unreportedWait):
            switch CoreLaunch.readiness(of: record, elapsed: elapsed, unreportedWait: unreportedWait) {
            case .ready: return open(address)
            case .waiting: return [.hold]
            case .readScreen: return [.readScreen]
            }
        case .screenRead(let address, let gate, let screen, let elapsed, let unreportedWait):
            let decision = CoreLaunch.screenDecision(
                kind: gate.kind, screen: screen, elapsed: elapsed, unreportedWait: unreportedWait)
            return decision == .ready ? open(address) : [.hold]
        }
    }

    private mutating func open(_ address: String) -> [Effect] {
        state.gates[address] = nil
        return [.letThrough]
    }
}
