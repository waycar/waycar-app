import Foundation

@testable import Waycar

/// What the harness lab (scripts/harness-lab) can make one kind do, and what
/// the suite therefore expects of it on each backend. Every entry cites the
/// dossier (`docs/research/harnesses/<kind>.md`, lab versions of 2026-10-12)
/// it comes from; a capability the lab cannot produce carries the reason
/// instead of an expectation, and the suite reports it rather than faking it.
struct HarnessLabProfile: Sendable {
    /// How an approval dialog is answered "yes, once": key presses, never
    /// pasted text, which a TUI with bracketed paste on (cline) ignores.
    enum Approve: Sendable {
        case keys([String])
    }

    /// How the lab makes the kind ask before running the mock's tool call.
    struct Approval: Sendable {
        /// The mock token: `WAYCAR_TOOL` runs `echo waycar-tool-ok`, which
        /// most harnesses auto-allow as read-only; `WAYCAR_TOOL_MUTATE` runs
        /// `touch /tmp/waycar-tool-mutate && echo waycar-tool-ok`.
        let token: String
        /// Launch arguments (the New Agent sheet's Arguments field) and
        /// environment that turn approvals on.
        let arguments: [String]
        let environment: [String: String]
        let approve: Approve
        /// Whether the dossier saw this dialog live; false = docs/source only.
        let verifiedLive: Bool
    }

    let kind: SupportedAgentKind
    /// Account-only: the lab stops at sign-in (cursor, kiro, devin).
    let signIn: Bool
    /// nil: the lab cannot produce a blocked state; see `noApprovalReason`.
    let approval: Approval?
    let noApprovalReason: String?
    /// How long a cold launch may take to answer its first turn.
    let launchBudget: Duration
    /// A first-run dialog the lab still shows, answered once per launch
    /// before anything else (screen text, keys).
    let startupDialog: (marker: String, keys: [String])?
    /// herdr screen detection reports working/done for this kind with no
    /// integration; with one, the hook does (herdr-backend.md matrix).
    let herdrStatusWithoutIntegration: Bool
    /// herdr reports no `agent_session` for it even with its integration.
    let herdrNeverReportsSession: Bool
    /// Why herdr's screen detection does not report a turn the model answers
    /// in text alone (no tool call); nil where it does. Such a turn reads
    /// idle throughout, or working only by catching its last frame, so the
    /// suite asserts no working → done for it on herdr (copilot.md §11).
    let herdrTextTurnsUnreported: String?
    /// The chat reader finds this kind's transcript only by a session id:
    /// agy's transcript records no cwd, so its reader has no launch lookup
    /// (plugin/src/chat-readers/agy.js); only herdr's agy integration or the
    /// tmux Status Hook supplies the id. Without one the read is `not_found`.
    /// (opencode, kilo and hermes find a session-less launch through their
    /// own session lists, plugin/src/chat-transcript.js.)
    var transcriptNeedsSession: Bool { kind == .antigravity }

    /// The approval the case turns on for this backend: none where the
    /// backend reports no turns for the kind, since a dialog it cannot
    /// report as blocked could only be answered blind (omp on herdr without
    /// herdr's omp integration reads idle throughout, herdr-backend.md).
    func approval(on backend: HostBackend, environment: HarnessLabEnvironment) -> Approval? {
        reportsTurns(on: backend, environment: environment) ? approval : nil
    }

    /// Why the case on this backend expects no blocked state.
    func noApprovalReason(on backend: HostBackend, environment: HarnessLabEnvironment) -> String? {
        if approval != nil, !reportsTurns(on: backend, environment: environment) {
            return "\(backend.rawValue) reports no turns for \(kind.rawValue) without its integration (herdr-backend.md)"
        }
        return noApprovalReason
    }

    /// Whether the backend reports working and done for a turn.
    func reportsTurns(on backend: HostBackend, environment: HarnessLabEnvironment) -> Bool {
        switch backend {
        case .herdr: herdrStatusWithoutIntegration || environment.herdrIntegrations.contains(kind)
        // The harness lab has no herdr-core or Zellij Host.
        case .core, .zellij, .ultimate, .codex, .opencode: false
        // Waycar's Status Hooks (plugin/src/agent-hooks.js) cover every lab kind.
        case .tmux: true
        }
    }

    /// Whether the backend reports the Agent's session, which Closed
    /// Sessions resume by.
    func reportsSession(on backend: HostBackend, environment: HarnessLabEnvironment) -> Bool {
        switch backend {
        case .herdr: !herdrNeverReportsSession && environment.herdrIntegrations.contains(kind)
        case .core, .zellij, .ultimate, .codex, .opencode: false
        // `@waycar_session`, written by the Status Hooks' session handling.
        case .tmux: true
        }
    }

    /// Why the backend gives no working → done for a turn answered in text
    /// alone, though it reports turns for the kind; nil where it does.
    func unreportedTextTurnReason(on backend: HostBackend) -> String? {
        backend == .herdr ? herdrTextTurnsUnreported : nil
    }

    /// Why a resume with no session (`ClosedSession.resumeArguments` gave
    /// `arguments` for none) cannot be checked; nil where the form reopens
    /// the most recent session in the working directory (`--continue`,
    /// gemini's and hermes's `--resume latest`, muse's `resume --last`).
    func sessionlessResumeUncheckable(_ arguments: [String]) -> String? {
        if arguments.isEmpty { return "\(kind.rawValue) has no session-less resume form" }
        switch kind {
        // Each opens an interactive picker without an id: claude.md, codex
        // (`ClosedSession.resumeArguments`), omp.md (`--resume`, "picker if
        // omitted"), pi's `--resume`, devin.md (`-r` "pick interactively").
        case .claude, .codex, .omp, .pi, .devin:
            return "its session-less form opens an interactive picker"
        default:
            return nil
        }
    }

    /// The 17 lab harnesses (scripts/harness-lab/VERSIONS).
    static let labKinds: [SupportedAgentKind] = [
        .claude, .codex, .opencode, .pi, .omp, .copilot, .cursor, .antigravity, .gemini, .cline,
        .kilo, .kiro, .devin, .hermes, .qwen, .grok, .muse,
    ]

    static func profile(for kind: SupportedAgentKind) -> HarnessLabProfile {
        all.first { $0.kind == kind }
            ?? HarnessLabProfile(
                kind: kind, signIn: false, approval: nil,
                noApprovalReason: "not a lab harness", launchBudget: .seconds(60),
                startupDialog: nil, herdrStatusWithoutIntegration: true,
                herdrNeverReportsSession: false, herdrTextTurnsUnreported: nil)
    }

    private static func make(
        _ kind: SupportedAgentKind, signIn: Bool = false, approval: Approval? = nil,
        noApprovalReason: String? = nil, launchBudget: Duration = .seconds(60),
        startupDialog: (marker: String, keys: [String])? = nil,
        herdrStatusWithoutIntegration: Bool = true, herdrNeverReportsSession: Bool = false,
        herdrTextTurnsUnreported: String? = nil
    ) -> HarnessLabProfile {
        HarnessLabProfile(
            kind: kind, signIn: signIn, approval: approval, noApprovalReason: noApprovalReason,
            launchBudget: launchBudget, startupDialog: startupDialog,
            herdrStatusWithoutIntegration: herdrStatusWithoutIntegration,
            herdrNeverReportsSession: herdrNeverReportsSession,
            herdrTextTurnsUnreported: herdrTextTurnsUnreported)
    }

    static let all: [HarnessLabProfile] = [
        // claude.md: the lab's default permission mode is auto; a dialog
        // appears only with `permissions.ask: ["Bash"]` via --settings.
        make(
            .claude,
            approval: Approval(
                token: "WAYCAR_TOOL",
                arguments: ["--settings", #"{"permissions":{"ask":["Bash"]}}"#],
                environment: [:], approve: .keys(["enter"]), verifiedLive: true)),
        // codex.md drift 2: approvals come only from an escalation request,
        // which the mock now sends (sandbox_permissions require_escalated).
        // The hooks-review screen appears until Waycar's hooks are trusted
        // (scripts/harness-lab/README.md); "Trust all" is the second option.
        make(
            .codex,
            approval: Approval(
                token: "WAYCAR_TOOL", arguments: [], environment: [:],
                approve: .keys(["enter"]), verifiedLive: false),
            startupDialog: (marker: "Trust all", keys: ["down", "enter"]),
            herdrNeverReportsSession: true),
        // opencode.md: default permissions allow bash; the dialog came from
        // OPENCODE_CONFIG_CONTENT.
        make(
            .opencode,
            approval: Approval(
                token: "WAYCAR_TOOL", arguments: [],
                environment: ["OPENCODE_CONFIG_CONTENT": #"{"permission":{"bash":"ask"}}"#],
                approve: .keys(["enter"]), verifiedLive: true),
            launchBudget: .seconds(90)),
        // pi.md: pi has no approvals, so it has no blocked state.
        make(.pi, noApprovalReason: "pi has no approvals (pi.md)"),
        // omp.md: default approval mode is yolo; --approval-mode=always-ask
        // produced the dialog. Without its herdr integration omp reads idle
        // for whole turns (herdr-backend.md).
        make(
            .omp,
            approval: Approval(
                token: "WAYCAR_TOOL", arguments: ["--approval-mode=always-ask"], environment: [:],
                approve: .keys(["enter"]), verifiedLive: true),
            herdrStatusWithoutIntegration: false),
        // copilot.md: echo is auto-allowed as read-only; a write asks
        // ("Do you want to run this command?", 1. Yes). On herdr its status
        // is screen-detected even with the integration (session only), and
        // a tool turn reads working → done once the tool call arrives.
        make(
            .copilot,
            approval: Approval(
                token: "WAYCAR_TOOL_MUTATE", arguments: [], environment: [:],
                approve: .keys(["enter"]), verifiedLive: false),
            herdrTextTurnsUnreported:
                "herdr 0.9.3's copilot manifest (2026.08.29.1, also the current remote one) has no rule for copilot's "
                + "\"◉ Working esc edit prompt\" footer, shown until the model's first output, and the mock's text "
                + "reply arrives in one burst that ends the turn about 200 ms later (copilot.md §11)"),
        make(.cursor, signIn: true, noApprovalReason: "account-only: stops at sign-in (cursor.md)"),
        // agy.md: every lab launch reached the permission prompt; Enter runs once.
        make(
            .antigravity,
            approval: Approval(
                token: "WAYCAR_TOOL", arguments: [], environment: [:],
                approve: .keys(["enter"]), verifiedLive: true)),
        // gemini.md: echo runs without a dialog; a write asks "Allow
        // execution of [Shell]?" (MockServer checked WAYCAR_TOOL_MUTATE live).
        make(
            .gemini,
            approval: Approval(
                token: "WAYCAR_TOOL_MUTATE", arguments: [], environment: [:],
                approve: .keys(["enter"]), verifiedLive: true)),
        // cline.md: default -i auto-approves everything; --auto-approve false
        // shows "[y] Approve   [n] Deny". A `y` key press answers it; a
        // bracketed paste of "y" (tmux `paste-buffer -p`, herdr
        // `pane.send_input` text) is ignored (§10).
        make(
            .cline,
            approval: Approval(
                token: "WAYCAR_TOOL", arguments: ["--auto-approve", "false"], environment: [:],
                approve: .keys(["y"]), verifiedLive: true),
            launchBudget: .seconds(90)),
        // kilo.md: the per-command safe list allows `echo *`; both "*" and
        // "echo *" had to ask. KILO_CONFIG_CONTENT is opencode's variable
        // renamed, as every kilo path and variable is [INFERENCE].
        make(
            .kilo,
            approval: Approval(
                token: "WAYCAR_TOOL_MUTATE", arguments: [],
                environment: [
                    "KILO_CONFIG_CONTENT":
                        #"{"permission":{"bash":{"*":"ask","echo *":"ask","touch *":"ask"}}}"#
                ],
                approve: .keys(["enter"]), verifiedLive: false),
            launchBudget: .seconds(90)),
        make(.kiro, signIn: true, noApprovalReason: "account-only: stops at sign-in (kiro.md)"),
        make(.devin, signIn: true, noApprovalReason: "account-only: stops at sign-in (devin.md)"),
        // hermes.md §1: only dangerous commands ask, and echo is not one; a
        // `pre_tool_call` hook answering `{"action": "approve"}` escalates the
        // call to the human gate (the dialog was forced live that way). The
        // lab's `waycar-lab-approval` plugin (host/config/hermes) does that
        // for a terminal call when the launch sets WAYCAR_LAB_HERMES_ASK=1.
        // Enter takes the highlighted "1. Allow once" (§10).
        make(
            .hermes,
            approval: Approval(
                token: "WAYCAR_TOOL", arguments: [], environment: ["WAYCAR_LAB_HERMES_ASK": "1"],
                approve: .keys(["enter"]), verifiedLive: true),
            launchBudget: .seconds(120)),
        // qwen.md: read-only echo is auto-allowed; the lab default is Auto
        // mode, so approvals need --approval-mode default plus a write. Enter
        // takes the highlighted "1. Yes, allow once" (qwen.md §10).
        make(
            .qwen,
            approval: Approval(
                token: "WAYCAR_TOOL_MUTATE", arguments: ["--approval-mode", "default"],
                environment: [:], approve: .keys(["enter"]), verifiedLive: true)),
        // grok.md §10: the lab's ~/.grok/config.toml asks before every shell
        // command (`[permission] ask = ["Bash"]`). Its preselected option is
        // always-approve, so the approval presses `3`, "Yes, proceed", which
        // approved once live.
        make(
            .grok,
            approval: Approval(
                token: "WAYCAR_TOOL", arguments: [], environment: [:],
                approve: .keys(["3"]), verifiedLive: true)),
        // muse.md §10: the lab's Auto-review mode asks even for the mock's
        // echo ("Would you like to run the following command?", Enter takes
        // "1. Yes, proceed (y)"). herdr's status comes from Muse's built-in
        // herdr plugin, which never reports a session (§1, §11). A cold
        // first launch took 39 s to take input.
        make(
            .muse,
            approval: Approval(
                token: "WAYCAR_TOOL", arguments: [], environment: [:],
                approve: .keys(["enter"]), verifiedLive: true),
            launchBudget: .seconds(90), herdrNeverReportsSession: true),
    ]
}
