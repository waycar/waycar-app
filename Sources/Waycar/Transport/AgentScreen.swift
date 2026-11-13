import Foundation

/// Pure, per Agent kind: when a launched Agent takes typed input, and whether
/// its pane shows a sign-in screen or a folder-trust dialog instead of a
/// prompt. Both backends read
/// the screen: tmux with `capture-pane` (`TmuxTransport.checkLaunchReadiness`,
/// `TmuxTransport.promptAgent`), herdr with `pane.read {source: "visible"}`
/// (`WaycarSSHTransport.promptAgent`). Every fact below is a live lab
/// observation recorded in `docs/research/harnesses/<kind>.md`.
enum AgentScreen {
    /// How a launched Agent of one kind becomes promptable, and how a prompt
    /// is submitted to it.
    struct InputReadiness: Sendable, Equatable {
        /// What the screen shows once the TUI takes input; until then it
        /// drops pastes and typed prompts alike. Nil: nothing on screen
        /// tells, so ``minimumDelay`` and the generic launch gate decide.
        var marker: InputMarker?
        /// Input typed sooner after the launch is lost, though the screen
        /// gives no sign of it. tmux counts it from the kind's detection.
        var minimumDelay: Duration = .zero
        /// tmux only: the gap between a prompt's paste and its Enter. With
        /// none the Enter goes on the paste's control line.
        var submitDelay: Duration = .zero
        /// The kind opens on a sign-in screen when the Host has no login,
        /// where a prompt's text and Enter drive the login instead: every
        /// prompt to such an Agent reads its screen first, launch or not.
        var hasSignInScreen = false
        /// The kind can open on a folder-trust dialog that the backend
        /// reports as idle and ready (herdr 0.9.3) or that its Status Hooks
        /// report as idle, where a prompt's text or Enter answers it: every
        /// prompt to such an Agent reads its screen first, launch or not.
        var hasTrustDialog = false

        /// Whether a launch of this kind holds prompts beyond the generic
        /// gate.
        var gatesLaunch: Bool { marker != nil || minimumDelay > .zero }
    }

    /// A screen sign that a TUI takes input.
    enum InputMarker: Sendable, Equatable {
        /// A `┃`-bordered input box on the alternate screen: opencode
        /// (1.18.34, 1.19.0) and kilo (7.8.8, an opencode fork). Before it
        /// the alternate screen is blank, at most a spinner.
        case barBorderedBox
        /// Cline's `❯` input row above its `(Tab)`/`Shift+Tab` footer
        /// (3.0.70): pastes before the row draws were lost, cold or warm.
        case clineComposer
    }

    static func readiness(kind: String) -> InputReadiness {
        switch SupportedAgentKind(rawValue: kind) {
        case .opencode, .kilo:
            // kilo: pastes up to 4.0 s were lost with the box at 4.29 s; on
            // herdr 0.9.3 a prompt acked ~1 s after promotion was lost in 3
            // of 4 runs (kilo.md, herdr-backend.md).
            InputReadiness(marker: .barBorderedBox)
        case .cline:
            // An Enter on the paste's own tmux line was swallowed and the
            // text stayed in the composer; a raw CR 0.5 s later submitted
            // (cline.md §10). herdr's `agent.prompt` submits fine.
            InputReadiness(marker: .clineComposer, submitDelay: .milliseconds(500))
        case .copilot:
            // A paste 0.3 s after launch was lost, 0.8 s landed (copilot.md).
            InputReadiness(minimumDelay: .milliseconds(1500))
        case .qwen:
            // 0.8 s lost, 1.5 s landed (qwen.md).
            InputReadiness(minimumDelay: .seconds(2), hasTrustDialog: true)
        case .gemini:
            // 0.8 s lost, 2 s landed; an Enter right after the paste is
            // swallowed, a ~0.3 s gap submits (gemini.md).
            InputReadiness(
                minimumDelay: .seconds(3), submitDelay: .milliseconds(500), hasTrustDialog: true)
        case .grok:
            InputReadiness(hasTrustDialog: true)
        case .hermes:
            // An Enter on the paste's own tmux line leaves the text
            // unsubmitted; 100 and 250 ms later it always submitted
            // (hermes.md). herdr's `agent.prompt` submits fine.
            InputReadiness(submitDelay: .milliseconds(250))
        case .cursor, .devin, .kiro, .antigravity:
            InputReadiness(hasSignInScreen: true)
        case .muse:
            // Pastes 0.3 s after a trusted launch landed (muse.md §10). Its
            // trust dialog comes before any hook (tmux reads it off the
            // screen); herdr 0.9.3 reports it blocked today, but only
            // through its remote `muse.toml`, stale for 1.4.6 elsewhere.
            InputReadiness(hasSignInScreen: true, hasTrustDialog: true)
        default:
            InputReadiness()
        }
    }

    /// Whether `screen` shows `marker`. tmux callers check the alternate
    /// screen is on first, so a shell's output from before the TUI drew
    /// never counts; herdr's `pane.read` reports no such flag.
    static func inputIsOnScreen(_ marker: InputMarker, screen: String) -> Bool {
        let rows = screen.split(whereSeparator: \.isNewline)
        switch marker {
        case .barBorderedBox:
            return rows.contains { $0.drop(while: \.isWhitespace).hasPrefix("┃") }
        case .clineComposer:
            // herdr's `cline.toml` `composer_idle` evidence: the row and
            // the footer's mode toggles, which a shell prompt has not.
            let hasRow = rows.contains { row in
                let trimmed = row.drop(while: \.isWhitespace)
                return trimmed.first == "❯" && trimmed.dropFirst().first?.isWhitespace != false
            }
            return hasRow && screen.contains("(Tab)") && screen.contains("Shift+Tab")
        }
    }

    /// Whether `screen`, read right before a delayed submit's Enter
    /// (``InputReadiness/submitDelay``), still shows the pasted `draft`
    /// waiting in the Agent's input and none of the kind's approval
    /// dialogs, so the Enter submits the draft rather than answering a
    /// dialog that opened during the gap. A draft of ``draftTailLength``
    /// or more non-blank characters counts as shown by its last
    /// ``draftTailLength`` within the bottom ``submitRegionRows`` non-empty
    /// rows, wraps ignored; a shorter one, whose few characters almost any
    /// screen holds, only right after the kind's input prompt (its last
    /// ``inputText(_:prompt:)`` row and the rows it wraps onto). Either
    /// also counts as the kind's collapsed-paste placeholder (gemini
    /// 0.63.0 `[Pasted Text: N lines]`/`chars]`, hermes `[Pasted text #N:
    /// …]`, cline `[… Pasted +N lines]`). gemini and cline hide their
    /// input while a dialog shows; hermes keeps the draft in its `⚠ ❯` row
    /// under one, so each dialog is also known by a row it always starts,
    /// read as ``trustDialogShown(kind:screen:)`` reads rows. All live in
    /// the harness lab on tmux 3.4, 2026-10-12: short, 8-line and
    /// 1263-char drafts, and a draft pasted during a turn that then asked.
    static func draftAwaitsEnter(kind: String, draft: String, screen: String) -> Bool {
        let rows = screen.lowercased().split(whereSeparator: \.isNewline)
            .filter { !$0.allSatisfy(\.isWhitespace) }
            .suffix(submitRegionRows)
        let dialogRows = approvalDialogRows(kind: kind)
        if rows.contains(where: { row in dialogRows.contains { trustDialogRow(row).hasPrefix($0) } }) {
            return false
        }
        if rows.contains(where: { $0.contains("[pasted text") || $0.contains("pasted +") }) {
            return true
        }
        let typed = String(draft.lowercased().filter { !$0.isWhitespace })
        guard typed.count < draftTailLength else {
            let tail = String(typed.suffix(draftTailLength))
            return rows.joined().filter { !$0.isWhitespace }.contains(tail)
        }
        guard let prompt = inputPrompt(kind: kind),
            let row = rows.lastIndex(where: { inputText($0, prompt: prompt) != nil }),
            let text = inputText(rows[row], prompt: prompt)
        else { return false }
        let input = String(text) + rows[(row + 1)...].joined()
        return input.filter { !$0.isWhitespace }.hasPrefix(typed)
    }

    /// Non-empty rows from the bottom the draft must sit in: gemini's input
    /// box sits over at most 4 rows of footer.
    static let submitRegionRows = 12

    /// Characters from the draft's end its input must show.
    static let draftTailLength = 24

    /// The glyph the input row of a kind with a submit delay starts with:
    /// gemini's ` > ` in its `▄`/`▀` box, hermes' and cline's `❯` (gemini.md,
    /// hermes.md, cline.md §10).
    private static func inputPrompt(kind: String) -> Character? {
        switch SupportedAgentKind(rawValue: kind) {
        case .gemini: ">"
        case .hermes, .cline: "❯"
        default: nil
        }
    }

    /// What `row` holds after `prompt`, when the row starts with it, at
    /// most one status glyph before it (hermes' `⚠ ❯` under a dialog, `☤ ❯`
    /// during a turn); nil for any other row.
    private static func inputText(_ row: Substring, prompt: Character) -> Substring? {
        var text = row.drop(while: \.isWhitespace)
        if let glyph = text.first, glyph != prompt, !glyph.isLetter, !glyph.isNumber,
            text.dropFirst().first?.isWhitespace == true
        {
            text = text.dropFirst().drop(while: \.isWhitespace)
        }
        guard text.first == prompt else { return nil }
        return text.dropFirst()
    }

    /// The starts of rows only a kind's approval dialog shows, from the
    /// live captures: gemini 0.63.0's tool box (`● 1. Allow once`), hermes'
    /// REPL box and footer and its TUI footer, cline 3.0.70's
    /// `Cline needs permission` / `[y] Approve   [n] Deny`. tmux also
    /// refuses the Enter on any screen its rules read as Blocked
    /// (`TmuxScreenDetector.classify`), cline's question among them.
    private static func approvalDialogRows(kind: String) -> [String] {
        switch SupportedAgentKind(rawValue: kind) {
        case .gemini: ["1. allow once"]
        case .hermes: ["1. allow once", "↑/↓ to select, enter to confirm", "↑/↓ select · enter confirm"]
        case .cline: ["cline needs permission", "[y] approve"]
        default: []
        }
    }

    /// Whether `screen` is the sign-in screen of an Agent of `kind`, where
    /// typing a prompt would drive the login (herdr 0.9.3 reads these
    /// screens as idle and ready). The texts are the screens captured live:
    /// cursor-agent 2026.10.01, devin 3000.11.3, kiro-cli 2.29.1, agy 1.3.3.
    /// cursor, devin and kiro draw inline and agy's chat does too, so an
    /// Agent's reply quoting a login line sits on the same screen: a
    /// screen counts only when every row it is known by starts one of the
    /// bottom ``signInRegionRows`` rows. Each marker is short enough to
    /// start its row on a narrow pane, where the rest of the line wraps.
    static func signInRequired(kind: String, screen: String) -> Bool {
        let rows = screen.lowercased().split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(signInRegionRows)
        return signInScreens(kind: kind).contains { markers in
            markers.allSatisfy { marker in rows.contains { $0.hasPrefix(marker) } }
        }
    }

    /// Non-empty rows from the bottom a sign-in screen's markers must sit
    /// in: the captured screens take at most 8, a wrapped URL included.
    static let signInRegionRows = 12

    /// Each sign-in screen of `kind` as the starts of rows it always shows.
    private static func signInScreens(kind: String) -> [[String]] {
        switch SupportedAgentKind(rawValue: kind) {
        case .cursor:
            [
                // "Cursor Agent" / its version / "Press any key to log in...".
                ["cursor agent", "press any key to log in"],
                // After a key: the browser link.
                ["if your browser didn't open", "https://cursor.com/logindeepcontrol"],
                // After `q`: the QR code (cursor.md records this row alone).
                ["scan this qr code to log in"],
            ]
        case .devin:
            [
                // The login method menu (lab capture, devin 3000.11.3): its
                // 13 non-empty rows push the welcome row past the region,
                // and the selected option's row starts with `❭`, so it is
                // known by its question and an option's description row.
                ["how would you like to log in?", "for ssh or remote sessions without browser"],
                // "Paste a token manually": the link above the `Code:` input.
                ["welcome to devin cli!", "visit https://app.devin.ai/auth/cli"],
                // "Log in with browser": the spinner row starts with a
                // braille glyph, so the hint under it marks the screen.
                ["welcome to devin cli!", "press enter to paste a token manually instead"],
            ]
        case .kiro:
            // "Welcome to Kiro CLI, let's get you signed in!" / "Press enter
            // to continue to the browser or esc to cancel".
            [["welcome to kiro cli, let's get", "press enter to continue"]]
        case .antigravity:
            // A fresh HOME's first run: "Welcome to the Antigravity CLI. You
            // are currently not signed in." over the login method menu.
            [["welcome to the antigravity cli", "select login method"]]
        case .muse:
            // muse 1.4.6 with no credentials: the login method menu, then
            // the browser device flow (muse.md §12).
            [
                ["log in with browser · enter to choose", "set an api key"],
                ["sign in at this page:", "waiting for approval"],
            ]
        default:
            []
        }
    }

    /// Whether `screen` shows the folder-trust dialog of an Agent of `kind`
    /// that a backend may not report as blocked (herdr 0.9.3 reads grok's
    /// and gemini's as idle; qwen's hook reports idle under it on tmux;
    /// muse's comes before any hook, and herdr knows it only from a remote
    /// manifest). Each dialog is known by the starts of rows it always
    /// shows, read the way ``signInRequired(kind:screen:)`` reads its
    /// screens: lowercased, within the bottom ``trustRegionRows`` non-empty
    /// rows, a box's `│` border and the option marker (`●`, `›`, `❯`, `>`)
    /// dropped. The texts are the dialogs captured live in the harness lab
    /// on 2026-10-12 (grok.md §12, gemini.md, qwen.md, muse.md §10).
    static func trustDialogShown(kind: String, screen: String) -> Bool {
        let markers = trustDialog(kind: kind)
        guard !markers.isEmpty else { return false }
        let rows = screen.lowercased().split(whereSeparator: \.isNewline)
            .map(trustDialogRow)
            .filter { !$0.isEmpty }
            .suffix(trustRegionRows)
        return markers.allSatisfy { marker in rows.contains { $0.hasPrefix(marker) } }
    }

    /// Non-empty rows from the bottom a trust dialog's markers must sit in:
    /// gemini's box takes 15, a wrapped explanation included.
    static let trustRegionRows = 20

    /// One row without its surrounding blanks, box border and option marker.
    private static func trustDialogRow(_ row: Substring) -> Substring {
        var text = row.drop(while: \.isWhitespace)
        if text.first == "│" { text = text.dropFirst().drop(while: \.isWhitespace) }
        if let marker = text.first, ["●", "›", "❯", ">"].contains(marker) {
            text = text.dropFirst().drop(while: \.isWhitespace)
        }
        while let last = text.last, last.isWhitespace || last == "│" { text = text.dropLast() }
        return text
    }

    /// The starts of the rows `kind`'s folder-trust dialog always shows.
    private static func trustDialog(kind: String) -> [String] {
        switch SupportedAgentKind(rawValue: kind) {
        case .grok:
            // grok 1.0.50, in a folder with project config (AGENTS.md,
            // `.claude/settings.json`, `.grok/hooks`) missing from
            // `~/.grok/trusted_folders.toml`: `y` trusts, `n` quits.
            ["do you trust the contents of this directory?", "yes, proceed", "no, quit"]
        case .gemini:
            // gemini 0.63.0 (folder trust is on by default): Enter picks
            // the marked `1. Trust folder (<name>)`.
            ["do you trust the files in this folder?", "1. trust folder", "3. don't trust"]
        case .qwen:
            // qwen 0.25.1 with `security.folderTrust.enabled` (off by
            // default): Enter picks the marked `1. Trust folder (<name>)`.
            ["do you trust this folder?", "1. trust folder", "3. don't trust"]
        case .muse:
            // Muse Code 1.4.6 in a workspace it has not trusted: Enter
            // picks the marked `1  Trust and continue`, which loads the
            // workspace's own hooks and plugins.
            ["do you trust this workspace?", "1  trust and continue", "2  quit"]
        default:
            []
        }
    }
}

/// A prompt refused, nothing typed, because the Agent's pane shows its
/// sign-in screen: the prompt's text and Enter would drive the login
/// (cursor's browser sign-in, devin's login menu, kiro's browser flow,
/// which exits kiro-cli when no browser opens). Not retried: only signing
/// in on the Host clears it.
struct AgentSignInRequiredError: Error, Sendable, Equatable {
    /// The Agent's kind, e.g. `cursor`.
    let kind: String
    let target: String

    /// What a sender shows.
    var message: String {
        let name = SupportedAgentKind(rawValue: kind)?.displayName ?? kind
        return "Sign in to \(name) on the Host first."
    }
}

/// A prompt refused, nothing typed, because the Agent's pane shows its
/// folder-trust dialog (`AgentScreen.trustDialogShown`): the prompt's text
/// or Enter would answer it (grok trusts the folder on `y` and quits on
/// `n`; gemini, qwen and muse trust it on Enter). Not retried: the user
/// answers it in the terminal.
struct AgentFolderTrustRequiredError: Error, Sendable, Equatable {
    /// The Agent's kind, e.g. `grok`.
    let kind: String
    let target: String

    /// What a sender shows.
    var message: String {
        let name = SupportedAgentKind(rawValue: kind)?.displayName ?? kind
        return "\(name) asks whether to trust this folder. Answer it in the terminal, then send again."
    }
}
