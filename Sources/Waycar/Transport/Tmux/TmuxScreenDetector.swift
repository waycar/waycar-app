import Foundation

/// Pure: a conservative Agent Status read off a tmux pane's screen, the
/// fallback for Status Hooks' blind spots (design §4.6, §7 phase 6; ADR
/// 0026): Claude's trust dialog and Esc interrupt, Codex plan-mode
/// questions, Codex hooks not yet reviewed, approvals of kinds whose hooks
/// report none (agy, cline, kiro), Copilot's dialogs before its first
/// hook, the folder-trust dialogs of grok, gemini and qwen
/// (`AgentScreen.trustDialogShown`), agents without hooks.
///
/// Nil means unsure, and Unknown beats a guess: a screen that matches no
/// rule changes nothing. A terminal title's spinner is never a signal on
/// its own (Claude shows none, Codex spins while idle).
///
/// The Claude, Codex, Copilot and Muse rules are Waycar's own, written from
/// screens captured live in tmux (Claude Code 2.1.287, Codex CLI 0.159.3,
/// Copilot CLI 1.0.96, Muse Code 1.4.6). The agy,
/// cline and kiro rules port herdr's Apache-2.0 detection manifests
/// (`src/detect/manifests`: agy 2026.10.05.1, cline 2026.09.11.1, kiro
/// 2026.09.19.1) with herdr's semantics: `contains` matches lowercased
/// text and needs every needle, each `line_regex` must match some row.
enum TmuxScreenDetector {
    /// Lines of history read above the visible screen.
    static let historyLines = 40

    static let claude = SupportedAgentKind.claude.rawValue
    static let codex = SupportedAgentKind.codex.rawValue
    static let agy = SupportedAgentKind.antigravity.rawValue
    static let cline = SupportedAgentKind.cline.rawValue
    static let kiro = SupportedAgentKind.kiro.rawValue
    static let copilot = SupportedAgentKind.copilot.rawValue
    static let muse = SupportedAgentKind.muse.rawValue
    static let grok = SupportedAgentKind.grok.rawValue
    static let gemini = SupportedAgentKind.gemini.rawValue
    static let qwen = SupportedAgentKind.qwen.rawValue

    /// Kinds with rules; panes of any other kind are never read.
    static func supports(kind: String) -> Bool {
        [claude, codex, agy, cline, kiro, copilot, muse, grok, gemini, qwen].contains(kind)
    }

    /// Kinds whose Status Hooks have no approval event, so a hook's
    /// `working` can hide an approval dialog (agy: `PreToolUse` fires before
    /// it; cline: likewise; kiro: no permission event) or outlive the turn
    /// (agy: a denial or Esc fires no hook). Their screens are read all
    /// through a hook's `working`, not only once it went stale.
    static func readsWhileWorking(kind: String) -> Bool {
        [agy, cline, kiro].contains(kind)
    }

    /// The status `screen` (`capture-pane -p -J` output) shows for an Agent
    /// of `kind` whose pane title is `title`; nil when unsure.
    static func classify(kind: String, screen: String, title: String) -> AgentStatus? {
        let lines = screenLines(screen)
        switch kind {
        case claude: return classifyClaude(lines)
        case codex: return classifyCodex(lines, title: title)
        case agy: return classifyAgy(lines)
        case cline: return classifyCline(lines)
        case kiro: return classifyKiro(lines, title: title)
        case copilot: return classifyCopilot(lines)
        case muse: return classifyMuse(lines)
        // Only their folder-trust dialog: Blocked, since Enter (or grok's
        // `y`) answers it; nothing else is read off these screens.
        case grok, gemini, qwen:
            return AgentScreen.trustDialogShown(kind: kind, screen: screen) ? .blocked : nil
        default: return nil
        }
    }

    /// The screen's rows, trailing blanks trimmed from each row and blank
    /// rows dropped from the bottom.
    static func screenLines(_ screen: String) -> [String] {
        var lines = screen.split(separator: "\n", omittingEmptySubsequences: false).map {
            trimmingTrailingWhitespace($0)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    // MARK: Claude Code

    /// Glyphs Claude's activity line starts with; the spinner cycles them.
    private static let claudeGlyphs: Set<Character> = ["·", "✢", "✳", "✶", "✻", "✽", "*"]

    /// Claude draws its input box between two full-width rules, `❯` on the
    /// box's first row; dialogs replace the box and sit after a rule, the
    /// status line and mode line follow the box. Claude hides its activity
    /// line while it streams text, so a box under streamed text is no idle
    /// signal: idle needs the turn's closing line (`✻ Baked for 31s`), an
    /// interruption, or the welcome screen.
    private static func classifyClaude(_ lines: [String]) -> AgentStatus? {
        let rules = lines.indices.filter { isRule(lines[$0]) }
        let footer = lines[(rules.last.map { $0 + 1 } ?? 0)...]
            .joined(separator: "\n").lowercased()
        if claudeDialogIsOpen(footer) { return .blocked }
        // Older releases print the hint on the mode line below the box.
        if footer.contains("esc to interrupt") { return .working }

        guard rules.count >= 2 else { return nil }
        let top = rules[rules.count - 2]
        let bottom = rules[rules.count - 1]
        guard bottom - top >= 2, trimmingLeadingWhitespace(lines[top + 1]).hasPrefix("❯")
        else { return nil }
        let transcript = lines[..<top]
        guard let headIndex = transcript.lastIndex(where: isHead) else { return nil }
        let head = transcript[headIndex]
        if isClaudeActivity(head) { return .working }
        if isClaudeTurnSummary(head) { return .idle }
        if transcript[headIndex...].contains(where: isClaudeInterruption) { return .idle }
        let hasTurns = transcript.contains { $0.hasPrefix("❯") || $0.hasPrefix("⏺") }
        if !hasTurns, transcript.contains(where: { $0.contains("Claude Code v") }) { return .idle }
        return nil
    }

    /// A dialog after the last rule: folder trust, a permission prompt, a
    /// question, an MCP input request.
    private static func claudeDialogIsOpen(_ footer: String) -> Bool {
        if footer.contains("do you trust the files in this folder?")
            || footer.contains("is this a project you created or one you trust?")
        {
            return true
        }
        guard footer.contains("esc to cancel") else { return false }
        return [
            "enter to confirm", "enter to select", "do you want to proceed?", "tab to amend",
            "requests your input",
        ].contains { footer.contains($0) }
    }

    /// `✢ Combobulating… (2s · thinking)`: a glyph, then a label ending in
    /// `…` before any `·` or `(`.
    private static func isClaudeActivity(_ line: String) -> Bool {
        guard let body = claudeGlyphBody(line), let ellipsis = body.firstIndex(of: "…") else {
            return false
        }
        let label = body[..<ellipsis]
        return !label.isEmpty && !label.contains("·") && !label.contains("(")
    }

    /// `✻ Baked for 31s · done 3:25 PM`: a glyph, a verb, `for`, a duration.
    private static func isClaudeTurnSummary(_ line: String) -> Bool {
        guard let body = claudeGlyphBody(line) else { return false }
        let words = body.split(separator: " ", omittingEmptySubsequences: true)
        guard words.count >= 3, words[1] == "for" else { return false }
        return isDuration(words[2])
    }

    /// `⎿  Interrupted · What should Claude do instead?` (and the older
    /// `⎿  Interrupted by user`).
    private static func isClaudeInterruption(_ line: String) -> Bool {
        let trimmed = trimmingLeadingWhitespace(line)
        return trimmed.hasPrefix("⎿")
            && (trimmed.contains("Interrupted ·") || trimmed.contains("Interrupted by user"))
    }

    /// The text after a leading activity glyph and its space; nil when the
    /// line does not start that way.
    private static func claudeGlyphBody(_ line: String) -> Substring? {
        guard let first = line.first, claudeGlyphs.contains(first) else { return nil }
        let rest = line.dropFirst()
        guard rest.first?.isWhitespace == true else { return nil }
        let body = rest.drop(while: \.isWhitespace)
        return body.isEmpty ? nil : body
    }

    // MARK: Codex

    /// Codex's composer is the last row starting with `›`, with only its
    /// footer below; while a turn runs, a `Working (7s • esc to interrupt)`
    /// line sits above it. Approvals, questions and folder trust replace
    /// the composer, and the title then reads `Action Required` for most.
    private static func classifyCodex(_ lines: [String], title: String) -> AgentStatus? {
        if title.lowercased().contains("action required") { return .blocked }
        let nonEmpty = lines.filter { !$0.allSatisfy(\.isWhitespace) }
        let recent = nonEmpty.suffix(20).joined(separator: "\n").lowercased()
        if codexTrustIsOpen(recent) { return .blocked }

        let promptIndex = lines.lastIndex { $0.hasPrefix("›") }
        let tailLines = lines[(promptIndex ?? max(0, lines.count - 20))...]
        let tail = tailLines.joined(separator: "\n").lowercased()
        let strong = [
            "press enter to confirm or esc to cancel", "enter to submit answer",
            "enter to submit all", "allow command?", "would you like to run the following command?",
            "would you like to make the following edits?",
        ]
        if strong.contains(where: { tail.contains($0) }) { return .blocked }
        let bottom = tailLines.suffix(6).joined(separator: "\n").lowercased()
        if bottom.contains("[y/n]") || bottom.contains("yes (y)") { return .blocked }

        guard let promptIndex, !isCodexMenuRow(lines[promptIndex]) else { return nil }
        let above = lines[..<promptIndex].filter { !$0.allSatisfy(\.isWhitespace) }.suffix(6)
        if above.contains(where: isCodexActivity) { return .working }
        let below = lines[(promptIndex + 1)...]
        if below.contains(where: isCodexActivity) { return .working }
        // More than a wrapped draft and the footer below it: an overlay.
        guard below.count <= 8 else { return nil }
        return .idle
    }

    private static func codexTrustIsOpen(_ recent: String) -> Bool {
        if recent.contains("do you trust the contents of this directory?") { return true }
        return recent.contains("trust this folder?")
            && (recent.contains("trust and continue") || recent.contains("enter continue"))
    }

    /// `Working (7s • esc to interrupt)`, never the user's own `›` row.
    private static func isCodexActivity(_ line: String) -> Bool {
        !line.hasPrefix("›") && line.lowercased().contains("esc to interrupt)")
    }

    /// `› 1. GPT-6-Luna`: a picker's selected row, not the composer.
    private static func isCodexMenuRow(_ line: String) -> Bool {
        let rest = line.dropFirst().drop(while: \.isWhitespace)
        let digits = rest.prefix(while: \.isNumber)
        return !digits.isEmpty && rest.dropFirst(digits.count).hasPrefix(". ")
    }

    // MARK: Antigravity (agy)

    /// agy 1.3.3 draws inline: a `>` box between two rules, then a footer
    /// row, `? for shortcuts` when idle and `esc to cancel` while a turn
    /// runs. Dialogs (permission, question) end with a key-hint row above
    /// that footer. A denial or Esc ends on the idle footer with no hook,
    /// which is the idle rule's reason (agy.md); herdr's manifest has no
    /// idle rule, its idle is the fallback.
    private static func classifyAgy(_ lines: [String]) -> AgentStatus? {
        let bottomTwo = bottomNonEmpty(lines, 2)
        let bottomText = bottomTwo.joined(separator: "\n").lowercased()
        if bottomText.contains("navigate"),
            bottomText.contains("tab amend") || bottomText.contains("esc skip")
        {
            return .blocked
        }
        if containsAll(
            bottomNonEmpty(lines, 8),
            ["do you trust the contents of this project?", "yes, i trust this folder", "enter confirm"])
        {
            return .blocked
        }
        let recent = lines.joined(separator: "\n").lowercased()
        if recent.contains("requesting permission for:"),
            recent.contains("do you want to proceed?")
                || (recent.contains("tab amend") && recent.contains("edit command"))
        {
            return .blocked
        }
        if footerFollowsRule(bottomTwo, footer: "esc to cancel") { return .working }
        if bottomNonEmpty(lines, 12).contains(where: { $0.contains(#/^\s*[\u{2801}-\u{28FF}]+\s+\S/#) }) {
            return .working
        }
        if footerFollowsRule(bottomTwo, footer: "? for shortcuts") { return .idle }
        return nil
    }

    /// A full-width rule row, then a footer row starting with `footer`.
    private static func footerFollowsRule(_ bottomTwo: [String], footer: String) -> Bool {
        guard bottomTwo.count == 2 else { return false }
        let rule = bottomTwo[0].drop(while: \.isWhitespace)
        return rule.count >= 3 && rule.allSatisfy { $0 == "─" }
            && bottomTwo[1].drop(while: \.isWhitespace).lowercased().hasPrefix(footer)
    }

    // MARK: Cline

    /// Cline 3.0.70's alternate-screen TUI. Its approval sits below a
    /// still-spinning `Thinking... (esc to cancel)` row, so blocked rules go
    /// first; the composer `❯` row stays drawn while a turn runs, so working
    /// goes before idle. herdr's catch-all `default_cline_working` is left
    /// out: an unknown screen stays unsure.
    private static func classifyCline(_ lines: [String]) -> AgentStatus? {
        let recent = lines.joined(separator: "\n").lowercased()
        let permissionPrompts: [[String]] = [
            ["let cline use this tool"],
            ["[act mode]", "execute command?", "yes"],
            ["[act mode]", "use this tool?", "yes"],
            ["[plan mode]", "execute command?", "yes"],
            ["[plan mode]", "use this tool?", "yes"],
        ]
        if permissionPrompts.contains(where: { $0.allSatisfy { recent.contains($0) } }) {
            return .blocked
        }
        if containsAll(
            bottomNonEmpty(lines, 16),
            ["cline needs permission", "approve tool call?", "[y] approve", "[n] deny"])
        {
            return .blocked
        }
        let bottom24 = bottomNonEmpty(lines, 24)
        if containsAll(bottom24, ["(tab)", "shift+tab"]),
            bottom24.contains(where: { $0.contains(#/^\s*Cline is asking a question\s*$/#) }),
            bottom24.contains(where: { $0.contains(#/^\s*>\s+\S/#) })
        {
            return .blocked
        }
        let bottom20 = bottomNonEmpty(lines, 20)
        if bottom20.contains(where: { $0.contains(#/^\s*[\u{2801}-\u{28FF}]\s+\S/#) })
            || containsAll(bottom20, ["thinking... (esc to cancel)"])
        {
            return .working
        }
        let bottom12 = bottomNonEmpty(lines, 12)
        if containsAll(bottom12, ["─", "(tab)", "shift+tab"]),
            bottom12.contains(where: { $0.contains(#/^\s*❯(?:\s.*)?$/#) })
        {
            return .idle
        }
        return nil
    }

    // MARK: Kiro

    /// kiro-cli's chat screens are UNVERIFIED live (no account; kiro.md):
    /// the rules are herdr's `kiro.toml` as it stands, in its priority
    /// order, idle first. OSC progress is not visible to tmux and is left
    /// out; the OSC title is the pane title.
    private static func classifyKiro(_ lines: [String], title: String) -> AgentStatus? {
        let bottom4 = bottomNonEmpty(lines, 4)
        if bottom4.contains(where: {
            $0.contains(#/(?i)^\s*[>›]\s*ask a question or describe a task(?:\s+(?:enter|↵))?\s*$/#)
        }) {
            return .idle
        }
        let bottom8 = bottomNonEmpty(lines, 8)
        if kiroToolApproval(bottom8) { return .blocked }
        if kiroModifyRequestApproval(lines) { return .blocked }
        if containsAll(
            bottom8,
            [
                "tool approval", "approve all pending", "configure individually (agent monitor)",
                "exit (cancel subagents)",
            ])
        {
            return .blocked
        }
        if containsAll(bottom8, ["to navigate", "to submit", "esc to cancel"]) { return .blocked }
        if containsAll(bottom4, ["kiro is working", "type to steer", "ctrl+s to queue"]) {
            return .working
        }
        if title.contains(#/(?i)^[◐◓◑◒\/|\\-]\s+kiro:/#) { return .working }
        return nil
    }

    /// `modify_request_approval`, as herdr's regex reads the whole capture:
    /// a rule row, a `… requires approval · modify request` row, rows that
    /// are blank or no rule with a `>`/`›` row among them, a rule row, and
    /// `esc to close` as the last row. Walked row by row from the bottom:
    /// the regex's nested alternations backtrack exponentially in Swift
    /// Regex (herdr's Rust `regex` is linear), and the screen watch runs
    /// this on the transport actor.
    private static func kiroModifyRequestApproval(_ lines: [String]) -> Bool {
        func isDashRule(_ row: String) -> Bool {
            let trimmed = row.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            return !trimmed.isEmpty && trimmed.allSatisfy { $0 == "-" || $0 == "─" }
        }
        /// Blank, or a character that is no space and no rule's.
        func isBodyRow(_ row: String) -> Bool {
            row.allSatisfy { $0 == " " || $0 == "\t" }
                || row.contains { !$0.isWhitespace && $0 != "-" && $0 != "─" }
        }
        guard lines.count >= 5, let last = lines.last,
            last.contains(#/(?i)^[ \t]*esc[ \t]+to[ \t]+close[ \t]*$/#),
            isDashRule(lines[lines.count - 2])
        else { return false }
        var sawInput = false
        for index in stride(from: lines.count - 3, through: 1, by: -1) {
            let row = lines[index]
            guard isBodyRow(row) else { return false }
            if sawInput, isDashRule(lines[index - 1]),
                row.contains(#/(?i)requires\s+approval\s*[·.]\s*modify\s+request[ \t]*$/#)
            {
                return true
            }
            if row.contains(#/^[ \t]*[>›]/#) { sawInput = true }
        }
        return false
    }

    /// `tool_approval`: the footer `esc to close … to navigate` (or its
    /// longer forms) closes the region, over one of the approval menus.
    private static func kiroToolApproval(_ bottom8: [String]) -> Bool {
        let region = bottom8.joined(separator: "\n")
        guard
            region.contains(
                #/(?is)(?:^|\n)\s*esc\s+to\s+close\b(?:[^\n]*\bto\s+navigate\b[^\n]*|.*\bto\s+navigate\b.*\bto\s+select\b.*\btab\s+to\s+edit|[^\n]*\benter\s+to\s+see\s+more\s+options)\s*\z/#)
        else { return false }
        func all(_ patterns: [Regex<Substring>]) -> Bool {
            patterns.allSatisfy { pattern in bottom8.contains { $0.contains(pattern) } }
        }
        return all([
            #/(?i)^\s*[>❯]\s*(?:allow|always allow|deny|always deny)\s*$/#,
            #/(?i)^\s*(?:[>❯]\s*)?allow\s*$/#,
            #/(?i)^\s*(?:[>❯]\s*)?always allow\s*$/#,
            #/(?i)^\s*(?:[>❯]\s*)?deny\s*$/#,
            #/(?i)^\s*(?:[>❯]\s*)?always deny\s*$/#,
        ])
            || all([
                #/(?i)^\s*[>❯]\s*(?:yes, single permission|trust, always allow in this session|no \(tab to edit\))\s*$/#,
                #/(?i)^\s*(?:[>❯]\s*)?yes, single permission\s*$/#,
                #/(?i)^\s*(?:[>❯]\s*)?trust, always allow in this session\s*$/#,
                #/(?i)^\s*(?:[>❯]\s*)?no \(tab to edit\)\s*$/#,
            ])
            || all([
                #/(?i)^\s*[>❯]\s*(?:trust\b.*|entire tool)\s*$/#,
                #/(?i)^\s*(?:[>❯]\s*)?(?:trust )?entire tool(?:\s+\([^\n]*\))?(?:\s+(?:session|workspace|always))?\s*$/#,
            ])
    }

    // MARK: Copilot

    /// Copilot CLI 1.0.96 draws each choice it waits on (a tool approval,
    /// "Session in use" on resume, folder trust) as a box closing the
    /// screen: a numbered option marked `❯`, the footer `↑/↓ to navigate ·
    /// enter to select · esc to cancel`, then `╰─…─╯`. Enter picks the
    /// marked option, so it is Blocked. Copilot fires no hook until its
    /// first prompt, so before then only its screen tells; nothing else is
    /// read off it.
    private static func classifyCopilot(_ lines: [String]) -> AgentStatus? {
        let box = bottomNonEmpty(lines, 16).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard let bottom = box.last, bottom.hasPrefix("╰─"), bottom.hasSuffix("╯"),
            box.count >= 2,
            box[box.count - 2].lowercased().contains(#/^│\s*↑/↓ to navigate · enter to select\b/#),
            box.contains(where: { $0.contains(#/^│\s*❯\s*\d+\.\s/#) })
        else { return nil }
        return .blocked
    }

    // MARK: Muse

    /// Muse Code 1.4.6 draws inline: a `❯` composer row between two rules
    /// over a `model · effort · cwd · mode` footer, which stays drawn while
    /// a turn runs above it (`◇ Thinking (1s · esc to interrupt)`). Its
    /// approval and pickers replace the composer, with the activity row
    /// still above; the trust dialog comes before any hook fires
    /// (`SessionStart` waits for the first prompt). Written from the live
    /// 1.4.6 screens (muse.md §10): herdr's `muse.toml` is stale for them.
    private static func classifyMuse(_ lines: [String]) -> AgentStatus? {
        // herdr's `muse.toml` misses 1.4.6's approval and idle rows; its
        // pairs for older versions stay beside them, and its settings
        // overlays stay unsure.
        let bottom = bottomNonEmpty(lines, 12)
        let blockers: [[String]] = [
            ["do you trust this workspace?", "trust and continue"],
            ["would you like to run the following command?", "yes, proceed (y)"],
            ["enter to select", "tab for an optional note"],
            ["enter to toggle", "esc to interrupt"],
            ["allow this stage once", "always allow in this workspace"],
            ["allow once", "allow for this session"],
            ["yes, proceed", "yes, don't ask again this session"],
        ]
        if blockers.contains(where: { containsAll(bottom, $0) }) { return .blocked }
        let overlays: [[String]] = [
            ["enter confirm", "esc go back"], ["enter save", "esc go back"],
            ["space toggle", "esc close", "type filter"],
        ]
        if overlays.contains(where: { containsAll(Array(bottom.suffix(8)), $0) }) { return nil }
        if bottom.contains(where: isMuseActivity) { return .working }
        let bottomFour = Array(bottom.suffix(4))
        guard bottomFour.count == 4, isRule(bottomFour[0]), isRule(bottomFour[2]),
            bottomFour[1].drop(while: \.isWhitespace).first == "❯",
            bottomFour[3].contains(" · ")
        else { return nil }
        return .idle
    }

    /// `◇ Thinking (1s · esc to interrupt)`, `◈ Calling tools (8s · …)`.
    private static func isMuseActivity(_ line: String) -> Bool {
        let trimmed = line.drop(while: \.isWhitespace)
        guard let glyph = trimmed.first, glyph == "◇" || glyph == "◈" else { return false }
        return trimmed.hasSuffix("esc to interrupt)")
    }

    // MARK: Lines

    /// A full-width `─` rule (Claude's box borders; `╌` dividers are not).
    private static func isRule(_ line: String) -> Bool {
        let trimmed = line.drop(while: \.isWhitespace)
        return trimmed.count >= 8 && trimmed.allSatisfy { $0 == "─" }
    }

    /// A row that starts a block: text at column zero.
    private static func isHead(_ line: String) -> Bool {
        guard let first = line.first else { return false }
        return !first.isWhitespace
    }

    /// The last `count` rows that are not blank, in order (herdr's
    /// `bottom_non_empty_lines`).
    private static func bottomNonEmpty(_ lines: [String], _ count: Int) -> [String] {
        Array(lines.filter { !$0.allSatisfy(\.isWhitespace) }.suffix(count))
    }

    /// Every needle in the rows, lowercased (herdr's `contains`).
    private static func containsAll(_ rows: [String], _ needles: [String]) -> Bool {
        let text = rows.joined(separator: "\n").lowercased()
        return needles.allSatisfy { text.contains($0) }
    }

    /// `31s`, `1m`, `2h`.
    private static func isDuration(_ word: Substring) -> Bool {
        guard let unit = word.last, "hms".contains(unit) else { return false }
        let number = word.dropLast()
        return !number.isEmpty && number.allSatisfy(\.isNumber)
    }

    private static func trimmingTrailingWhitespace(_ text: Substring) -> String {
        var end = text.endIndex
        while end > text.startIndex {
            let previous = text.index(before: end)
            guard text[previous].isWhitespace else { break }
            end = previous
        }
        return String(text[..<end])
    }

    private static func trimmingLeadingWhitespace(_ text: String) -> Substring {
        text.drop(while: \.isWhitespace)
    }
}

/// Which Agent panes get their screen read, and the status last reported
/// for each (design §4.6 blind spots). Pure: the transport passes time in.
///
/// A pane is read while its kind has rules and its `@waycar_status` is
/// unset, or is `working` with no `@waycar_seq` change for
/// ``Timing/staleWorking`` (Claude's Esc, Codex's plan questions), or is
/// `working` at all for a kind whose hooks report no approval
/// (`TmuxScreenDetector.readsWhileWorking`); each at most once per
/// ``Timing/readInterval``, at most ``Timing/panesPerTick`` per tick. A
/// hook change always wins: it drops the screen's verdict, as does an
/// Agent replaced in the pane (another kind or hook session) and a pane the
/// inventory stops listing.
///
/// A read is not tokened: its verdict applies to the pane as listed again
/// after the read, and only while that listing still names the Agent and
/// hook options the watch holds for it.
struct TmuxScreenVerdictMachine: StateMachine {
    struct Timing: Sendable, Equatable {
        var tick: Duration = .seconds(1)
        var readInterval: Duration = .seconds(3)
        var staleWorking: Duration = .seconds(20)
        var panesPerTick = 4
    }

    /// One Agent pane as the last inventory and `wc-status` push show it.
    struct Pane: Sendable, Equatable {
        /// Raw id, `%N`.
        let id: String
        let kind: String
        /// `@waycar_status` and `@waycar_seq`, raw; empty when unset.
        let hookStatus: String
        let hookSeq: String
        /// What the pane shows without a screen read: the hook's status,
        /// else a third-party plugin's, else Unknown.
        let baseStatus: AgentStatus
        /// The raw hook session, when known; a replacement ends the verdict.
        var session = ""
    }

    /// What the watch holds for one pane.
    struct Watched: Sendable, Equatable {
        let kind: String
        let session: String
        var hookStatus: String
        var hookSeq: String
        var hookSince: ContinuousClock.Instant
        var lastRead: ContinuousClock.Instant?
        var base: AgentStatus
        /// The screen's verdict in force, if any.
        var screenStatus: AgentStatus?
        /// What the projection was last told.
        var reported: AgentStatus
    }

    enum Event: Equatable, Sendable {
        /// A poll tick at `now` over the Agent panes the inventory lists.
        case tick([Pane], now: ContinuousClock.Instant, timing: Timing)
        /// One screen read of `pane`, as listed again after the read,
        /// classified as `status` (nil: unsure).
        case read(AgentStatus?, pane: Pane, now: ContinuousClock.Instant)
        /// The panes are gone: a closed transport, a lost link, a server
        /// with no session left.
        case forget
    }

    enum Effect: Equatable, Sendable {
        /// Read `pane`'s screen.
        case readScreen(Pane)
        /// Tell the projection the pane's status is now `status`.
        case report(AgentStatus, paneID: String)
    }

    /// Per raw pane id.
    private(set) var state: [String: Watched] = [:]

    init() {}

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .tick(let panes, let now, let timing):
            return due(panes, now: now, timing: timing).map(Effect.readScreen)
        case .read(let status, let pane, let now):
            guard let report = record(status, for: pane, now: now) else { return [] }
            return [.report(report, paneID: pane.id)]
        case .forget:
            state = [:]
            return []
        }
    }

    /// The panes due a screen read at `now`, least recently read first,
    /// each marked read (``Event/tick(_:now:timing:)``). Panes not listed
    /// are forgotten.
    mutating func due(
        _ panes: [Pane], now: ContinuousClock.Instant, timing: Timing
    ) -> [Pane] {
        var live = Set<String>()
        var candidates: [Pane] = []
        for pane in panes where TmuxScreenDetector.supports(kind: pane.kind) {
            guard live.insert(pane.id).inserted else { continue }
            observe(pane, now: now)
            candidates.append(pane)
        }
        state = state.filter { live.contains($0.key) }
        let ready = candidates.filter { pane in
            guard let entry = state[pane.id],
                Self.isEligible(entry, kind: pane.kind, now: now, timing: timing)
            else { return false }
            return entry.lastRead.map { now - $0 >= timing.readInterval } ?? true
        }
        let chosen = ready.sorted { lhs, rhs in
            switch (state[lhs.id]?.lastRead, state[rhs.id]?.lastRead) {
            case (nil, nil): return lhs.id < rhs.id
            case (nil, _): return true
            case (_, nil): return false
            case (let left?, let right?): return left == right ? lhs.id < rhs.id : left < right
            }
        }.prefix(max(0, timing.panesPerTick))
        for pane in chosen { state[pane.id]?.lastRead = now }
        return Array(chosen)
    }

    /// Applies one screen read of `pane` (as listed again after the read,
    /// ``Event/read(_:pane:now:)``). Returns the status to report when it
    /// differs from the last one.
    mutating func record(_ status: AgentStatus?, for pane: Pane, now: ContinuousClock.Instant)
        -> AgentStatus?
    {
        guard var entry = state[pane.id], entry.kind == pane.kind,
            entry.session == pane.session
        else { return nil }
        guard entry.hookStatus == pane.hookStatus, entry.hookSeq == pane.hookSeq else {
            // A hook moved while the screen was read: the hook wins.
            observe(pane, now: now)
            return nil
        }
        entry.base = pane.baseStatus
        if let status {
            entry.screenStatus = status
        } else if entry.screenStatus == .blocked {
            // The dialog is gone; what followed it is unclear.
            entry.screenStatus = nil
        }
        let effective = entry.screenStatus ?? entry.base
        defer { state[pane.id] = entry }
        guard effective != entry.reported else { return nil }
        entry.reported = effective
        return effective
    }

    /// The screen's verdict while the same Agent and hook options remain;
    /// nil when there is none, a hook moved or the Agent was replaced.
    func screenStatus(
        paneID: String, hookStatus: String, hookSeq: String, kind: String, session: String = ""
    ) -> AgentStatus? {
        guard let entry = state[paneID], entry.kind == kind, entry.session == session,
            entry.hookStatus == hookStatus, entry.hookSeq == hookSeq
        else { return nil }
        return entry.screenStatus
    }

    private mutating func observe(_ pane: Pane, now: ContinuousClock.Instant) {
        guard var entry = state[pane.id], entry.kind == pane.kind,
            entry.session == pane.session
        else {
            state[pane.id] = Watched(
                kind: pane.kind, session: pane.session,
                hookStatus: pane.hookStatus, hookSeq: pane.hookSeq, hookSince: now,
                lastRead: nil, base: pane.baseStatus, screenStatus: nil,
                reported: pane.baseStatus)
            return
        }
        if entry.hookStatus != pane.hookStatus || entry.hookSeq != pane.hookSeq {
            // The hook's own event (or a resync) already told the projection.
            entry.hookStatus = pane.hookStatus
            entry.hookSeq = pane.hookSeq
            entry.hookSince = now
            entry.screenStatus = nil
            entry.reported = pane.baseStatus
        }
        entry.base = pane.baseStatus
        state[pane.id] = entry
    }

    private static func isEligible(
        _ state: Watched, kind: String, now: ContinuousClock.Instant, timing: Timing
    ) -> Bool {
        guard let hooked = TmuxAgentDetection.waycarStatus(state.hookStatus) else { return true }
        guard hooked == .working else { return false }
        return TmuxScreenDetector.readsWhileWorking(kind: kind)
            || now - state.hookSince >= timing.staleWorking
    }
}
