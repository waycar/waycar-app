import Foundation
import Testing

@testable import Waycar

@Suite("tmux agent detection")
struct TmuxAgentDetectionTests {
    private func pane(
        _ command: String, status: String = "", agent: String = "", sidebar: String = "",
        workmux: String = "", dead: Bool = false
    ) -> TmuxPaneRecord {
        TmuxPaneRecord(
            id: "%1", sessionID: "$1", windowID: "@1", dead: dead, currentCommand: command,
            waycarStatus: status, waycarAgent: agent, sidebarStatus: sidebar,
            workmuxStatus: workmux)
    }

    @Test func kindPrecedence() {
        #expect(TmuxAgentDetection.kind(for: pane("2.1.286", agent: "claude"), resolvedKind: "codex")
            == "claude")
        #expect(TmuxAgentDetection.kind(for: pane("codex"), resolvedKind: "claude") == "codex")
        #expect(TmuxAgentDetection.kind(for: pane("cursor-agent"), resolvedKind: nil) == "cursor")
        #expect(TmuxAgentDetection.kind(for: pane("2.1.286"), resolvedKind: "claude") == "claude")
        #expect(TmuxAgentDetection.kind(for: pane("vim"), resolvedKind: nil) == nil)
        #expect(TmuxAgentDetection.kind(for: pane("codex", dead: true), resolvedKind: nil) == nil)
    }

    @Test func shellIgnoresStaleWaycarOptions() {
        let stale = pane("-zsh", status: "working", agent: "claude")
        #expect(TmuxAgentDetection.kind(for: stale, resolvedKind: "claude") == nil)
        #expect(TmuxAgentDetection.status(for: stale) == .unknown)
        #expect(ShellCommand.isShell("/bin/bash"))
        #expect(ShellCommand.isShell("fish"))
        #expect(!ShellCommand.isShell("node"))
    }

    @Test(arguments: [
        ("zsh", nil, ShellActivity.idle),
        ("-bash", nil, .idle),
        ("bash", "bash -l", .idle),
        ("sudo", "sudo apt update", .running(command: "sudo apt update")),
        ("sleep", "sleep  30\n", .running(command: "sleep 30")),
        ("ssh", nil, .running(command: "ssh")),
        ("vim", "  \t ", .running(command: "vim")),
    ] as [(String, String?, ShellActivity)])
    func shellActivityOfAShell(command: String, commandLine: String?, expected: ShellActivity) {
        #expect(TmuxAgentDetection.shellActivity(
            for: pane(command), resolvedKind: nil, commandLine: commandLine) == expected)
    }

    @Test func shellActivityIsUnknownForAgentsAndDeadPanes() {
        #expect(TmuxAgentDetection.shellActivity(
            for: pane("sleep", dead: true), resolvedKind: nil, commandLine: "sleep 5") == nil)
        #expect(TmuxAgentDetection.shellActivity(
            for: pane("2.1.286", agent: "claude"), resolvedKind: nil, commandLine: nil) == nil)
        #expect(TmuxAgentDetection.shellActivity(
            for: pane("codex"), resolvedKind: nil, commandLine: "codex") == nil)
        #expect(TmuxAgentDetection.shellActivity(
            for: pane("2.1.286"), resolvedKind: "claude", commandLine: "claude") == nil)
        #expect(TmuxAgentDetection.shellActivity(
            for: pane(""), resolvedKind: nil, commandLine: nil) == nil)
    }

    @Test func foregroundCommandLineResolution() {
        #expect(AgentKindDetection.kind(commandLine: "claude --resume abc") == "claude")
        #expect(AgentKindDetection.kind(commandLine: "/usr/local/bin/codex") == "codex")
        #expect(AgentKindDetection.kind(commandLine: "node --no-warnings /opt/bin/gemini -p x")
            == "gemini")
        #expect(AgentKindDetection.kind(commandLine: "vim notes.md") == nil)
        #expect(AgentKindDetection.kind(commandLine: "") == nil)
        #expect(TmuxAgentDetection.kind(
            for: pane("2.1.286"), foregroundCommandLine: "claude") == "claude")
    }

    @Test func pythonAgentUnderAnyPythonResolves() {
        func kind(_ commandLine: String) -> String? {
            AgentKindDetection.kind(commandLine: commandLine)
        }
        // Homebrew's framework Python re-executes itself as `Python`.
        let framework = "/opt/homebrew/Cellar/python@3.12/3.12.15/Frameworks/Python.framework"
            + "/Versions/3.12/Resources/Python.app/Contents/MacOS/Python"
        #expect(kind("\(framework) /Users/me/.local/bin/hermes --tui") == "hermes")
        #expect(kind("python3.12 /usr/local/bin/hermes") == "hermes")
        #expect(kind("python3 -u /usr/local/bin/hermes") == "hermes")
        #expect(kind("pythonw /usr/local/bin/hermes") == nil)
        #expect(kind("\(framework) -m http.server") == nil)
    }

    @Test func museReleaseBinaryIsMuse() {
        // The `muse` launcher execs the release it installed; tmux shows its
        // name cut to 15 characters.
        #expect(AgentKindDetection.kind(commandLine: "/Users/me/.local/bin/muse-bin-1.4.4-R5419.1")
            == "muse")
        let release = pane("muse-bin-1.4.4-")
        #expect(TmuxAgentDetection.kind(for: release, resolvedKind: nil) == "muse")
        #expect(TmuxAgentDetection.panesNeedingForegroundResolution([release]).isEmpty)
    }

    /// `pane_current_command` and the foreground leader's `ps -o args=` of
    /// each newer kind, as the harness lab showed them (Ubuntu 24.04,
    /// 2026-10-12); the long ones are cut where `ps` printed more.
    @Test(arguments: [
        // Native binaries: the command is the executable.
        ("agy", "agy", "agy"),
        ("devin", "devin", "devin"),
        ("grok", "grok", "grok"),
        ("kiro-cli", "kiro-cli", "kiro"),
        ("cursor-agent",
         "/home/waycar/.local/bin/cursor-agent --use-system-ca "
            + "/home/waycar/.local/share/cursor-agent/versions/2026.10.01-e373342/index.js",
         "cursor"),
        // npm wrappers: `node` runs the script.
        ("node", "node /home/waycar/.npm-global/bin/cline -i --data-dir /home/waycar/.cline/data",
         "cline"),
        ("node", "node /home/waycar/.npm-global/bin/qwen", "qwen"),
        ("node", "node /home/waycar/.npm-global/bin/gemini", "gemini"),
        ("node", "node /home/waycar/.npm-global/bin/copilot", "copilot"),
        ("node", "node /home/waycar/.npm-global/bin/kilo", "kilo"),
        // Cursor's `agent` alias.
        ("agent",
         "/home/waycar/.local/bin/agent --use-system-ca "
            + "/home/waycar/.local/share/cursor-agent/versions/2026.10.01-e373342/index.js",
         "cursor"),
        // Hermes Agent's launcher: Python with its code inline.
        ("python3",
         "/home/waycar/.hermes/tools/python-3.14.7+20260901-linux-arm64/bin/python3 -I -c "
            + "import os, re, sys import contextlib, hashlib, io, pathlib, shutil, subprocess "
            + "os.environ.pop('PYTHONHOME', None) sys.path.insert(0, '/home/waycar/.hermes/hermes-agent')",
         "hermes"),
    ] as [(String, String, String)])
    func newerKindsResolveFromTheLabsProcesses(command: String, args: String, kind: String) {
        let record = pane(command)
        let resolved =
            TmuxAgentDetection.needsForegroundResolution(record)
            ? AgentKindDetection.kind(commandLine: args) : nil
        #expect(TmuxAgentDetection.kind(for: record, resolvedKind: resolved) == kind)
    }

    /// The names those launchers need claimed only with their own marks.
    @Test func genericLauncherNamesNeedTheirMarks() {
        #expect(AgentKindDetection.kind(commandLine: "/usr/local/bin/agent --serve") == nil)
        #expect(AgentKindDetection.kind(commandLine: "python3 -c print(1)") == nil)
    }

    @Test func onlyUnknownNonShellPanesNeedResolution() {
        let panes = [
            pane("2.1.286"), pane("zsh"), pane("codex"), pane("2.1.286", agent: "claude"),
            pane("htop", dead: true),
        ]
        #expect(TmuxAgentDetection.panesNeedingForegroundResolution(panes) == [pane("2.1.286")])
    }

    @Test func waycarStatusMaps() {
        #expect(TmuxAgentDetection.status(for: pane("codex", status: "working")) == .working)
        #expect(TmuxAgentDetection.status(for: pane("codex", status: "blocked")) == .blocked)
        #expect(TmuxAgentDetection.status(for: pane("codex", status: "done")) == .done)
        #expect(TmuxAgentDetection.status(for: pane("codex", status: "idle")) == .idle)
        #expect(TmuxAgentDetection.status(for: pane("codex")) == .unknown)
    }

    @Test func thirdPartyEnrichmentOnlyWithoutWaycarStatus() {
        #expect(TmuxAgentDetection.status(for: pane("codex", sidebar: "running")) == .working)
        #expect(TmuxAgentDetection.status(for: pane("codex", sidebar: "waiting")) == .blocked)
        #expect(TmuxAgentDetection.status(for: pane("codex", sidebar: "idle")) == .idle)
        #expect(TmuxAgentDetection.status(for: pane("codex", workmux: "🤖")) == .working)
        #expect(TmuxAgentDetection.status(for: pane("codex", workmux: "💬")) == .blocked)
        #expect(TmuxAgentDetection.status(for: pane("codex", workmux: "✅")) == .done)
        #expect(TmuxAgentDetection.status(
            for: pane("codex", status: "idle", sidebar: "running", workmux: "🤖")) == .idle)
    }
}
