import Testing

@testable import Waycar

struct ShellForegroundTests {
    private static func process(
        _ pid: Int, _ name: String, argv: [String]? = nil, argv0: String? = nil,
        cmdline: String? = nil
    ) -> PaneProcessInfoProcess {
        PaneProcessInfoProcess(name: name, pid: pid, argv: argv, argv0: argv0, cmdline: cmdline)
    }

    private static func info(
        shell: Int? = 100, group: Int? = 200, _ processes: [PaneProcessInfoProcess]? = nil
    ) -> PaneProcessInfo {
        PaneProcessInfo(
            paneID: "w1:p1", foregroundProcessGroupID: group, foregroundProcesses: processes,
            shellPid: shell)
    }

    @Test func idleLoginZsh() {
        let i = Self.info(group: 100, [Self.process(100, "zsh", argv: ["-zsh"])])
        #expect(ShellForeground.activity(i) == .idle)
    }

    @Test func missingIDsAreUnknown() {
        #expect(ShellForeground.activity(Self.info(group: nil, [Self.process(1, "zsh")])) == nil)
        #expect(ShellForeground.activity(Self.info(shell: nil, [Self.process(1, "zsh")])) == nil)
    }

    @Test func noProcesses() {
        #expect(ShellForeground.activity(Self.info(group: 100, [])) == .idle)
        #expect(ShellForeground.activity(Self.info(group: 200, nil)) == nil)
    }

    @Test func runningSleep() {
        let i = Self.info([Self.process(200, "sleep", argv: ["sleep", "3"])])
        #expect(ShellForeground.activity(i) == .running(command: "sleep 3"))
    }

    @Test func pipelineUsesLeaderEvenWhenNotFirst() {
        let i = Self.info([
            Self.process(150, "cat", argv: ["cat"]),
            Self.process(200, "sleep", argv: ["sleep", "3"]),
        ])
        #expect(ShellForeground.activity(i) == .running(command: "sleep 3"))
    }

    @Test(arguments: [
        ["bash", "--norc", "-i"], ["zsh", "-l"], ["bash", "-o", "vi"], ["/bin/zsh"],
    ])
    func interactiveShellsAreIdle(argv: [String]) {
        let name = ShellCommand.normalized(argv[0])
        let i = Self.info([Self.process(200, name, argv: argv)])
        #expect(ShellForeground.activity(i) == .idle)
    }

    @Test(arguments: [
        ["bash", "deploy.sh"], ["bash", "-c", "make"], ["sh", "-lc", "x"], ["bash", "--", "s.sh"],
        ["fish", "--command=sleep 9"],
    ])
    func shellsRunningCommandsAreRunning(argv: [String]) {
        let i = Self.info([Self.process(200, argv[0], argv: argv)])
        #expect(ShellForeground.activity(i) == .running(command: argv.joined(separator: " ")))
    }

    @Test func execReplacingShellIsRunning() {
        let i = Self.info(group: 100, [Self.process(100, "sleep", argv: ["sleep", "3"])])
        #expect(ShellForeground.activity(i) == .running(command: "sleep 3"))
    }

    @Test func fallsBackToCmdlineThenName() {
        let withCmdline = Self.info([Self.process(200, "make", cmdline: "make  all")])
        #expect(ShellForeground.activity(withCmdline) == .running(command: "make all"))
        let nameOnly = Self.info([Self.process(200, "/usr/bin/top")])
        #expect(ShellForeground.activity(nameOnly) == .running(command: "/usr/bin/top"))
    }

    @Test func linuxTruncatedCommUsesArgv() {
        let i = Self.info([
            Self.process(200, "unattended-upgr", argv: ["/usr/bin/unattended-upgrade", "-d"])
        ])
        #expect(ShellForeground.activity(i) == .running(command: "/usr/bin/unattended-upgrade -d"))
    }

    @Test func runningCommandStripsControlsAndBidi() {
        #expect(
            ShellActivity.runningCommand("\u{1B}[31mls\u{202E} \u{2066}-la\u{85}\u{200F}")
                == .running(command: "[31mls -la"))
    }

    @Test func runningCommandCollapsesWhitespace() {
        #expect(ShellActivity.runningCommand("  sudo \t apt\n update  ") == .running(command: "sudo apt update"))
    }

    @Test func runningCommandCapsAtEightyGraphemes() {
        let long = String(repeating: "é", count: 100)
        #expect(ShellActivity.runningCommand(long) == .running(command: String(repeating: "é", count: 80) + "…"))
        let exact = String(repeating: "a", count: 80)
        #expect(ShellActivity.runningCommand(exact) == .running(command: exact))
    }

    @Test func runningCommandEmptyIsNil() {
        #expect(ShellActivity.runningCommand(" \u{0} \u{200E}\t") == nil)
        #expect(ShellActivity.runningCommand("") == nil)
    }

    @Test func shellNames() {
        #expect(ShellCommand.isShell("-bash"))
        #expect(ShellCommand.isShell("/bin/zsh"))
        #expect(!ShellCommand.isShell("sleep"))
    }

    @Test(arguments: [
        ["bash", "--rcfile", "/tmp/rc"], ["fish", "-C", "set x"], ["bash", "-C"],
        ["bash", "--rcfile=/tmp/rc"],
    ])
    func shellOptionValuesAreNotOperands(argv: [String]) {
        let i = Self.info([Self.process(200, argv[0], argv: argv)])
        #expect(ShellForeground.activity(i) == .idle)
    }

    @Test func subshellLeaderReportsItsCommand() {
        let i = Self.info([
            Self.process(200, "-zsh", argv: ["-zsh"]),
            Self.process(250, "make", argv: ["make"]),
        ])
        #expect(ShellForeground.activity(i) == .running(command: "make"))
    }

    @Test func nestedShellAloneIsIdle() {
        let i = Self.info([Self.process(200, "bash", argv: ["bash"])])
        #expect(ShellForeground.activity(i) == .idle)
    }

    @Test func unsanitizableCommandIsUnknown() {
        let empty = Self.info([Self.process(200, "", argv: [], cmdline: "")])
        #expect(ShellForeground.activity(empty) == nil)
        #expect(ShellForeground.activity(Self.info([Self.process(200, "\u{202E}")])) == nil)
    }

    @Test func runningCommandStripsFormatScalars() {
        let raw = "a\u{061C}b\u{200B}c\u{FEFF}"
        #expect(ShellActivity.runningCommand(raw) == .running(command: "abc"))
    }

    @Test func runningCommandBoundsCombiningMarks() {
        let raw = "e" + String(repeating: "\u{0301}", count: 10_000)
        guard case .running(let command)? = ShellActivity.runningCommand(raw) else {
            Issue.record("expected running")
            return
        }
        #expect(command.unicodeScalars.count <= 3)
    }
}
