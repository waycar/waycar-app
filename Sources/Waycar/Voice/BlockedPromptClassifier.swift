import Foundation

/// What a Blocked Agent's screen is asking, as far as the car may act on it
/// (docs/design/carplay.md §5 per-kind unblock map). herdr reports `blocked`
/// for a permission prompt and a trust dialog alike, so the car reads the
/// screen itself.
enum BlockedPrompt: Equatable, Sendable {
    /// A command approval whose selected answer is option 1, the plain Yes.
    /// `command` is exactly what the screen shows; `isLossless` says it can
    /// be spoken or shown in full (one line, nothing elided, nothing
    /// invisible that could make it read differently from what runs).
    case permission(command: String, isLossless: Bool)
    /// A question with options (claude AskUserQuestion, an MCP input
    /// request, a codex plan question).
    case question
    /// A codex child process asking `[y/n]`.
    case yesNo
    /// A folder-trust dialog. Enter accepts trust: never answered by voice.
    case trust
    /// Anything else: an unsupported kind, an option-1 label that grants
    /// more than this once, plan approval, the cursor off option 1.
    case unknown
}

/// What the car may do about a Blocked prompt (§5 Safety rules 1, 6).
enum CarApproval: Equatable, Sendable {
    /// Allow (Enter) and Deny (Esc).
    case allow
    /// Deny and Hold only: no voice Allow.
    case hold(HoldReason)
    /// Spoken only; nothing sent.
    case readOnly
}

enum HoldReason: Equatable, Sendable {
    /// A risk pattern matched; the associated value is speakable.
    case risky(String)
    /// The command cannot be read out or shown in full, exactly as it runs.
    case notLossless
}

/// Pure, Backend-neutral: classifies a Blocked Agent's visible screen
/// (`ConsoleStore.readVisibleScreen`, ANSI stripped) with
/// `TmuxScreenDetector`'s claude and codex rules, narrowed to what the car
/// may answer. Anything it is unsure of is `.unknown`, which is read-only.
enum BlockedPromptClassifier {
    static func classify(kind: String, screen: String) -> BlockedPrompt {
        let lines = TmuxScreenDetector.screenLines(screen)
        switch kind {
        case SupportedAgentKind.claude.rawValue: return classifyClaude(lines)
        case SupportedAgentKind.codex.rawValue: return classifyCodex(lines)
        default: return .unknown
        }
    }

    /// Allow only for a lossless plain-Yes permission with no risk pattern.
    static func carApproval(for prompt: BlockedPrompt) -> CarApproval {
        guard case .permission(let command, let isLossless) = prompt else { return .readOnly }
        if let reason = riskReason(command: command) { return .hold(.risky(reason)) }
        guard isLossless else { return .hold(.notLossless) }
        return .allow
    }

    // MARK: Claude Code

    /// Claude's dialogs sit after the last full-width `─` rule; the
    /// permission dialog frames its command between two `╌` dividers under
    /// a `Bash command` header and asks `Do you want to proceed?`.
    private static func classifyClaude(_ lines: [String]) -> BlockedPrompt {
        let lastRule = lines.lastIndex(where: isRule)
        let footer = Array(lines[(lastRule.map { $0 + 1 } ?? 0)...])
        let text = footer.joined(separator: "\n").lowercased()
        if text.contains("do you trust the files in this folder?")
            || text.contains("is this a project you created or one you trust?")
        {
            return .trust
        }
        // Plan approval (ExitPlanMode) escalates to auto-accept edits.
        if text.contains("plan") && text.contains("would you like to proceed") {
            return .unknown
        }
        if text.contains("do you want to proceed?"), text.contains("bash command") {
            guard selectedOptionOneLabel(in: footer, cursor: "❯") == "Yes",
                let command = claudeCommand(in: footer)
            else { return .unknown }
            return .permission(command: command.text, isLossless: command.isLossless)
        }
        if text.contains("esc to cancel"),
            text.contains("enter to select") || text.contains("requests your input")
        {
            return .question
        }
        return .unknown
    }

    /// The rows between the first and last `╌` divider above `Do you want
    /// to proceed?`. A command row can itself be all `╌`, so more than two
    /// dividers there is ambiguous: the whole span is kept (for the risk
    /// check) and marked not lossless.
    private static func claudeCommand(in footer: [String]) -> Command? {
        let question = footer.firstIndex {
            $0.lowercased().contains("do you want to proceed?")
        } ?? footer.endIndex
        let dividers = footer[..<question].indices.filter { isDivider(footer[$0]) }
        guard let first = dividers.first, let last = dividers.last, first < last,
            let command = command(from: Array(footer[(first + 1)..<last]))
        else { return nil }
        guard dividers.count == 2 else { return Command(text: command.text, isLossless: false) }
        return command
    }

    // MARK: Codex

    /// Codex replaces its composer with the approval: `Would you like to
    /// run the following command?`, the command after `$ `, then options
    /// with `›` on the selected one.
    private static func classifyCodex(_ lines: [String]) -> BlockedPrompt {
        let nonEmpty = lines.filter { !$0.allSatisfy(\.isWhitespace) }
        let recent = nonEmpty.suffix(20).joined(separator: "\n").lowercased()
        if recent.contains("do you trust the contents of this directory?")
            || (recent.contains("trust this folder?")
                && (recent.contains("trust and continue") || recent.contains("enter continue")))
        {
            return .trust
        }
        if let header = lines.lastIndex(where: {
            $0.lowercased().contains("would you like to run the following command?")
        }) {
            let below = Array(lines[(header + 1)...])
            guard let label = selectedOptionOneLabel(in: below, cursor: "›"),
                label == "Yes, proceed" || label == "Yes, proceed (y)",
                let command = codexCommand(in: below)
            else { return .unknown }
            return .permission(command: command.text, isLossless: command.isLossless)
        }
        let tail = nonEmpty.suffix(12).joined(separator: "\n").lowercased()
        if tail.contains("enter to submit answer") || tail.contains("enter to submit all") {
            return .question
        }
        if nonEmpty.suffix(6).joined(separator: "\n").lowercased().contains("[y/n]") {
            return .yesNo
        }
        return .unknown
    }

    /// From the `$ ` row to the selected `› 1.` row. An option-looking row
    /// in between may be a command line, so it stays in the text (for the
    /// risk check) and makes the command not lossless.
    private static func codexCommand(in below: [String]) -> Command? {
        guard
            let start = below.firstIndex(where: {
                $0.drop(while: \.isWhitespace).hasPrefix("$ ")
            }),
            let end = below[start...].firstIndex(where: {
                let trimmed = $0.drop(while: \.isWhitespace)
                return trimmed.first == "›"
                    && optionNumber(of: String(trimmed.dropFirst())) == 1
            })
        else { return nil }
        var rows = Array(below[start..<end])
        let hasOptionRow = rows.dropFirst().contains(where: isOptionRow)
        rows[0] = String(rows[0].drop(while: \.isWhitespace).dropFirst(2))
        guard let command = command(from: rows) else { return nil }
        guard !hasOptionRow else { return Command(text: command.text, isLossless: false) }
        return command
    }

    // MARK: Shared

    private struct Command {
        let text: String
        let isLossless: Bool
    }

    /// The command's rows, trimmed; blank rows dropped. More than one row
    /// (a wrapped or multi-line command), any elision, or any scalar that
    /// does not show as itself is not lossless.
    private static func command(from rows: [String]) -> Command? {
        let kept = rows.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !kept.isEmpty else { return nil }
        let text = kept.joined(separator: "\n")
        return Command(
            text: text,
            isLossless: kept.count == 1 && !looksShortened(text) && !hasHiddenScalars(text))
    }

    /// Whether `command` has a scalar that is invisible or reorders what is
    /// displayed: a format scalar (zero-width, bidi embedding/override/
    /// isolate, direction mark, BOM), a control, any separator but the plain
    /// space, or another default-ignorable one (Hangul filler, variation
    /// selector). The screen would then show something other than what runs.
    private static func hasHiddenScalars(_ command: String) -> Bool {
        command.unicodeScalars.contains { scalar in
            guard scalar != " " else { return false }
            switch scalar.properties.generalCategory {
            case .format, .control, .spaceSeparator, .lineSeparator, .paragraphSeparator:
                return true
            default:
                return scalar.properties.isDefaultIgnorableCodePoint
            }
        }
    }

    /// `…`, `...`, or a `+N lines` fold: the screen shows less than runs.
    static func looksShortened(_ command: String) -> Bool {
        if command.contains("…") || command.contains("...") { return true }
        return command.range(
            of: #"\+\s*\d+\s+(more\s+)?lines?"#, options: [.regularExpression, .caseInsensitive])
            != nil
    }

    /// The label of option 1 when the cursor glyph is on it; nil when the
    /// cursor is on another row or no option 1 is shown. Every option row is
    /// checked, so a second cursor elsewhere also yields nil.
    private static func selectedOptionOneLabel(in lines: [String], cursor: Character) -> String? {
        var label: String?
        for line in lines {
            let trimmed = line.drop(while: \.isWhitespace)
            let isSelected = trimmed.first == cursor
            let row = isSelected ? trimmed.dropFirst().drop(while: \.isWhitespace) : trimmed
            guard let number = optionNumber(of: String(row)) else { continue }
            if isSelected {
                guard number == 1, label == nil else { return nil }
                let body = row.drop(while: \.isNumber).dropFirst(2)
                label = body.trimmingCharacters(in: .whitespaces)
            }
        }
        return label
    }

    /// An option row, selected (`› 1. …`, `❯ 1. …`) or not (`2. …`).
    private static func isOptionRow(_ line: String) -> Bool {
        let trimmed = line.drop(while: \.isWhitespace)
        let row = trimmed.first == "›" || trimmed.first == "❯" ? trimmed.dropFirst() : trimmed
        return optionNumber(of: String(row)) != nil
    }

    /// `1. Yes` → 1, `2. No` → 2; a cursor glyph must be dropped first.
    private static func optionNumber(of line: String) -> Int? {
        let trimmed = line.drop(while: \.isWhitespace)
        let digits = trimmed.prefix(while: \.isNumber)
        guard !digits.isEmpty, trimmed.dropFirst(digits.count).hasPrefix(". ") else { return nil }
        return Int(digits)
    }

    private static func isRule(_ line: String) -> Bool {
        let trimmed = line.drop(while: \.isWhitespace)
        return trimmed.count >= 8 && trimmed.allSatisfy { $0 == "─" }
    }

    private static func isDivider(_ line: String) -> Bool {
        let trimmed = line.drop(while: \.isWhitespace)
        return trimmed.count >= 8 && trimmed.allSatisfy { $0 == "╌" }
    }

    // MARK: Risk

    /// A short speakable reason when `command` matches a risk pattern
    /// (S6): checked on the full command as the screen shows it, never a
    /// normalized or shortened copy.
    static func riskReason(command: String) -> String? {
        for (pattern, reason) in riskPatterns
        where command.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
            return reason
        }
        return nil
    }

    private static let riskPatterns: [(String, String)] = [
        (#"\brm\s+(-\S*\s+)*-[a-z]*(r[a-z]*f|f[a-z]*r)"#, "it deletes files recursively"),
        (#"\brm\s+.*(-r\b|-R\b|--recursive).*(-f\b|--force)"#, "it deletes files recursively"),
        (#"\brm\s+.*(-f\b|--force).*(-r\b|-R\b|--recursive)"#, "it deletes files recursively"),
        (#"\bpush\b.*(\s--force(-with-lease)?\b|\s-f\b|\s\+\S)"#, "it force-pushes"),
        (#"\breset\s+(.*\s)?--hard\b"#, "it hard-resets"),
        (#"\b(drop|truncate)\b"#, "it drops or truncates data"),
        (#"deploy"#, "it deploys"),
        (#"(^|[^a-z])prod(uction)?([^a-z]|$)"#, "it touches production"),
        (#"\bsudo\b"#, "it runs as root"),
        (#"\b(curl|wget)\b.*\|\s*(sudo\s+)?(ba|z|da)?sh\b"#, "it pipes a download into a shell"),
        (#"\.ssh\b|\.env\b|id_rsa|id_ed25519|\.aws\b|credentials|\.netrc|keychain"#,
            "it touches secrets"),
    ]
}
