import Foundation
import Synchronization
import Testing
import WaycarSSH

@testable import Waycar

/// Screens below are captures from live tmux panes (Claude Code 2.1.287,
/// Codex CLI 0.159.3, opencode 1.18.34), trimmed to the rows that matter.
@Suite("tmux screen detection")
struct TmuxScreenDetectorTests {
    // MARK: Claude Code

    static let rule = String(repeating: "─", count: 60)

    static func claudeBox(above: [String], draft: String = "") -> String {
        (above + [
            rule, "❯ \(draft)", rule,
            "  Opus 5.5 (medium) | io: 52.6k | 5% of 1000k",
            "  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents",
        ]).joined(separator: "\n") + "\n\n\n"
    }

    static let claudeTrust = """

        \(rule)
         Accessing workspace:

         /private/tmp/project

         Quick safety check: Is this a project you created or one you trust? (Like your own code, a well-known open source
         project, or work from your team). If not, take a moment to review what's in this folder first.

         ❯ No, exit
           Yes, I trust this folder

         Enter to confirm · Esc to cancel



        """

    static let claudePermission = """
        ❯ Run the shell command: touch x.txt
        ⏺ Creating empty file x.txt
          ⎿  $ touch x.txt
        \(rule)
         Bash command
         Create empty file x.txt
        ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
         touch x.txt
        ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
         Do you want to proceed?
         ❯ 1. Yes
           2. Yes, and always allow access to /tmp/project from this project
           3. No
         Esc to cancel · Tab to amend
        """

    static let claudeQuestion = """
        ❯ Use your AskUserQuestion tool to ask me whether I prefer red or blue.
        \(rule)
         ☐ Color
        Do you prefer red or blue?
        ❯ 1. Red
             You prefer red.
          2. Blue
             You prefer blue.
          3. Type something.
        \(rule)
          4. Chat about this
        Enter to select · ↑/↓ to navigate · Esc to cancel
        """

    static let claudeMCPInput = """
        ⏺ Asking the tracker for a project
        \(rule)
         MCP server "tracker" requests your input
         Which project?
         ❯ Accept
           Decline
         Esc to cancel
        """

    @Test(arguments: [
        ("trust dialog", claudeTrust),
        ("older trust dialog", """
            \(rule)
             Do you trust the files in this folder?
             /home/me/project
             ❯ 1. Yes, proceed
               2. No, exit
             Enter to confirm · Esc to exit
            """),
        ("permission prompt", claudePermission),
        ("question", claudeQuestion),
        ("MCP input request", claudeMCPInput),
    ])
    func claudeDialogsAreBlocked(name: String, screen: String) {
        #expect(TmuxScreenDetector.classify(kind: "claude", screen: screen, title: "✳ Claude Code")
            == .blocked, "\(name)")
    }

    @Test func claudeActivityLineIsWorkingWhateverTheTitle() {
        let screen = Self.claudeBox(above: [
            "❯ Run this exact shell command in the foreground: sleep 25",
            "⏺ Waiting 25 seconds",
            "  ⎿  $ sleep 25",
            "· Marinating… (5s · ↓ 198 tokens · thinking)",
            "  ⎿  Tip: Run claude --continue or claude --resume to resume a conversation",
        ])
        #expect(TmuxScreenDetector.classify(kind: "claude", screen: screen, title: "✳ Claude Code")
            == .working)
        let older = Self.claudeBox(above: ["❯ fix it", "✻ Thinking… (esc to interrupt)"])
        #expect(TmuxScreenDetector.classify(kind: "claude", screen: older, title: "") == .working)
    }

    @Test func claudeStreamingTextIsUnsure() {
        // Claude hides its activity line while it streams text: the box under
        // the text is no idle signal.
        let screen = Self.claudeBox(above: [
            "❯ Write a 1500-word essay on terminal multiplexers.",
            "⏺ There were partial fixes early on. The nohup command makes a process ignore SIGHUP.",
            "  Shells added disown to detach a job from the shell's job table.",
        ])
        #expect(TmuxScreenDetector.classify(kind: "claude", screen: screen, title: "") == nil)
    }

    @Test(arguments: [
        ("turn summary", [
            "❯ Run the shell command: sleep 30 ; then reply with just ok.",
            "⏺ ok",
            "✻ Crunched for 1s · done 3:24 PM",
            "                  tmux focus-events off · add 'set -g focus-events on' to ~/.tmux.conf",
            "                                                       ◐ medium · /effort",
        ]),
        ("interrupted while streaming", [
            "❯ Write an essay.",
            "⏺ The trouble starts when the terminal goes away.",
            "  There",
            "  ⎿  Interrupted · What should Claude do instead?",
        ]),
        ("interrupted at a permission prompt", [
            "❯ Run the shell command: touch x.txt",
            "  Ran 1 shell command",
            "  ⎿  Interrupted · What should Claude do instead?",
            "✻ Cogitated for 2s · done 3:27 PM",
        ]),
        ("welcome screen", [
            " ▐▛███▛█   Claude Code v2.1.287",
            "▝▜██████▀  Opus 5.5 · Claude Max",
            " ▝▝   ▝▝   /private/tmp/project",
        ]),
    ])
    func claudeIdleNeedsATurnEnd(name: String, above: [String]) {
        let screen = Self.claudeBox(above: above, draft: "Try \"how do I log an error?\"")
        #expect(TmuxScreenDetector.classify(kind: "claude", screen: screen, title: "") == .idle,
            "\(name)")
    }

    @Test func claudeDialogWordsInTheTranscriptAreNotADialog() {
        let screen = Self.claudeBox(above: [
            "❯ Why does it say Do you want to proceed? Esc to cancel · Enter to confirm",
            "⏺ That is Claude's permission prompt.",
            "✻ Baked for 3s · done 3:25 PM",
        ])
        #expect(TmuxScreenDetector.classify(kind: "claude", screen: screen, title: "") == .idle)
    }

    @Test func claudeUnknownScreensAreUnsure() {
        // A plain shell, an overlay without the input box, and an activity
        // label that is not a running spinner.
        let shell = "me@host:~$ ls\nREADME.md  src\nme@host:~$\n"
        #expect(TmuxScreenDetector.classify(kind: "claude", screen: shell, title: "zsh") == nil)
        let overlay = "  Showing detailed transcript · ctrl+o to toggle\n⏺ Read 3 files\n"
        #expect(TmuxScreenDetector.classify(kind: "claude", screen: overlay, title: "") == nil)
        let waiting = Self.claudeBox(above: ["❯ go", "✻ Waiting for 2 background agents to finish"])
        #expect(TmuxScreenDetector.classify(kind: "claude", screen: waiting, title: "") == nil)
    }

    // MARK: Codex

    static let codexFooter = [
        "                                                     ⚠ monthly limit: 16% left · /status",
        "› Ask Codex to do anything",
        "  GPT-6-Luna low · /private/tmp/project · Run sleep command",
        "  ← for agents · ? for shortcuts                                 ⚠ 5 warnings · f2 to view",
    ]

    static func codex(_ above: [String]) -> String {
        (["  >_ OpenAI Codex (v0.159.3)", "     /private/tmp/project"] + above + codexFooter)
            .joined(separator: "\n") + "\n"
    }

    static let codexQuestion = """
        › Plan a tiny script. Before planning, ask me: red or blue?
          Question 1/1 (1 unanswered)
          Which color should the tiny script use: red or blue?
          › 1. Red                Use red as the script's selected color.
            2. Blue               Use blue as the script's selected color.
            3. None of the above  Optionally, add details in notes (tab)
          tab to add notes | enter to submit answer | esc to interrupt
        """

    @Test(arguments: [
        ("plan question, with its title", codexQuestion, "[ ! ] Action Required | project"),
        ("plan question, title not yet set", codexQuestion, "project"),
        ("folder trust", """
              Folder access
              /private/tmp/project
              Trust this folder? Codex can read, edit, and run files here, subject to your permission settings.
            › 1. Trust and continue
              2. Back to Agent Command Center
              enter continue · esc back
            """, "host"),
        ("older folder trust", """
            > You are in /home/me/project
              Do you trust the contents of this directory? Working with untrusted contents comes with higher risk.
            › 1. Yes, continue
              2. No, quit
              Press enter to continue
            """, "host"),
        ("command approval", """
            › Run curl -sI https://example.com
              Would you like to run the following command?
              $ curl -sI https://example.com
            › 1. Yes, proceed (y)
              2. No, and tell Codex what to do differently (esc)
              Press enter to confirm or esc to cancel
            """, "project"),
        ("y/n question", """
            › Install the dependencies
            • Running npm install
              Proceed with installation? [y/n]
            """, "project"),
    ])
    func codexQuestionsAndApprovalsAreBlocked(name: String, screen: String, title: String) {
        #expect(TmuxScreenDetector.classify(kind: "codex", screen: screen, title: title) == .blocked,
            "\(name)")
    }

    @Test func codexStatusLineIsWorking() {
        let screen = Self.codex([
            "› Run the shell command: sleep 20 ; then reply ok",
            "• I’ll run the requested 20-second pause, then confirm.",
            "• Working (10s • esc to interrupt) · 1 background terminal running · /ps to view",
        ])
        #expect(TmuxScreenDetector.classify(kind: "codex", screen: screen, title: "⠇ project")
            == .working)
    }

    @Test(arguments: [
        ("after a turn", [
            "› Run exactly this shell command: touch x.txt",
            "• Ran touch x.txt",
            "  └ (no output)",
            "• The command succeeded.",
            "  Worked for 5s • 3:29 PM",
        ]),
        ("after Esc", [
            "› Run the shell command: sleep 20 ; then reply ok",
            "• I’ll run the requested 20-second pause, then confirm.",
            "■ Conversation interrupted - use /feedback if something went wrong",
            "  1 background terminal running · /ps to view · /stop to close",
        ]),
        ("fresh", ["  Your move, teammate."]),
    ])
    func codexComposerWithoutStatusLineIsIdle(name: String, above: [String]) {
        // Codex's title spins while it is idle: never a working signal.
        #expect(TmuxScreenDetector.classify(kind: "codex", screen: Self.codex(above), title: "⠸ | project")
            == .idle, "\(name)")
    }

    @Test func codexUnknownScreensAreUnsure() {
        let picker = """
              Select Model and Effort
            › 1. GPT-6-Luna (default)  Fast and affordable model for easier tasks.
              2. GPT-5.5               Legacy coding model.
              enter select · esc back
            """
        #expect(TmuxScreenDetector.classify(kind: "codex", screen: picker, title: "project") == nil)
        #expect(TmuxScreenDetector.classify(kind: "codex", screen: "loading…\n", title: "") == nil)
    }

    // MARK: opencode

    static let opencodeHome = [
        "                     █▀▀█ █▀▀█ █▀▀█ █▀▀▄ █▀▀▀ █▀▀█ █▀▀█ █▀▀█",
        "                     ▀▀▀▀ █▀▀▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀",
        "   ┃",
        "   ┃  Ask anything… \"What is the tech stack of this project?\"",
        "   ┃",
        "   ┃  Build · apodex/apodex-1.1-mini:free OpenRouter",
        "   ╹" + String(repeating: "▀", count: 74),
        "                                                   tab agents  ctrl+p commands",
        "        ● Tip Start a message with ! to run shell commands (e.g., !ls -la)",
        "  ~/proj:master                                                        1.18.34",
    ]

    /// `opencode --session <id>`'s first frame: the input box before the
    /// transcript loads.
    static let opencodeSession = [
        "  ┃",
        "  ┃",
        "  ┃",
        "  ┃  Build · apodex/apodex-1.1-mini:free OpenRouter",
        "  ╹" + String(repeating: "▀", count: 75),
        "   /home/waycar/proj                               tab agents  ctrl+p commands",
    ]

    // MARK: Antigravity (agy 1.3.3, inline; agy.md)

    static let agyRule = String(repeating: "─", count: 60)
    static let agyFooterModel = "                                        Gemini 3.1 Pro · low"
    static let agyHeader = [
        "waycar@harness-lab:~/work/demo$ agy",
        "      ▄▀▀▄        Antigravity CLI 1.3.3",
        "     ▀▀▀▀▀▀       Gemini API key",
        "  ▄▀▀      ▀▀▄",
    ]

    static let agyIdle = (agyHeader + [
        agyRule, ">", agyRule, "? for shortcuts" + agyFooterModel,
    ]).joined(separator: "\n")

    static let agyWorking = (agyHeader + [
        agyRule, "> hello WAYCAR probeone", "⣽  Generating...", agyRule, ">", agyRule,
        "esc to cancel" + agyFooterModel,
    ]).joined(separator: "\n")

    static let agyBlocked = [
        "> run WAYCAR_TOOL now",
        "● Ran (echo waycar-tool-ok) (ctrl+o to expand)",
        "Command",
        agyRule,
        "Requesting permission for:",
        "   echo waycar-tool-ok",
        "Run this command?",
        "> 1. Yes, run command",
        "  2. Yes, and always allow in this conversation for commands that start with 'echo'",
        "  4. No, cancel",
        "  ↑/↓ Navigate · tab Amend · ctrl+g edit/expand command",
        "esc to cancel" + agyFooterModel,
    ].joined(separator: "\n")

    /// After `4. No, cancel` (and after Esc mid-turn): no hook fires, the
    /// pane is back at its prompt.
    static let agyDenied = (agyHeader + [
        agyRule, "> deny WAYCAR_TOOL test",
        "● Ran (echo waycar-tool-ok) failed (ctrl+o to expand)",
        "Command",
        "  ⎿  User declined the tool call",
        "  ⎿  Interrupted · What should Antigravity CLI do instead?",
        agyRule, ">", agyRule, "? for shortcuts" + agyFooterModel,
    ]).joined(separator: "\n")

    @Test func agyScreens() {
        #expect(TmuxScreenDetector.classify(kind: "agy", screen: Self.agyBlocked, title: "") == .blocked)
        #expect(TmuxScreenDetector.classify(kind: "agy", screen: Self.agyWorking, title: "") == .working)
        #expect(TmuxScreenDetector.classify(kind: "agy", screen: Self.agyIdle, title: "") == .idle)
        #expect(TmuxScreenDetector.classify(kind: "agy", screen: Self.agyDenied, title: "") == .idle)
        // herdr's question dialog footer.
        let question = "  Which color?\n  ↑/↓ Navigate · enter Select · esc Skip\nesc to cancel"
        #expect(TmuxScreenDetector.classify(kind: "agy", screen: question, title: "") == .blocked)
        // The first-run login screen is no status at all.
        #expect(TmuxScreenDetector.classify(
            kind: "agy", screen: AgentScreenTests.screen(AgentScreenTests.agyFirstRun), title: "")
            == nil)
    }

    // MARK: Cline (3.0.70, alternate screen; cline.md)

    static let clineRule = String(repeating: "─", count: 60)
    static let clineFooter = [
        " mock-model (5,441) $0.00                              ○ Plan ● Act (Tab)",
        " demo (main)",
        " ▶▶ Auto-approve all enabled (Shift+Tab)",
    ]

    static let clineWorking = ([
        " ❯ hello WAYCAR turn one", " ⠋ Thinking... (esc to cancel)", clineRule,
        "❯ Ask anything...", clineRule,
    ] + clineFooter).joined(separator: "\n")

    static let clineDone = ([
        " ❯ hello WAYCAR turn one", " * waycar-mock-reply: one", clineRule, "❯ Ask anything...",
        clineRule,
    ] + clineFooter).joined(separator: "\n")

    /// `--auto-approve false`: the approval below a still-spinning row.
    static let clineBlocked = [
        " ❯ please run WAYCAR_TOOL now",
        " ⠼ Thinking... (esc to cancel)",
        " Cline needs permission",
        " Approve tool call?",
        " run_commands",
        "   $ echo waycar-tool-ok",
        "  [y] Approve   [n] Deny",
        " mock-model (5,442) $0.00                              ○ Plan ● Act (Tab)",
        " demo (main)",
        " Auto-approve all disabled (Shift+Tab)",
    ].joined(separator: "\n")

    /// cline's question dialog, shaped on herdr's `cline.toml` as the
    /// Host's approval watch reads it (`plugin/test/approval-watch.test.js`).
    static let clineQuestion = [
        " Cline is asking a question",
        " Which colour should the theme use?",
        " > Use the colour from the brand guide",
        "   Pick a new one",
    ] + clineFooter

    @Test func clineScreens() {
        #expect(TmuxScreenDetector.classify(kind: "cline", screen: Self.clineBlocked, title: "")
            == .blocked)
        #expect(TmuxScreenDetector.classify(kind: "cline", screen: Self.clineWorking, title: "")
            == .working)
        #expect(TmuxScreenDetector.classify(kind: "cline", screen: Self.clineDone, title: "") == .idle)
        #expect(TmuxScreenDetector.classify(
            kind: "cline", screen: AgentScreenTests.screen(Self.clineQuestion), title: "") == .blocked)
        #expect(TmuxScreenDetector.classify(
            kind: "cline", screen: AgentScreenTests.screen(AgentScreenTests.clineReady), title: "")
            == .idle)
        // Blank while the TUI starts: unsure, not herdr's working fallback.
        #expect(TmuxScreenDetector.classify(kind: "cline", screen: "\n\n", title: "") == nil)
    }

    // MARK: Kiro (UNVERIFIED live: shaped on herdr's kiro.toml 2026.09.19.1)

    @Test func kiroScreensFollowHerdrsManifest() {
        let idle = "  Welcome back\n\n> ask a question or describe a task ↵"
        #expect(TmuxScreenDetector.classify(kind: "kiro", screen: idle, title: "") == .idle)
        let approval = [
            "  Tool: shell  echo waycar-tool-ok",
            "> allow", "  always allow", "  deny", "  always deny",
            "esc to close · ↑↓ to navigate",
        ].joined(separator: "\n")
        #expect(TmuxScreenDetector.classify(kind: "kiro", screen: approval, title: "") == .blocked)
        let question = "  Pick one\n> red\n  blue\n↑↓ to navigate · enter to submit · esc to cancel"
        #expect(TmuxScreenDetector.classify(kind: "kiro", screen: question, title: "") == .blocked)
        let working = "  thinking\n kiro is working · type to steer · ctrl+s to queue"
        #expect(TmuxScreenDetector.classify(kind: "kiro", screen: working, title: "") == .working)
        #expect(TmuxScreenDetector.classify(kind: "kiro", screen: "  output", title: "◐ kiro: demo")
            == .working)
        // The sign-in screen is no status.
        #expect(TmuxScreenDetector.classify(
            kind: "kiro", screen: AgentScreenTests.screen(AgentScreenTests.kiroSignIn), title: "")
            == nil)
    }

    /// herdr's `modify_request_approval`: the dialog closes the screen.
    /// Left in the inline transcript with anything after it, it is no
    /// approval, and reading such a screen stays quick: herdr's regex for
    /// it backtracked for minutes in Swift Regex on a dialog this size.
    @Test func kiroModifyRequestDialogMustCloseTheScreen() {
        let rule = String(repeating: "─", count: 40)
        let dialog = [
            "  earlier output",
            rule,
            "  shell requires approval · modify request",
            "  rm -rf build && make all, then run the tests",
            "  another body row of the dialog, also long",
            "",
            "› yes, run it",
            "  a row after the input",
            rule,
            "  esc to close",
        ]
        #expect(TmuxScreenDetector.classify(
            kind: "kiro", screen: dialog.joined(separator: "\n"), title: "") == .blocked)
        // No input row, a rule inside, or no rule above the header.
        var noInput = dialog
        noInput[6] = "  yes, run it"
        var ruleInside = dialog
        ruleInside[4] = "  -----"
        var noRuleAbove = dialog
        noRuleAbove[1] = "  text"
        for screen in [noInput, ruleInside, noRuleAbove] {
            #expect(TmuxScreenDetector.classify(
                kind: "kiro", screen: screen.joined(separator: "\n"), title: "") == nil)
        }

        let left = Array(dialog.prefix(7))
            + (1...6).map { "  the turn goes on, reply row \($0) with some words in it" }
        let started = ContinuousClock.now
        #expect(TmuxScreenDetector.classify(
            kind: "kiro", screen: left.joined(separator: "\n"), title: "") == nil)
        #expect(started.duration(to: .now) < .seconds(1))
    }

    // MARK: Copilot (live, Copilot CLI 1.0.96 in the harness lab, tmux 3.4)

    static let copilotBoxWidth = 98

    static func copilotBox(_ rows: [String]) -> [String] {
        let rule = String(repeating: "─", count: copilotBoxWidth)
        return ["╭" + rule + "╮"]
            + rows.map { "│ " + $0.padding(toLength: copilotBoxWidth - 2, withPad: " ", startingAt: 0) + " │" }
            + ["╰" + rule + "╯"]
    }

    static let copilotSessionInUse = [
        " ● IDE auto-connect skipped: session is already in use by another client      ┃",
        "                                                                               ┃",
    ] + copilotBox([
        "Session in use",
        String(repeating: "─", count: 96),
        "This session was last active just now and appears to be in use by another CLI or application.",
        "Resuming it here may cause conflicts.",
        "",
        "❯ 1. Resume anyway",
        "  2. Go back (Esc)",
        "",
        "↑/↓ to navigate · enter to select · esc to cancel",
    ])

    static let copilotToolApproval = [" $ Shell Waycar mock check"] + copilotBox([
        "Waycar mock check",
        "Do you want to run this command?",
        "",
        "❯ 1. Yes",
        "  2. Yes, and don't ask again for `touch` in this repo (~/work/demo)",
        "  3. No, and tell Copilot what to do differently (Esc to stop)",
        "",
        "↑/↓ to navigate · enter to select · esc to cancel",
    ])

    static let copilotIdle = [
        " ● waycar-mock-reply: hi",
        " ~/work/demo [⎇ main%]",
        String(repeating: "─", count: 100),
        "❯",
        String(repeating: "─", count: 100),
        " ← open sidebar · Interactive · Manual Approval · / commands · ? help · tab next tab     mock-model",
    ]

    /// Enter would pick the marked option of a box closing the screen;
    /// the input box, or a dialog no longer at the bottom, is no status.
    @Test func copilotDialogsAreBlocked() {
        for screen in [Self.copilotSessionInUse, Self.copilotToolApproval] {
            #expect(TmuxScreenDetector.classify(
                kind: "copilot", screen: screen.joined(separator: "\n"), title: "") == .blocked)
        }
        #expect(TmuxScreenDetector.classify(
            kind: "copilot", screen: Self.copilotIdle.joined(separator: "\n"), title: "") == nil)
        #expect(TmuxScreenDetector.classify(
            kind: "copilot",
            screen: (Self.copilotToolApproval + Self.copilotIdle).joined(separator: "\n"),
            title: "") == nil)
        #expect(TmuxScreenDetector.supports(kind: "copilot"))
        #expect(!TmuxScreenDetector.readsWhileWorking(kind: "copilot"))
    }

    // MARK: Muse

    static let museRule = String(repeating: "─", count: 160)
    static let museFooter = "  mock-model · high · ~/work/demo · Auto-review"
    static let museIdle = [
        "waycar@harness-lab:~/work/demo$ muse", "", "  Muse Code 1.4.6", "",
        "❯ hello WAYCAR_TUI1", "", "◆ waycar-mock-reply: WAYCAR_TUI1", "",
        museRule, "❯", museRule, museFooter,
    ]
    static let museWorking = [
        "  Muse Code 1.4.6", "", "❯ hello WAYCAR_TUI1", "", "◇ Thinking (1s · esc to interrupt)", "",
        museRule, "❯", museRule, museFooter,
    ]
    static let museApproval = [
        "❯ please run WAYCAR_TOOL now", "", "◇ Calling tools (14s · esc to interrupt)", "", museRule,
        "Would you like to run the following command?", "", "  $ echo waycar-tool-ok", "",
        "› 1. Yes, proceed (y)", "  2. No, and tell Muse Code what to do differently (esc)", "",
        "Change approval defaults in /permissions", museRule, museFooter,
    ]
    static let museTrust = [
        "waycar@harness-lab:~/work/demo$ muse", "Do you trust this workspace?",
        "Workspace: /home/waycar/work/demo", "",
        "Trusting allows project-local skills, rules, hooks, and plugin config to load before the model runs.",
        "Only trust this workspace when you trust its contents.", "> 1  Trust and continue", "  2  Quit", "",
        "Use Up/Down or 1/2, then Enter. Esc quits.", "", "", "",
    ]

    /// The live Muse Code 1.4.6 screens (muse.md §10): the approval keeps
    /// the activity row above it and the composer stays under a running
    /// turn, so blocked goes before working and working before idle.
    @Test func museScreensClassify() {
        func classify(_ rows: [String]) -> AgentStatus? {
            TmuxScreenDetector.classify(kind: "muse", screen: rows.joined(separator: "\n"), title: "")
        }
        #expect(classify(Self.museApproval) == .blocked)
        #expect(classify(Self.museTrust) == .blocked)
        #expect(classify(Self.museWorking) == .working)
        #expect(classify(Self.museIdle) == .idle)
        // A shell, or a reply quoting the activity text, is no status.
        #expect(classify(["waycar@harness-lab:~/work/demo$ muse"]) == nil)
        #expect(classify(["◆ it said (1s · esc to interrupt)", "$ "]) == nil)
        #expect(TmuxScreenDetector.supports(kind: "muse"))
        #expect(!TmuxScreenDetector.readsWhileWorking(kind: "muse"))
    }

    @Test func kindsWithoutRulesAreNeverClassified() {
        #expect(!TmuxScreenDetector.supports(kind: "hermes"))
        #expect(TmuxScreenDetector.classify(
            kind: "hermes", screen: Self.claudeTrust, title: "Action Required") == nil)
    }

    // MARK: Folder-trust dialogs (live, harness lab, tmux 3.4, 2026-10-12)

    /// Claude Code 2.1.296 in an untrusted folder; Enter picks the marked "No, exit".
    static let claudeTrust2296 = [
        "────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────",
        " Accessing workspace:",
        "",
        " /home/waycar/trustsweep/claude.cjYT",
        "",
        " Quick safety check: Is this a project you created or one you trust? (Like your own code, a well-known open source",
        " project, or work from your team). If not, take a moment to review what's in this folder first.",
        "",
        " Claude Code'll be able to read, edit, and execute files here.",
        "",
        " Security guide",
        "",
        " ❯ No, exit",
        "   Yes, I trust this folder",
        "",
        " Enter to confirm · Esc to cancel",
    ]

    /// Codex CLI 0.162.1 in an untrusted git checkout.
    static let codexTrust1621 = [
        "  Folder access",
        "  /home/waycar/trustsweep/codex.S0hW",
        "",
        "  Trust this folder? Codex can read, edit, and run files here, subject to your permission settings. Folder settings",
        "  can run code automatically, even without a model request. Continue only if you trust these files. Your trust",
        "  decision will be saved.",
        "",
        "› 1. Trust and continue",
        "  2. Back to Agent Command Center",
        "",
        "  enter continue · esc back",
    ]

    /// Copilot CLI 1.0.95 in an untrusted folder.
    static let copilotTrust = [
        "",
        "╭──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────╮",
        "│ Confirm folder trust                                                                                                 │",
        "│ ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────── │",
        "│ ╭──────────────────────────────────────────────────────────────────────────────────────────────────────────────────╮ │",
        "│ │ /home/waycar/trustsweep/copilot.lSM5                                                                             │ │",
        "│ ╰──────────────────────────────────────────────────────────────────────────────────────────────────────────────────╯ │",
        "│                                                                                                                      │",
        "│ Copilot can read files in this folder and, with your permission, edit them or run code and shell commands. It will   │",
        "│ remember your permissions for the rest of this session.                                                              │",
        "│                                                                                                                      │",
        "│ Do you trust the files in this folder?                                                                               │",
        "│                                                                                                                      │",
        "│ ❯ 1. Yes                                                                                                             │",
        "│   2. Yes, and remember this folder for future sessions                                                               │",
        "│   3. No (Esc)                                                                                                        │",
        "│                                                                                                                      │",
        "│ ↑/↓ to navigate · enter to select · esc to cancel                                                                    │",
        "╰──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────╯",
    ]

    /// Antigravity 1.3.3 in an untrusted folder.
    static let agyTrust = [
        "Accessing workspace:",
        "",
        "/home/waycar/trustsweep/agy.3vB7",
        "",
        "Do you trust the contents of this project?",
        "",
        "Antigravity CLI requires permission to read, edit, and execute files here.",
        "",
        "> Yes, I trust this folder",
        "  No, exit",
        "",
        "  ↑/↓ Navigate · enter Confirm",
        "                                                                                                    Gemini 3.1 Pro · low",
    ]

    /// Every lab kind that opens on a folder-trust dialog in an untrusted
    /// checkout, captured before any hook fired: Blocked, since Enter
    /// answers it (claude 2.1.296's Enter even picks "No, exit").
    @Test(arguments: [
        ("claude", TmuxScreenDetectorTests.claudeTrust2296),
        ("codex", TmuxScreenDetectorTests.codexTrust1621),
        ("copilot", TmuxScreenDetectorTests.copilotTrust),
        ("agy", TmuxScreenDetectorTests.agyTrust),
        ("grok", AgentScreenTests.grokTrust),
        ("gemini", AgentScreenTests.geminiTrust),
        ("qwen", AgentScreenTests.qwenTrust),
    ])
    func liveTrustDialogsAreBlocked(kind: String, rows: [String]) {
        #expect(TmuxScreenDetector.supports(kind: kind))
        #expect(TmuxScreenDetector.classify(
            kind: kind, screen: rows.joined(separator: "\n"), title: "") == .blocked)
    }

    /// grok, gemini and qwen are read for their trust dialog alone: any
    /// other screen is unsure, never idle or working.
    @Test(arguments: [
        ("grok", AgentScreenTests.grokIdle),
        ("gemini", AgentScreenTests.geminiIdle),
        ("qwen", AgentScreenTests.qwenIdle),
    ])
    func trustOnlyKindsReadNothingElse(kind: String, rows: [String]) {
        #expect(TmuxScreenDetector.classify(
            kind: kind, screen: rows.joined(separator: "\n"), title: kind) == nil)
        #expect(!TmuxScreenDetector.readsWhileWorking(kind: kind))
    }

    // MARK: Scheduling

    static let timing: TmuxScreenVerdictMachine.Timing = {
        var timing = TmuxScreenVerdictMachine.Timing()
        timing.readInterval = .seconds(3)
        timing.staleWorking = .seconds(20)
        timing.panesPerTick = 2
        return timing
    }()

    static func pane(
        _ id: String, kind: String = "claude", status: String = "", seq: String = "",
        session: String = ""
    ) -> TmuxScreenVerdictMachine.Pane {
        TmuxScreenVerdictMachine.Pane(
            id: id, kind: kind, hookStatus: status, hookSeq: seq,
            baseStatus: TmuxAgentDetection.waycarStatus(status) ?? .unknown, session: session)
    }

    @Test func onlyHooklessAndStaleWorkingPanesAreRead() {
        var watch = TmuxScreenVerdictMachine()
        let start = ContinuousClock.now
        let panes = [
            Self.pane("%1", status: "idle", seq: "3"),
            Self.pane("%2"),
            Self.pane("%3", status: "working", seq: "7"),
            Self.pane("%4", kind: "hermes"),
            Self.pane("%5", status: "blocked", seq: "2"),
        ]
        #expect(watch.due(panes, now: start, timing: Self.timing).map(\.id) == ["%2"])
        // Working with no sequence change for 20 s: Esc or a plan question.
        #expect(watch.due(panes, now: start + .seconds(19), timing: Self.timing).map(\.id) == ["%2"])
        #expect(watch.due(panes, now: start + .seconds(23), timing: Self.timing).map(\.id)
            == ["%3", "%2"])
        // A new sequence restarts the window.
        var moved = panes
        moved[2] = Self.pane("%3", status: "working", seq: "8")
        #expect(watch.due(moved, now: start + .seconds(30), timing: Self.timing).map(\.id) == ["%2"])
        #expect(!watch.due(moved, now: start + .seconds(49), timing: Self.timing).map(\.id)
            .contains("%3"))
        #expect(watch.due(moved, now: start + .seconds(51), timing: Self.timing).map(\.id)
            .contains("%3"))
    }

    /// agy's, cline's and kiro's hooks report no approval: their screens
    /// are read all through a hook's `working`, never once the hook moved
    /// on to `done` or `idle`.
    @Test func approvalBlindKindsAreReadWhileWorking() {
        var watch = TmuxScreenVerdictMachine()
        let start = ContinuousClock.now
        let panes = [
            Self.pane("%1", kind: "agy", status: "working", seq: "4"),
            Self.pane("%2", kind: "cline", status: "done", seq: "9"),
        ]
        #expect(watch.due(panes, now: start, timing: Self.timing).map(\.id) == ["%1"])
        #expect(watch.due(panes, now: start + .seconds(3), timing: Self.timing).map(\.id) == ["%1"])
    }

    /// The screen overrides the hook only where it proves something: agy
    /// shows an approval while its hook still reads `working`, then its
    /// prompt after a denial, which fires no hook; the next turn's hook
    /// takes over again.
    @Test func agyScreenProvesBlockedAndIdleUnderAWorkingHook() {
        var watch = TmuxScreenVerdictMachine()
        let now = ContinuousClock.now
        let working = Self.pane("%1", kind: "agy", status: "working", seq: "4")
        _ = watch.due([working], now: now, timing: Self.timing)
        func verdict(_ screen: String) -> AgentStatus? {
            watch.record(
                TmuxScreenDetector.classify(kind: "agy", screen: screen, title: ""), for: working,
                now: now)
        }
        #expect(verdict(Self.agyWorking) == nil)
        #expect(verdict(Self.agyBlocked) == .blocked)
        #expect(verdict(Self.agyDenied) == .idle)
        let nextTurn = Self.pane("%1", kind: "agy", status: "working", seq: "5")
        _ = watch.due([nextTurn], now: now + .seconds(1), timing: Self.timing)
        #expect(watch.screenStatus(
            paneID: "%1", hookStatus: "working", hookSeq: "5", kind: "agy") == nil)
    }

    @Test func readsAreRateLimitedPerPaneAndPerTick() {
        var watch = TmuxScreenVerdictMachine()
        let start = ContinuousClock.now
        let panes = ["%1", "%2", "%3"].map { Self.pane($0) }
        #expect(watch.due(panes, now: start, timing: Self.timing).map(\.id) == ["%1", "%2"])
        // %3 waited: it goes first; %1 and %2 were read under 3 s ago.
        #expect(watch.due(panes, now: start + .seconds(1), timing: Self.timing).map(\.id) == ["%3"])
        #expect(watch.due(panes, now: start + .seconds(2), timing: Self.timing).isEmpty)
        #expect(watch.due(panes, now: start + .seconds(3), timing: Self.timing).map(\.id)
            == ["%1", "%2"])
    }

    @Test func replacingAnAgentDiscardsItsScreenVerdict() {
        var watch = TmuxScreenVerdictMachine()
        let now = ContinuousClock.now
        let claude = Self.pane("%3")
        _ = watch.due([claude], now: now, timing: Self.timing)
        #expect(watch.record(.working, for: claude, now: now) == .working)
        let copilot = Self.pane("%3", kind: "copilot")
        _ = watch.due([copilot], now: now, timing: Self.timing)
        #expect(watch.record(nil, for: copilot, now: now) == nil)
        #expect(watch.screenStatus(
            paneID: "%3", hookStatus: "", hookSeq: "", kind: "copilot") == nil)
        // A read that was already in flight for claude cannot restore it.
        #expect(watch.record(.working, for: claude, now: now) == nil)
        #expect(watch.screenStatus(
            paneID: "%3", hookStatus: "", hookSeq: "", kind: "copilot") == nil)
        #expect(watch.record(.working, for: copilot, now: now) == .working)
        let resumed = Self.pane("%3", kind: "copilot", session: "next-session")
        _ = watch.due([resumed], now: now, timing: Self.timing)
        #expect(watch.record(nil, for: resumed, now: now) == nil)
        #expect(watch.screenStatus(
            paneID: "%3", hookStatus: "", hookSeq: "", kind: "copilot",
            session: "next-session") == nil)
        #expect(watch.record(.working, for: copilot, now: now) == nil)
    }

    @Test func verdictsReportOnlyChangesAndHooksWin() {
        var watch = TmuxScreenVerdictMachine()
        let now = ContinuousClock.now
        let hookless = Self.pane("%2")
        _ = watch.due([hookless], now: now, timing: Self.timing)
        #expect(watch.record(.working, for: hookless, now: now) == .working)
        #expect(watch.record(.working, for: hookless, now: now) == nil)
        // Unsure keeps the last verdict.
        #expect(watch.record(nil, for: hookless, now: now) == nil)
        #expect(watch.record(.blocked, for: hookless, now: now) == .blocked)
        #expect(watch.screenStatus(
            paneID: "%2", hookStatus: "", hookSeq: "", kind: "claude") == .blocked)
        // A dialog that is gone falls back to what the hooks say.
        #expect(watch.record(nil, for: hookless, now: now) == .unknown)

        // A hook that moved during the read wins, and its change is no report.
        #expect(watch.record(.idle, for: hookless, now: now) == .idle)
        let hooked = Self.pane("%2", status: "working", seq: "1")
        #expect(watch.record(.idle, for: hooked, now: now) == nil)
        #expect(watch.screenStatus(
            paneID: "%2", hookStatus: "working", hookSeq: "1", kind: "claude") == nil)
        #expect(watch.screenStatus(
            paneID: "%2", hookStatus: "", hookSeq: "", kind: "claude") == nil)
        #expect(watch.due([hooked], now: now + .seconds(5), timing: Self.timing).isEmpty)
    }

    /// A pane the inventory stops listing is forgotten: listed again, it is
    /// read at once and its first verdict is a report. A pane never watched,
    /// or of a kind without rules, takes no verdict.
    @Test func aPaneNoLongerListedIsForgotten() {
        var watch = TmuxScreenVerdictMachine()
        let now = ContinuousClock.now
        let claude = Self.pane("%2")
        #expect(watch.record(.blocked, for: claude, now: now) == nil)
        _ = watch.due([claude], now: now, timing: Self.timing)
        #expect(watch.record(.blocked, for: claude, now: now) == .blocked)

        _ = watch.due([], now: now + .seconds(1), timing: Self.timing)
        #expect(watch.screenStatus(
            paneID: "%2", hookStatus: "", hookSeq: "", kind: "claude") == nil)
        #expect(watch.due([claude], now: now + .seconds(2), timing: Self.timing).map(\.id) == ["%2"])
        #expect(watch.record(.blocked, for: claude, now: now + .seconds(2)) == .blocked)

        let pi = Self.pane("%5", kind: "pi")
        #expect(watch.due([pi], now: now + .seconds(3), timing: Self.timing).isEmpty)
        #expect(watch.record(.blocked, for: pi, now: now + .seconds(3)) == nil)
    }

    // MARK: Transport

    /// A lost control link takes the screen verdicts with it.
    @Test func aLostLinkDropsTheScreenVerdicts() async throws {
        let host = ScreenHost(panes: [ScreenHost.paneRecord("%4", command: "claude")])
        host.setScreen("%4", Self.claudeTrust)
        let (transport, fake) = try await host.open()
        let events = ScreenEventLog(try await transport.subscribeToEvents([]))
        _ = try await transport.sessionSnapshot()
        #expect(await eventually {
            events.statuses.contains { $0.pane == "tmux:%4" && $0.status == "blocked" }
        })

        let channel = try #require(await fake.controlChannels.first)
        channel.lose()
        #expect(await eventually {
            let watch = await transport.screenWatch
            return watch.screenStatus(
                paneID: "%4", hookStatus: "", hookSeq: "", kind: "claude") == nil
        })
        try await transport.close()
    }

    @Test func hookedPanesAreSkippedAndAHooklessDialogIsReported() async throws {
        let host = ScreenHost(panes: [
            ScreenHost.paneRecord("%3", command: "2.1.287", agent: "claude", status: "idle", seq: "4"),
            ScreenHost.paneRecord("%4", command: "claude"),
        ])
        host.setScreen("%3", Self.claudeTrust)
        host.setScreen("%4", Self.claudeTrust)
        let (transport, fake) = try await host.open()
        let events = ScreenEventLog(try await transport.subscribeToEvents([]))
        _ = try await transport.sessionSnapshot()

        #expect(await eventually {
            events.statuses.contains { $0.pane == "tmux:%4" && $0.status == "blocked" }
        })
        #expect(host.reads.allSatisfy { $0.pane == "%4" })
        let channel = try #require(await fake.controlChannels.first)
        let line = try #require(channel.writtenLines.first { $0.hasPrefix("capture-pane") })
        #expect(line == "capture-pane -p -J -S -40 -t %4 ; display -p -t %4 '#{pane_title}'")
        // A re-snapshot shows the reported status, not the hooks' Unknown.
        let snapshot = try await transport.sessionSnapshot()
        #expect(snapshot.agents.first { $0.paneID == "tmux:%4" }?.agentStatus == .blocked)
        #expect(snapshot.agents.first { $0.paneID == "tmux:%3" }?.agentStatus == .idle)

        try await transport.close()
        let reads = host.reads.count
        try await Task.sleep(for: .milliseconds(150))
        #expect(host.reads.count == reads)
        // The verdict dies with the transport.
        let watch = await transport.screenWatch
        #expect(watch.screenStatus(
            paneID: "%4", hookStatus: "", hookSeq: "", kind: "claude") == nil)
    }

    @Test func verdictsSurviveADeliberateResubscribe() async throws {
        let host = ScreenHost(panes: [ScreenHost.paneRecord("%4", command: "claude")])
        host.setScreen("%4", Self.claudeTrust)
        let (transport, _) = try await host.open()
        let first = try await transport.subscribeToEvents([])
        let events = ScreenEventLog(first)
        _ = try await transport.sessionSnapshot()
        #expect(await eventually {
            events.statuses.contains { $0.pane == "tmux:%4" && $0.status == "blocked" }
        })

        // EventsSession resubscribes after every Agent-set change. From here
        // on every read fails, so only the kept verdict can show Blocked.
        host.removeScreen("%4")
        await first.end()
        let second = try await transport.subscribeToEvents([])
        let snapshot = try await transport.sessionSnapshot()
        #expect(snapshot.agents.first { $0.paneID == "tmux:%4" }?.agentStatus == .blocked)
        let watch = await transport.screenWatch
        #expect(watch.screenStatus(
            paneID: "%4", hookStatus: "", hookSeq: "", kind: "claude") == .blocked)

        await second.end()
        try await transport.close()
        let closedWatch = await transport.screenWatch
        #expect(closedWatch.screenStatus(
            paneID: "%4", hookStatus: "", hookSeq: "", kind: "claude") == nil)
    }

    @Test func staleWorkingPaneIsReadAndAHookChangeWins() async throws {
        let interrupted = Self.claudeBox(above: [
            "❯ Write an essay.",
            "⏺ The trouble starts when the terminal goes away.",
            "  ⎿  Interrupted · What should Claude do instead?",
        ])
        let host = ScreenHost(
            panes: [ScreenHost.paneRecord(
                "%5", command: "2.1.287", agent: "claude", status: "working", seq: "7")],
            staleWorking: .milliseconds(300))
        host.setScreen("%5", interrupted)
        let (transport, fake) = try await host.open()
        let events = ScreenEventLog(try await transport.subscribeToEvents([]))
        let channel = try #require(await fake.controlChannels.first)
        channel.push([ScreenHost.statusPush([["%5", "working", "claude", "s1", "7"]])])
        let start = ContinuousClock.now
        _ = try await transport.sessionSnapshot()

        #expect(await eventually {
            events.statuses.contains { $0.pane == "tmux:%5" && $0.status == "idle" }
        })
        let firstRead = try #require(host.reads.first { $0.pane == "%5" })
        #expect(firstRead.at - start >= .milliseconds(250))

        // The next prompt's hook moves the sequence: the hook's working wins.
        host.setPanes([ScreenHost.paneRecord(
            "%5", command: "2.1.287", agent: "claude", status: "working", seq: "8")])
        channel.push([ScreenHost.statusPush([["%5", "working", "claude", "s1", "8"]])])
        #expect(await eventually { events.kinds.contains(TmuxEvents.resyncKind) })
        let snapshot = try await transport.sessionSnapshot()
        #expect(snapshot.agents.first?.agentStatus == .working)
        let reads = host.reads.count
        try await Task.sleep(for: .milliseconds(150))
        #expect(host.reads.count == reads)
        try await transport.close()
    }

    @Test func readsAreBoundedPerPaneAndPerTick() async throws {
        let ids = (10..<16).map { "%\($0)" }
        // The poll's own timer and each pane's interval never come round
        // during the test, so the test drives every tick itself.
        let host = ScreenHost(
            panes: ids.map { ScreenHost.paneRecord($0, command: "codex") },
            readInterval: .seconds(3600), tick: .seconds(3600))
        for id in ids { host.setScreen(id, Self.codex(["  Your move, teammate."])) }
        let (transport, _) = try await host.open()
        let events = ScreenEventLog(try await transport.subscribeToEvents([]))
        _ = try await transport.sessionSnapshot()

        // Four in the first tick, the other two in the next; then none until
        // each pane's interval has passed.
        for tick in 1...3 {
            host.beginTick(tick)
            #expect(await transport.pollScreens())
        }
        let reads = host.reads
        #expect(reads.count == 6)
        #expect(Set(reads.map(\.pane)) == Set(ids))
        let perTick = Dictionary(grouping: reads) { $0.tick }.mapValues(\.count)
        #expect(perTick == [1: 4, 2: 2])
        // Each pane's verdict goes out once.
        #expect(await eventually { events.statuses.count == 6 })
        #expect(Set(events.statuses.map(\.pane)).count == 6)
        #expect(events.statuses.allSatisfy { $0.status == "idle" })
        try await transport.close()
    }
}

// MARK: - Scripted Host

/// A tmux Host with session `$1`, window `@2` and the given panes; every
/// `capture-pane` line answers that pane's scripted screen, and each read is
/// logged with its time and the tick the test labelled it with.
private final class ScreenHost: Sendable {
    struct Read: Sendable {
        let pane: String
        let at: ContinuousClock.Instant
        /// The tick the test last began with `beginTick`; 0 when it drives
        /// none.
        let tick: Int
    }

    private struct State {
        var panes: [String]
        var screens: [String: String] = [:]
        var reads: [Read] = []
        var tick = 0
    }

    private let state: Mutex<State>
    private let timing: TmuxScreenVerdictMachine.Timing

    init(
        panes: [String], staleWorking: Duration = .seconds(20),
        readInterval: Duration = .milliseconds(150), tick: Duration = .milliseconds(20)
    ) {
        state = Mutex(State(panes: panes))
        var timing = TmuxScreenVerdictMachine.Timing()
        timing.tick = tick
        timing.readInterval = readInterval
        timing.staleWorking = staleWorking
        self.timing = timing
    }

    static func paneRecord(
        _ id: String, command: String, agent: String = "", status: String = "", seq: String = ""
    ) -> String {
        let fields = [
            id, "$1", "@2", "0", "1", "0", "1", "100", "/dev/ttys001", "120", "40", command,
            status, agent, seq, "", "", "/home/me/repo", "", "", "host", "", "",
        ]
        return "\u{241E}" + fields.joined(separator: "\u{241F}")
    }

    static func statusPush(_ rows: [[String]]) -> String {
        let value = rows.map { $0.joined(separator: "\u{241F}") + "\u{241E}" }.joined()
        return "%subscription-changed \(TmuxEvents.statusName) $1 - - - : \(value)"
    }

    func setScreen(_ pane: String, _ screen: String) {
        state.withLock { $0.screens[pane] = screen }
    }

    /// Labels the reads that follow as `tick`'s.
    func beginTick(_ tick: Int) {
        state.withLock { $0.tick = tick }
    }

    /// Every later read of `pane` fails, as for a pane that went away.
    func removeScreen(_ pane: String) {
        state.withLock { $0.screens[pane] = nil }
    }

    func setPanes(_ panes: [String]) {
        state.withLock { $0.panes = panes }
    }

    var reads: [Read] { state.withLock { $0.reads } }

    func open() async throws -> (TmuxTransport, FakeHostSSHServices) {
        let fake = FakeHostSSHServices(
            exec: { command, _ in
                if command.contains("exec tmux -V") {
                    return FakeHostSSHServices.result(stdout: "tmux 3.7c\n")
                }
                if command.contains("tmux ls -F") {
                    return FakeHostSSHServices.result(stdout: "$1 off main\n")
                }
                return FakeHostSSHServices.result()
            },
            control: { [self] line in respond(line) })
        var configuration = TmuxTransport.Configuration(requestTimeout: .seconds(5))
        configuration.resyncDebounce = .milliseconds(20)
        configuration.screenWatch = timing
        let transport = try await TmuxTransport.open(session: fake, configuration: configuration)
        return (transport, fake)
    }

    private func respond(_ line: String) -> [FakeTmuxBlock] {
        if line.hasPrefix(TmuxTransport.versionFlagsCommand) {
            return [.ok(["3.7c\u{241F}no-output,no-detach-on-destroy"]), .ok([]), .ok([])]
        }
        if line.hasPrefix("list-sessions") {
            let panes = state.withLock { $0.panes }
            return [
                .ok(["\u{241E}$1\u{241F}0\u{241F}1\u{241F}main\u{241F}\u{241F}/home/me"]),
                .ok(["\u{241E}@2\u{241F}$1\u{241F}1\u{241F}1\u{241F}0\u{241F}agents"]),
                .ok(panes),
            ]
        }
        if line.hasPrefix("capture-pane") {
            let words = line.split(separator: " ").map(String.init)
            let pane = words.firstIndex(of: "-t").map { words[$0 + 1] } ?? ""
            let screen: String? = state.withLock { state in
                state.reads.append(Read(pane: pane, at: .now, tick: state.tick))
                return state.screens[pane]
            }
            guard let screen else { return [.error(["can't find pane: \(pane)"])] }
            return [
                .ok(screen.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)),
                .ok(["host"]),
            ]
        }
        return line.components(separatedBy: " ; ").map { _ in .ok([]) }
    }
}

// MARK: - Events

/// Drains one event stream; status changes as (pane id, status) pairs.
private final class ScreenEventLog: Sendable {
    private let state = Mutex<[HerdrEvent]>([])

    init(_ stream: HerdrEventStream) {
        Task { [self] in
            do {
                for try await event in stream.events {
                    state.withLock { $0.append(event) }
                }
            } catch {}
        }
    }

    var kinds: [HerdrEventKind] { state.withLock { $0.map(\.kind) } }

    var statuses: [(pane: String, status: String)] {
        state.withLock { events in
            events.compactMap { event in
                guard event.kind == PaneEventKind.agentStatusChanged.kind,
                    let pane = event.data["pane_id"]?.stringValue,
                    let status = event.data["agent_status"]?.stringValue
                else { return nil }
                return (pane: pane, status: status)
            }
        }
    }
}

/// Polls `condition` until it holds or `timeout` passes.
private func eventually(
    _ timeout: Duration = .waitCeiling, _ condition: () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}
