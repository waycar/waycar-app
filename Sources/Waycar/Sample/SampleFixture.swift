import Foundation

/// What the Sample Host shows (WAY-285): three Agents on one made-up
/// computer, one of them Blocked, one Done and one Working, so a person with
/// no Host can see what Waycar is for. Taken from the screenshot fixture's
/// Agents, but compiled into every build: nothing here reads the demo mode
/// flags, and nothing in it names a real computer, account or path.
///
/// Everything is data, and every surface that shows it is labelled "Sample"
/// (`SampleContextModifier`; the terminal's own first line). No text here claims the
/// Agents are live.
enum SampleFixture {
    static let workingPaneID = "mobile:p1"
    static let donePaneID = "mobile:p4"
    static let blockedPaneID = "checkout:p3"

    /// The Blocked Agent's screen, as a permission prompt a person would
    /// answer. Answering it changes nothing: the sample has no Agent to
    /// receive the keys.
    static let blockedPrompt = """
         Bash command
           make test-ui
         Do you want to proceed?
         ❯ 1. Yes
           2. No, and tell the agent what to do (esc)
        """

    static let snapshot = SessionSnapshot(
        agents: [
            agent(
                paneID: blockedPaneID, status: .blocked, workspaceID: "checkout", kind: "omp",
                name: "reviewer", title: "Checkout review", cwd: "/workspace/storefront"),
            agent(
                paneID: donePaneID, status: .done, workspaceID: "mobile", kind: "gemini",
                name: "accessibility", title: "Audit VoiceOver labels", cwd: "/workspace/waycar"),
            agent(
                paneID: workingPaneID, status: .working, workspaceID: "mobile", kind: "codex",
                name: "ios-polish", title: "Polish the Attach experience",
                cwd: "/workspace/waycar"),
        ],
        layouts: [],
        panes: [],
        protocolVersion: 17,
        tabs: [],
        version: "sample",
        workspaces: [
            workspace(id: "mobile", label: "iOS App", repo: "waycar", isLinkedWorktree: true),
            workspace(id: "checkout", label: "Checkout", repo: "storefront"),
        ])

    /// The Agent Summaries the sample plugin "holds", aged relative to each
    /// read so a card always reads about a minute.
    static func summaries(now: Date) -> [String: AgentSummary] {
        func summary(
            _ paneID: String, _ status: AgentStatus, minutesAgo: Int, _ text: String,
            progress: AgentProgress? = nil
        ) -> AgentSummary {
            let written = now.addingTimeInterval(TimeInterval(-minutesAgo * 60 - 5))
            return AgentSummary(
                paneID: paneID, status: status, text: text,
                timestamp: Int64(written.timeIntervalSince1970 * 1000), progress: progress)
        }
        let all = [
            summary(
                blockedPaneID, .blocked, minutesAgo: 1,
                "Waiting for approval to run the checkout UI test suite",
                progress: AgentProgress(steps: .init(done: 3, total: 6), phase: nil)),
            // Written while the Agent was still working: stale now it is Done.
            summary(
                donePaneID, .working, minutesAgo: 2,
                "Finished the VoiceOver audit: fixed 14 missing labels"),
            summary(
                workingPaneID, .working, minutesAgo: 1,
                "Reading the Attach reconnect code before smoothing the scroll position",
                progress: AgentProgress(steps: nil, phase: .exploring)),
        ]
        return Dictionary(all.map { ($0.paneID, $0) }) { first, _ in first }
    }

    /// What an Agent's terminal paints into a `cols`-wide window: a first line
    /// that says what this is, then the Agent's identity. Every line is cut to
    /// fit, so nothing wraps into a second, unlabelled row.
    static func terminalFrame(cols: Int, agent: AgentInfo?) -> String {
        let width = max(cols, 1)
        let lines = [
            "SAMPLE - not a real computer",
            "",
            agent.map { "\($0.agent ?? "agent") · \($0.name ?? "unnamed")" } ?? "agent",
            agent?.terminalTitleStripped ?? "",
            String(repeating: "-", count: min(width, 40)),
            "Nothing here is running.",
            "Connect your machine to see",
            "your own agents.",
        ]
        // Clear the screen, home the cursor, then one row per line.
        return "\u{1B}[2J\u{1B}[H"
            + lines.map { String($0.prefix(width)) }.joined(separator: "\r\n")
            + "\r\n"
    }

    private static func agent(
        paneID: String, status: AgentStatus, workspaceID: String, kind: String, name: String,
        title: String, cwd: String
    ) -> AgentInfo {
        AgentInfo(
            agentStatus: status,
            focused: false,
            paneID: paneID,
            revision: 1,
            tabID: "\(workspaceID):t1",
            terminalID: "terminal:\(paneID)",
            workspaceID: workspaceID,
            agent: kind,
            cwd: cwd,
            name: name,
            terminalTitleStripped: title)
    }

    private static func workspace(
        id: String, label: String, repo: String, isLinkedWorktree: Bool = false
    ) -> WorkspaceInfo {
        let repoRoot = isLinkedWorktree ? "/source/\(repo)" : "/workspace/\(repo)"
        return WorkspaceInfo(
            activeTabID: "\(id):t1",
            agentStatus: .unknown,
            focused: false,
            label: label,
            number: 1,
            paneCount: 1,
            tabCount: 1,
            workspaceID: id,
            worktree: WorkspaceWorktreeInfo(
                checkoutPath: "/workspace/\(repo)",
                isLinkedWorktree: isLinkedWorktree,
                repoKey: "\(repoRoot)/.git",
                repoName: repo,
                repoRoot: repoRoot))
    }
}
