import Foundation
import Testing

@testable import Waycar

/// The Closed Session record: how it resumes each Agent kind, what it is
/// keyed by, and what a search finds in it.
@Suite("Closed session")
struct ClosedSessionTests {
    private typealias Reference = ClosedSession.SessionReference

    @Test func resumeArgumentsMirrorHerdrsRestorePlanner() {
        let id = Reference(kind: .id, value: "0b6a2c1e-5f1d-4e4c-9b1a-3f2d8c7e6a10")
        let path = Reference(kind: .path, value: "/home/me/.omp/sessions/s.jsonl")
        var cases: [(SupportedAgentKind, Reference?, [String])] = [
            (.claude, id, ["--resume", id.value]),
            (.claude, nil, ["--resume"]),
            // herdr resumes claude by id only.
            (.claude, path, ["--resume"]),
            (.codex, id, ["resume", id.value]),
            (.codex, nil, ["resume"]),
            (.omp, path, ["--resume=\(path.value)"]),
            (.omp, id, ["--resume=\(id.value)"]),
            (.omp, nil, ["--resume"]),
            (.pi, path, ["--session", path.value]),
            (.pi, id, ["--session", id.value]),
            (.pi, nil, ["--resume"]),
            (.opencode, id, ["--session", id.value]),
            (.opencode, nil, []),
            (.kimi, id, ["--session", id.value]),
            (.mastracode, id, ["--thread", id.value]),
            (.amp, id, []),
            // Waycar's tmux hooks store these kinds' ids (`@waycar_session`);
            // herdr 0.9.3 reports none without its integration, so each falls
            // back to its own continue or picker form (herdr-backend.md).
            (.copilot, id, ["--resume=\(id.value)"]),
            (.copilot, nil, ["--continue"]),
            (.kilo, id, ["--session", id.value]),
            (.kilo, nil, ["--continue"]),
            (.antigravity, id, ["--conversation", id.value]),
            (.antigravity, nil, ["--continue"]),
            (.gemini, id, ["--resume", id.value]),
            (.gemini, nil, ["--resume", "latest"]),
            (.gemini, path, ["--resume", "latest"]),
            (.cline, Reference(kind: .id, value: "1791823632626_6jtha"), ["--id", "1791823632626_6jtha"]),
            (.cline, nil, []),
            (.kiro, id, ["--resume-id", id.value]),
            (.kiro, nil, ["--resume"]),
            (.devin, id, ["--resume", id.value]),
            (.devin, nil, ["--resume"]),
            (.muse, id, ["resume", id.value]),
            (.muse, nil, ["resume", "--last"]),
            (.muse, path, ["resume", "--last"]),
            // hermes's `--continue` follows a per-tty breadcrumb first;
            // `--resume latest` is the workspace's most recent session.
            (.hermes, id, ["--resume", id.value]),
            (.hermes, nil, ["--resume", "latest"]),
            (.hermes, path, ["--resume", "latest"]),
        ]
        for kind in [SupportedAgentKind.grok, .qwen] {
            cases.append((kind, id, ["--resume", id.value]))
            cases.append((kind, nil, ["--continue"]))
            // Resumed by id only.
            cases.append((kind, path, ["--continue"]))
        }
        for kind in [SupportedAgentKind.cursor, .droid, .qodercli] {
            cases.append((kind, id, ["--resume", id.value]))
            // Without a session herdr knows no picker form for these.
            cases.append((kind, nil, []))
            cases.append((kind, path, []))
        }
        for (kind, session, expected) in cases {
            #expect(
                ClosedSession.resumeArguments(kind: kind, session: session) == expected,
                "\(kind.rawValue) with \(String(describing: session))")
        }
    }

    @Test func aSessionValueThatReadsAsAFlagOpensThePickerInstead() {
        let flag = Reference(kind: .id, value: "--dangerously-skip-permissions")
        #expect(ClosedSession.resumeArguments(kind: .claude, session: flag) == ["--resume"])
        #expect(ClosedSession.resumeArguments(kind: .codex, session: flag) == ["resume"])
        #expect(ClosedSession.resumeArguments(kind: .copilot, session: flag) == ["--continue"])
        #expect(ClosedSession.resumeArguments(kind: .gemini, session: flag) == ["--resume", "latest"])
    }

    /// Two devices that saw the same Agent close derive one record, and the
    /// same session closing again after a resume lands on it too.
    @Test func theSameClosureYieldsTheSameRecordOnEveryDevice() {
        let hostID = UUID()
        let session = Reference(kind: .id, value: "abc")
        let first = ClosedSession.recordID(
            hostID: hostID, kind: .claude, session: session, terminalID: "t1")
        // Resumed into a new tab, then closed again: another terminal.
        let again = ClosedSession.recordID(
            hostID: hostID, kind: .claude, session: session, terminalID: "t9")
        #expect(first == again)
        #expect(
            first
                != ClosedSession.recordID(
                    hostID: hostID, kind: .claude, session: Reference(kind: .id, value: "xyz"),
                    terminalID: "t1"))
        #expect(
            first
                != ClosedSession.recordID(
                    hostID: UUID(), kind: .claude, session: session, terminalID: "t1"))
        // Without a session the terminal it ran in identifies it.
        #expect(
            ClosedSession.recordID(hostID: hostID, kind: .gemini, session: nil, terminalID: "t1")
                != ClosedSession.recordID(
                    hostID: hostID, kind: .gemini, session: nil, terminalID: "t2"))
    }

    /// herdr clears `agent_session` as the Agent leaves, so the session the
    /// Console remembered for it wins over what the closing row still says.
    @Test func theRememberedSessionWinsOverTheClosingRowsOwn() throws {
        let row = ConsoleAgent(
            hostID: UUID(), hostName: "studio",
            agent: Agent(
                terminalID: "term-1", kind: "claude", title: "Fix login", status: .idle,
                workspaceID: "w1", tabID: "w1:t1", paneID: "w1:p1", cwd: "/work/app",
                revision: 1,
                agentSession: AgentSessionInfo(
                    agent: "claude", kind: .id, source: "herdr:claude", value: "on-row")),
            workspaceLabel: "App", repositoryCheckout: nil)
        let remembered = AgentSessionInfo(
            agent: "claude", kind: .id, source: "herdr:claude", value: "remembered")
        let closedAt = Date(timeIntervalSince1970: 1_800_000_000.1234)

        let session = try #require(
            ClosedSession(
                closing: row, session: remembered, lastSeenRunningAt: closedAt, closedAt: closedAt))
        let fromRow = try #require(
            ClosedSession(closing: row, session: nil, lastSeenRunningAt: closedAt, closedAt: closedAt))

        #expect(session.session == Reference(kind: .id, value: "remembered"))
        #expect(session.resumeArguments == ["--resume", "remembered"])
        #expect(fromRow.session == Reference(kind: .id, value: "on-row"))
        #expect(session.id != fromRow.id)
        // Stored in whole milliseconds, so a decoded copy compares equal.
        let decoded = try JSONDecoder().decode(
            ClosedSession.self, from: JSONEncoder().encode(session))
        #expect(decoded == session)
    }

    @Test func shellsAndKindsWaycarCannotStartAreNotCaptured() {
        let shell = ConsoleAgent(
            hostID: UUID(), hostName: "studio",
            agent: Agent(
                terminalID: "t", kind: Agent.shellKind, title: "zsh", status: .shellTerminal,
                workspaceID: "w1", tabID: "w1:t1", paneID: "p", cwd: "/", revision: 1),
            workspaceLabel: nil, repositoryCheckout: nil)
        let unknown = ConsoleAgent(
            hostID: UUID(), hostName: "studio",
            agent: Agent(
                terminalID: "t", kind: "unknown", title: "", status: .unknown,
                workspaceID: "w1", tabID: "w1:t1", paneID: "p", cwd: "/", revision: 1),
            workspaceLabel: nil, repositoryCheckout: nil)
        let now = Date()
        #expect(
            ClosedSession(closing: shell, session: nil, lastSeenRunningAt: now, closedAt: now)
                == nil)
        #expect(
            ClosedSession(closing: unknown, session: nil, lastSeenRunningAt: now, closedAt: now)
                == nil)
    }

    /// Close Agent skips its confirmation only when the Closed Session it
    /// leaves brings the conversation back (#185).
    @Test func onlyAConversationClosedSessionsCanResumeClosesWithoutAsking() {
        func row(_ kind: String, session: String? = nil) -> ConsoleAgent {
            ConsoleAgent(
                hostID: UUID(), hostName: "studio",
                agent: Agent(
                    terminalID: "t", kind: kind, title: "", status: .idle,
                    workspaceID: "w1", tabID: "w1:t1", paneID: "p", cwd: "/", revision: 1,
                    agentSession: session.map {
                        AgentSessionInfo(agent: kind, kind: .id, source: "herdr:\(kind)", value: $0)
                    }),
                workspaceLabel: nil, repositoryCheckout: nil)
        }
        let cases: [(ConsoleAgent, Bool, String)] = [
            (row("claude", session: "abc"), true, "exact session"),
            (row("claude"), true, "claude's own resume picker"),
            (row("opencode", session: "abc"), true, "exact session"),
            (row("opencode"), false, "no session and no picker: a fresh start"),
            (row("devin"), true, "devin's own resume picker"),
            (row("gemini", session: "abc"), true, "exact session"),
            (row("gemini"), false, "latest session: may be another Agent's"),
            (row("grok"), false, "--continue: may be another Agent's"),
            (row("hermes"), false, "--resume latest: may be another Agent's"),
            (row("muse"), false, "resume --last: may be another Agent's"),
            (row("kiro"), false, "bare --resume is kiro's latest session"),
            (row("amp"), false, "never resumable"),
            (row("unknown"), false, "not kept"),
            (row(Agent.shellKind), false, "a shell is not kept"),
        ]
        for (row, expected, reason) in cases {
            #expect(
                ClosedSession.resumesConversation(of: row) == expected,
                "\(row.agent.kind): \(reason)")
        }
    }

    @Test func searchCoversNameKindDirectoryWorkspaceTabTitleAndHost() {
        let session = ClosedSession.fixture(
            hostName: "studio", kind: .codex, agentName: "reviewer", title: "Deploy fix",
            cwd: "/srv/payments", workspaceLabel: "Billing", tabLabel: "Main")
        for query in ["review", "CODEX", "payments", "billing", "main", "deploy", "stud", "  "] {
            #expect(session.matchesSearch(query, currentHostName: nil), "\(query)")
        }
        #expect(!session.matchesSearch("gemini", currentHostName: nil))
    }

    /// The card shows the Host's name now; a search finds the row by that
    /// name, not by the one it had when the Agent closed.
    @Test func searchMatchesTheHostsCurrentName() {
        let session = ClosedSession.fixture(hostName: "studio")

        #expect(session.matchesSearch("workshop", currentHostName: "workshop"))
        #expect(!session.matchesSearch("studio", currentHostName: "workshop"))
    }
}
