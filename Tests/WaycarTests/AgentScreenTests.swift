import Foundation
import Testing

@testable import Waycar

/// Screens are `capture-pane` captures from the harness lab (2026-10-12),
/// trimmed to the rows that matter: kilo 7.8.8, Cline 3.0.70, cursor-agent
/// 2026.10.01-e373342, Devin 3000.11.3, kiro-cli 2.29.1, Antigravity 1.3.3,
/// grok 1.0.50, gemini 0.63.0, qwen 0.25.1 (`docs/research/harnesses/<kind>.md`).
@Suite("Agent input, sign-in and folder-trust screens")
struct AgentScreenTests {
    static let kiloReady = [
        "                                       ██  ██ ██🬺🬏   ██  ██   ██🬺🬏     ████",
        "                           ┃",
        "                           ┃  Ask anything... \"What is the tech stack of this project?\"",
        "                           ┃",
        "                           ┃  Code  · mock-model Waycar harness lab mock",
        "                           ╹" + String(repeating: "▀", count: 60),
        "                                                           tab agents  ctrl+p commands",
        "  ~/work/demo:main                                                              7.8.8",
    ]

    static let clineRule = String(repeating: "─", count: 68)

    static let clineReady = [
        "                                                        @@@@@@@@@@@@@@@@.",
        "                                                     What can I do for you?",
        "                 Use / for slash commands, @ for file mentions, Ctrl+P for menu",
        "              " + clineRule,
        "              ❯ What can I do for you?",
        "              " + clineRule,
        "               mock-model (0) $0.00                            ○ Plan ● Act (Tab)",
        "               demo (main)",
        "               ▶▶ Auto-approve all enabled (Shift+Tab)",
    ]

    static let cursorFirstScreen = [
        "",
        "                                   Cursor Agent",
        "                                   v2026.10.01-e373342",
        "                                   Press any key to log in...",
    ]

    static let cursorBrowserLink = [
        " Signing in",
        " If your browser didn't open, click this link to log in:",
        "https://cursor.com/loginDeepControl?challenge=U_0zE&mode=login&redirectTarget=cli",
        " Press q to show a QR code to log in from another device",
    ]

    /// devin 3000.11.3's first screen with no login, as the harness lab
    /// E2E read it on tmux (2026-10-12): 13 non-empty rows.
    static let devinLoginMenu = [
        "Welcome to Devin CLI!",
        "",
        "⠀⣴⣾⣶⡄⠀⠀⠀⠀",
        "⠀⠛⠿⠟⠻⣶⣾⣶⡄  Devin CLI",
        "⠀⣤⣶⣦⣴⠿⢿⠿⠃  v3000.11.3",
        "⠀⠻⢿⠿⠃⠀⠀⠀⠀",
        "", "", "",
        "How would you like to log in?",
        "",
        "❭ 1 Log in with browser",
        "    Recommended for most users",
        "  2 Paste a token manually",
        "    For SSH or remote sessions without browser access",
        "  3 Log in with Windsurf for Enterprise",
        "    For enterprise customers only",
        "",
        "↑↓ select · ↵ confirm · esc cancel",
    ]

    static let devinTokenPrompt = [
        "Welcome to Devin CLI!",
        "Visit https://app.devin.ai/auth/cli/continue?state=af0e to sign in, then copy the code and paste it below.",
        "Code:",
        "❭ Paste the code from the sign-in page",
        "↵ submit · esc cancel",
    ]

    static let kiroSignIn = [
        "waycar@harness-lab:~/work/demo$ kiro-cli",
        "",
        "Welcome to Kiro CLI, let's get you signed in!",
        "",
        "Press enter to continue to the browser or esc to cancel",
    ]

    static let agyFirstRun = [
        " ▄▀▀      ▀▀▄",
        " Welcome to the Antigravity CLI. You are currently not signed in.",
        " Select login method:",
        " > 1. Google OAuth",
        "   2. Use a Google Cloud project",
        "   ↑/↓ Navigate · enter Select",
    ]

    static func screen(_ rows: [String]) -> String { rows.joined(separator: "\n") }

    // MARK: Input markers

    @Test func barBorderedBoxMarksOpencodeAndKiloInput() {
        #expect(AgentScreen.inputIsOnScreen(.barBorderedBox, screen: Self.screen(Self.kiloReady)))
        #expect(AgentScreen.inputIsOnScreen(
            .barBorderedBox,
            screen: Self.screen(TmuxScreenDetectorTests.opencodeHome)))
        // `opencode --session <id>`'s first frame: the box before the transcript.
        #expect(AgentScreen.inputIsOnScreen(
            .barBorderedBox,
            screen: Self.screen(TmuxScreenDetectorTests.opencodeSession)))
        #expect(!AgentScreen.inputIsOnScreen(.barBorderedBox, screen: String(repeating: "\n", count: 24)))
        #expect(!AgentScreen.inputIsOnScreen(
            .barBorderedBox,
            screen: String(repeating: "\n", count: 22) + "                          ⠋ Loading plugins…\n"))
    }

    @Test func clineComposerNeedsItsRowAndFooter() {
        #expect(AgentScreen.inputIsOnScreen(.clineComposer, screen: Self.screen(Self.clineReady)))
        // The alternate screen before the TUI draws.
        #expect(!AgentScreen.inputIsOnScreen(.clineComposer, screen: String(repeating: "\n", count: 24)))
        // A shell prompt drawn with `❯` (a herdr pane read has no
        // alternate-screen flag to rule it out): no mode footer.
        #expect(!AgentScreen.inputIsOnScreen(
            .clineComposer, screen: "~/work/demo\n❯ cline -i --data-dir ~/.cline/data"))
        // The footer alone, the composer not yet drawn.
        #expect(!AgentScreen.inputIsOnScreen(
            .clineComposer, screen: Self.screen(Array(Self.clineReady.suffix(3)))))
    }

    // MARK: Sign-in screens

    @Test(arguments: [
        ("cursor", AgentScreenTests.cursorFirstScreen),
        ("cursor", AgentScreenTests.cursorBrowserLink),
        ("devin", AgentScreenTests.devinLoginMenu),
        ("devin", AgentScreenTests.devinTokenPrompt),
        ("kiro", AgentScreenTests.kiroSignIn),
        ("agy", AgentScreenTests.agyFirstRun),
        ("muse", AgentScreenTests.museLoginMenu),
        ("muse", AgentScreenTests.museDeviceLogin),
    ])
    func signInScreensAreRecognized(kind: String, rows: [String]) {
        #expect(AgentScreen.signInRequired(kind: kind, screen: Self.screen(rows)))
        #expect(!AgentScreen.signInRequired(kind: "codex", screen: Self.screen(rows)))
    }

    /// Muse Code 1.4.6 with no credentials (muse.md §12).
    static let museLoginMenu = [
        "  Muse Code 1.4.6", "", "  Log in with browser · Enter to choose", "  Set an API key", "",
        "  ↓↑ to select · Esc to quit",
    ]
    static let museDeviceLogin = [
        "  Muse Code 1.4.6", "", "  Sign in at this page:", "  https://auth.meta.com/oauth/device?user_code=ABCD",
        "", "  Waiting for approval…",
    ]

    @Test func museIdleIsNotSignIn() {
        #expect(!AgentScreen.signInRequired(
            kind: "muse", screen: Self.screen(TmuxScreenDetectorTests.museIdle)))
        #expect(AgentScreen.readiness(kind: "muse").hasSignInScreen)
    }

    @Test func workingScreensAreNotSignIn() {
        #expect(!AgentScreen.signInRequired(kind: "agy", screen: TmuxScreenDetectorTests.agyIdle))
        #expect(!AgentScreen.signInRequired(kind: "agy", screen: TmuxScreenDetectorTests.agyBlocked))
        #expect(!AgentScreen.signInRequired(kind: "cursor", screen: ""))
    }

    /// agy, devin and kiro draw their chat inline, so a reply quoting a
    /// login line sits on the screen a prompt reads: one line, or a login
    /// line inside a sentence, is no sign-in screen.
    @Test(arguments: [
        ("agy", ["> fix the banner", "The header now shows 'You are currently not signed in'.", "> "]),
        ("agy", ["Welcome to the Antigravity CLI. You are currently not signed in.", "> "]),
        ("devin", ["The CLI asks: How would you like to log in?", "❭ "]),
        ("devin", ["How would you like to log in?", "❭ "]),
        ("kiro", ["Its first screen says: Welcome to Kiro CLI, let's get you signed in!", "> "]),
        ("kiro", ["Press enter to continue to the browser or esc to cancel", "> "]),
        ("cursor", ["Press any key to log in...", "> "]),
        ("cursor", ["It prints https://cursor.com/loginDeepControl?challenge=x", "> "]),
    ])
    func quotedLoginLinesAreNotSignIn(kind: String, rows: [String]) {
        #expect(!AgentScreen.signInRequired(kind: kind, screen: Self.screen(rows)))
    }

    /// An inline login screen left above a chat once its rows are past the
    /// bottom of the screen no longer counts.
    @Test func loginRowsAboveTheChatAreNotSignIn() {
        let chat = (1...AgentScreen.signInRegionRows).map { "reply row \($0)" }
        #expect(!AgentScreen.signInRequired(kind: "kiro", screen: Self.screen(Self.kiroSignIn + chat)))
        #expect(AgentScreen.signInRequired(
            kind: "kiro", screen: Self.screen(Self.kiroSignIn + ["", "", ""])))
    }

    /// devin's screen after "Log in with browser", as the harness lab E2E
    /// read it on herdr (2026-10-12): the spinner row starts with a braille
    /// blank.
    @Test func devinBrowserWaitIsSignIn() {
        #expect(AgentScreen.signInRequired(
            kind: "devin",
            screen: Self.screen([
                "$ devin", "Welcome to Devin CLI!",
                "⠀⠇ Waiting for login in browser... · 2s",
                "Press Enter to paste a token manually instead",
            ])))
    }

    // MARK: Folder-trust dialogs (harness lab captures, 2026-10-12)

    /// grok 1.0.50 in a folder with an AGENTS.md, not yet trusted (grok.md §12).
    static let grokTrust = [
        "  ~/trustsweep/grok-agents-md.xJEz",
        "",
        "                                                     ⠀⠀⠀⠀⠀⠀⣀⣀⡀⠀⠀⠀⢀⠄",
        "                                                     ⠀⠀⠀⣠⣾⠿⠛⠛⠛⠛⢀⡴⠁⠀",
        "                                                     ⠀⠀⣼⡟⠁⠀⠀⠀⢀⡴⠻⣿⡀⠀",
        "                                                     ⠀⠀⣿⡇⠀⠀⠀⠔⠁⠀⠀⣿⡇⠀",
        "                                                     ⠀⠀⢹⣷⠀⠀⠀⠀⠀⢀⣴⡿⠀⠀",
        "                                                     ⠀⢀⠞⠁⠠⢶⣶⣶⣶⠿⠋⠀⠀⠀",
        "                                                     ⠐⠁⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀",
        "",
        "                                      Do you trust the contents of this directory?",
        "                                       /home/waycar/trustsweep/grok-agents-md.xJEz",
        "",
        "                                Grok Build may run or modify contents in this directory,",
        "                                                 posing security risks.",
        "",
        "                                             Yes, proceed                 y",
        "                                             No, quit                     n",
        "",
        "                                                                                                    Grok Build  1.0.50",
    ]

    /// gemini 0.63.0, folder trust on (its default), an untrusted git checkout (gemini.md).
    static let geminiTrust = [
        "   ▝▜▄",
        "  ▗▟▀    Authenticated with gemini-api-key /auth",
        " ▝▀",
        "",
        "ℹ Skipping project agents due to untrusted folder. To enable, ensure that the project root is trusted.",
        "",
        " ╭────────────────────────────────────────────────────────────────────────────────────────────────────────────────────╮",
        " │                                                                                                                    │",
        " │ Do you trust the files in this folder?                                                                             │",
        " │                                                                                                                    │",
        " │ Trusting a folder allows Gemini CLI to load its local configurations, including custom commands, hooks, MCP        │",
        " │ servers, agent skills, and settings. These configurations could execute code on your behalf or change the behavior │",
        " │ of the CLI.                                                                                                        │",
        " │                                                                                                                    │",
        " │                                                                                                                    │",
        " │ ● 1. Trust folder (gemini-trust.jMMS)                                                                              │",
        " │   2. Trust parent folder (trustsweep)                                                                              │",
        " │   3. Don't trust                                                                                                   │",
        " │                                                                                                                    │",
        " ╰────────────────────────────────────────────────────────────────────────────────────────────────────────────────────╯",
    ]

    /// qwen 0.25.1 with `security.folderTrust.enabled` (qwen.md).
    static let qwenTrust = [
        "  Tips: You can resume a previous conversation by running qwen --continue or qwen --resume.",
        "  ●︎ Extensions changed on disk. Run /reload-plugins to apply updates.",
        "   ╭──────────────────────────────────────────────────────────────────────────────────────────────────",
        "   │",
        "   │ Do you trust this folder?",
        "   │ Trusting a folder allows Qwen Code to execute commands it suggests. This is a security feature",
        "   │ to prevent accidental execution in untrusted directories.",
        "   │",
        "   │ › 1. Trust folder (qwen-trust.lgkn)",
        "   │   2. Trust parent folder (trustsweep)",
        "   │   3. Don't trust (esc)",
        "   │",
        "   ╰──────────────────────────────────────────────────────────────────────────────────────────────────",
    ]

    /// grok 1.0.50 ready for input.
    static let grokIdle = [
        "",
        "  ╭──────────────────────────────────────────────────────────────────────────────────────────────────────────────────╮",
        "  │ ❯                                                                                                                │",
        "  ╰─────────────────────────────────────────────────────────────────────────── mock-model (Waycar harness lab mock) ─╯",
        "",
        "                                                                                                Logged in with API key",
    ]

    /// gemini 0.63.0 ready for input.
    static let geminiIdle = [
        "                                                                                                        ? for shortcuts",
        "────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────",
        " Shift+Tab to accept edits",
        "▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄",
        " >   Type your message or @path/to/file",
        "▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀",
        " workspace (/directory)                                         sandbox                                          /model",
        " ~/trustsweep/gemini.EXoF                                       no sandbox                                         Auto",
    ]

    /// qwen 0.25.1 ready for input.
    static let qwenIdle = [
        "────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────",
        ">   Type your message or @path/to/file",
        "────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────",
        "  ➜ qwen.d6MF · git:(main) · mock-model (Waycar harness lab mock)",
        "  Auto mode (shift + tab to cycle)",
    ]

    /// gemini 0.63.0 with `draft` typed in its input (screen-typed capture).
    static let geminiDraft = [
        "✦ waycar-mock-reply: GEMNODELAY",
        "────────────────────────────────────────────────────────────",
        " Shift+Tab to accept edits",
        "▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄",
        " > draft",
        "▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀",
        " workspace (/directory)                         sandbox",
        " ~/work/probe-gemini                            no sandbox",
    ]

    /// gemini 0.63.0's tool approval (screen-blocked capture): the input
    /// is gone, the last prompt sits above the dialog.
    static let geminiApproval = [
        "▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄",
        " > third WAYCAR_TOOL blocked",
        "▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀",
        "╭──────────────────────────────────────────────────────────╮",
        "│ ? Shell  rm -f /tmp/probe-none && echo waycar-tool-ok    │",
        "│ ╭──────────────────────────────────────────────────────╮ │",
        "│ │ rm -f /tmp/probe-none && echo waycar-tool-ok         │ │",
        "│ ╰──────────────────────────────────────────────────────╯ │",
        "│ Allow execution of [Shell]?                              │",
        "│                                                          │",
        "│ ● 1. Allow once                                          │",
        "│   2. Allow for this session                              │",
        "│   3. No, suggest changes (esc)                           │",
        "╰──────────────────────────────────────────────────────────╯",
    ]

    /// cline 3.0.70's tool approval (cline.md §10 capture).
    static let clineApproval = [
        " ❯ please run WAYCAR_TOOL now",
        " ⠼ Thinking... (esc to cancel)",
        " Cline needs permission",
        " Approve tool call?",
        " run_commands",
        "   $ bash",
        "   $ -lc",
        "   $ echo waycar-tool-ok",
        "  [y] Approve   [n] Deny",
        " mock-model (5,442) $0.00                                  ○ Plan ● Act (Tab)",
        " demo (main)",
        " Auto-approve all disabled (Shift+Tab)",
    ]

    /// hermes' REPL approval (hermes.md §10 capture).
    static let hermesApproval = [
        "│ <terminal> (plugin approval rule)              │",
        "│                                                │",
        "│ ❯ 1. Allow once                                │",
        "│   2. Allow for this session                    │",
        "│   3. Add to permanent allowlist                │",
        "│   4. Deny                                      │",
        "│                                                │",
        "│ waycar-probe-approval                          │",
        "╰────────────────────────────────────────────────╯",
        "  ↑/↓ to select, Enter to confirm  (297s)",
        " ☤ mock-model │ 12.5K/256K │ [░░░░░░░░░░] 5% │ ◷ 1.7s │ ↑ 5 t/s │ 10s │ ⏱ 4s",
        "──────────────────────────────────────────────────────────",
        "⚠ ❯",
        "──────────────────────────────────────────────────────────",
    ]

    @Test func aDraftInTheInputAwaitsEnter() {
        #expect(AgentScreen.draftAwaitsEnter(
            kind: "gemini", draft: "draft", screen: Self.screen(Self.geminiDraft)))
        #expect(!AgentScreen.draftAwaitsEnter(
            kind: "gemini", draft: "another draft", screen: Self.screen(Self.geminiDraft)))
        #expect(!AgentScreen.draftAwaitsEnter(kind: "gemini", draft: "draft", screen: ""))
    }

    /// A draft the TUI wrapped over rows, or collapsed to a placeholder,
    /// is still the draft.
    @Test func aWrappedOrCollapsedDraftAwaitsEnter() {
        let draft = "please look at the failing build and tell me why the tests broke"
        let wrapped = ["❯ please look at the failing build and tell me why t", "  he tests broke", "─────"]
        #expect(AgentScreen.draftAwaitsEnter(kind: "hermes", draft: draft, screen: Self.screen(wrapped)))
        #expect(AgentScreen.draftAwaitsEnter(
            kind: "gemini", draft: "one\ntwo\nthree\nfour\nfive\nsix",
            screen: Self.screen([" > [Pasted Text: 6 lines]", "▀▀▀▀▀"])))
        #expect(AgentScreen.draftAwaitsEnter(
            kind: "cline", draft: "one\ntwo\nthree",
            screen: Self.screen([" ❯ [one... Pasted +3 lines]", " Auto-approve all enabled (Shift+Tab)"])))
    }

    /// A short draft's few characters are on almost any screen (gemini's
    /// footer, cline's `(Tab)`, an earlier prompt above the input): it
    /// counts only right after the kind's input prompt.
    @Test func aShortDraftElsewhereOnScreenDoesNotAwaitEnter() {
        #expect(!AgentScreen.draftAwaitsEnter(kind: "gemini", draft: "y", screen: Self.screen(Self.geminiIdle)))
        #expect(!AgentScreen.draftAwaitsEnter(kind: "cline", draft: "tab", screen: Self.screen(Self.clineReady)))
        #expect(!AgentScreen.draftAwaitsEnter(
            kind: "cline", draft: "hello", screen: TmuxScreenDetectorTests.clineDone))
        // hermes' ghost suggestion in its input row is no draft (hermes.md).
        #expect(!AgentScreen.draftAwaitsEnter(
            kind: "hermes", draft: "brief",
            screen: Self.screen(["─────", "❯ Research this topic and write me a brief", "─────"])))
    }

    /// Each kind with a submit delay, its short draft in its input row: a
    /// status glyph before hermes' `❯` (`☤` during a turn) and a draft
    /// over two rows included.
    @Test(arguments: [
        ("gemini", [" > y"]), ("hermes", ["❯ y"]), ("hermes", ["☤ ❯ y"]), ("cline", ["❯ y"]),
        ("hermes", ["❯ y", "  n"]),
    ])
    func aShortDraftInTheInputRowAwaitsEnter(kind: String, input: [String]) {
        let draft = input.count > 1 ? "y\nn" : "y"
        #expect(AgentScreen.draftAwaitsEnter(
            kind: kind, draft: draft, screen: Self.screen(["* reply", "─────"] + input + ["─────", " footer"])))
        let delayed = SupportedAgentKind.allCases.map(\.rawValue)
            .filter { AgentScreen.readiness(kind: $0).submitDelay > .zero }
        #expect(Set(delayed) == ["gemini", "hermes", "cline"])
    }

    /// An approval dialog takes the Enter as its answer, whatever else the
    /// screen shows.
    @Test(arguments: [
        ("gemini", AgentScreenTests.geminiApproval),
        ("cline", AgentScreenTests.clineApproval),
        ("hermes", AgentScreenTests.hermesApproval),
    ])
    func anApprovalDialogDoesNotAwaitEnter(kind: String, rows: [String]) {
        #expect(!AgentScreen.draftAwaitsEnter(kind: kind, draft: "draft", screen: Self.screen(rows)))
        #expect(!AgentScreen.draftAwaitsEnter(
            kind: kind, draft: "draft", screen: Self.screen(rows + ["draft"])))
    }

    /// hermes keeps a draft typed during a turn in its `⚠ ❯` row under the
    /// approval (harness lab, 2026-10-12): the draft shows, the dialog
    /// still takes the Enter.
    @Test func hermesDraftUnderItsApprovalDoesNotAwaitEnter() {
        let rows = Self.hermesApproval.map { $0 == "⚠ ❯" ? "⚠ ❯ follow up draft" : $0 }
        #expect(rows != Self.hermesApproval)
        #expect(!AgentScreen.draftAwaitsEnter(
            kind: "hermes", draft: "follow up draft", screen: Self.screen(rows)))
    }

    @Test(arguments: [
        ("grok", AgentScreenTests.grokTrust),
        ("gemini", AgentScreenTests.geminiTrust),
        ("qwen", AgentScreenTests.qwenTrust),
        ("muse", TmuxScreenDetectorTests.museTrust),
    ])
    func trustDialogsAreRecognized(kind: String, rows: [String]) {
        #expect(AgentScreen.readiness(kind: kind).hasTrustDialog)
        #expect(AgentScreen.trustDialogShown(kind: kind, screen: Self.screen(rows)))
        // Each kind's own dialog only.
        for other in ["grok", "gemini", "qwen", "muse"] where other != kind {
            #expect(!AgentScreen.trustDialogShown(kind: other, screen: Self.screen(rows)))
        }
    }

    @Test(arguments: [
        ("grok", AgentScreenTests.grokIdle),
        ("gemini", AgentScreenTests.geminiIdle),
        ("qwen", AgentScreenTests.qwenIdle),
        ("muse", TmuxScreenDetectorTests.museIdle),
    ])
    func readyScreensShowNoTrustDialog(kind: String, rows: [String]) {
        #expect(!AgentScreen.trustDialogShown(kind: kind, screen: Self.screen(rows)))
        #expect(!AgentScreen.trustDialogShown(kind: kind, screen: ""))
    }

    /// A reply quoting the dialog's question is no dialog: every row it is
    /// known by must start a row.
    @Test func aQuotedTrustQuestionIsNoDialog() {
        #expect(!AgentScreen.trustDialogShown(
            kind: "grok",
            screen: Self.screen(["Do you trust the contents of this directory?", "", "  ❯"])))
        #expect(!AgentScreen.trustDialogShown(
            kind: "gemini",
            screen: Self.screen(["It asked: Do you trust the files in this folder?", " >   Type your message"])))
    }

    /// muse marks its selected option with an ASCII `>`: either row
    /// selected, the dialog is the same.
    @Test func museTrustIsKnownWhicheverOptionIsSelected() {
        let quitSelected = TmuxScreenDetectorTests.museTrust.map {
            switch $0 {
            case "> 1  Trust and continue": "  1  Trust and continue"
            case "  2  Quit": "> 2  Quit"
            default: $0
            }
        }
        #expect(quitSelected != TmuxScreenDetectorTests.museTrust)
        #expect(AgentScreen.trustDialogShown(kind: "muse", screen: Self.screen(quitSelected)))
    }

    /// The dialog's rows scrolled above the bottom of the screen no longer
    /// count.
    @Test func trustDialogRowsAboveTheChatAreNotShown() {
        let chat = (1...AgentScreen.trustRegionRows).map { "reply row \($0)" }
        #expect(!AgentScreen.trustDialogShown(kind: "grok", screen: Self.screen(Self.grokTrust + chat)))
    }

    /// claude, codex, copilot and agy dialogs are reported Blocked by herdr
    /// 0.9.3 and, before any hook, by tmux's screen rules
    /// (`TmuxScreenDetectorTests.liveTrustDialogsAreBlocked`): no extra read.
    @Test func kindsTheBackendsReportNeedNoTrustRead() {
        for kind in ["claude", "codex", "copilot", "agy", "pi", "omp", "opencode", "kilo", "cline", "hermes"] {
            #expect(!AgentScreen.readiness(kind: kind).hasTrustDialog, "\(kind)")
        }
    }

    @Test func trustRefusalNamesTheHarness() {
        let message = AgentFolderTrustRequiredError(kind: "grok", target: "w1:p1").message
        #expect(message.contains(SupportedAgentKind.grok.displayName))
    }

    @Test func signInRefusalNamesTheHarness() {
        let message = AgentSignInRequiredError(kind: "kiro", target: "w1:p1").message
        #expect(message.contains(SupportedAgentKind.kiro.displayName))
    }
}
