import Foundation

/// Control-mode command strings, one command each, plus the quoting tmux's
/// command parser needs (design §4.3, T15).
///
/// Callers join several commands into one control line with ` ; `; a bare
/// `;` word is tmux's separator, so every builder quotes user text as one
/// word. Targets take tmux's raw ids (`$1`, `@2`, `%3`), not the app's
/// `tmux:` ids.
///
/// Three hazards every builder handles:
/// - A raw LF ends the control line, and whatever follows would run as a
///   new command. Text holding LF, CR or NUL is double-quoted with escapes
///   (``argument(_:)``).
/// - Outside single quotes tmux expands `$VAR`, a leading `~` and
///   `#`-comments; inside double quotes `$` and a leading `~` still expand.
/// - Window and session names and `-c` directories are format-expanded,
///   `#(…)` included, which runs a shell command on the Host (verified on
///   3.7c for `rename-window`, `rename-session`, `new-window -n -c` and
///   `new-session -s -c`). Those go through ``formatLiteral(_:)``. Option
///   values, environment, buffer text, `send-keys -l` text and the
///   shell-command argument are not expanded.
enum TmuxCommand {
    // MARK: Quoting

    /// `'…'`, with each `'` written `'\''`. tmux takes everything inside
    /// single quotes literally, but a raw LF still ends the control line:
    /// text that may hold one goes through ``argument(_:)``.
    static func singleQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Double-quoted for tmux, as a Composer draft needs it: `\`, `"`, `$`
    /// and every `~` escaped (a leading `~` is tilde-expanded otherwise, and
    /// `\~` is safe anywhere), LF written `\n` and CR `\r`, so the control
    /// line stays one line whatever the draft holds. NUL is dropped: tmux
    /// arguments are C strings, and a NUL would cut off the rest of the
    /// text (verified). Other bytes pass through unchanged.
    static func doubleQuotedDraft(_ text: String) -> String {
        var quoted = "\""
        quoted.reserveCapacity(text.utf8.count + 2)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": quoted += "\\\\"
            case "\"": quoted += "\\\""
            case "$": quoted += "\\$"
            case "~": quoted += "\\~"
            case "\n": quoted += "\\n"
            case "\r": quoted += "\\r"
            case "\0": continue
            default: quoted.unicodeScalars.append(scalar)
            }
        }
        return quoted + "\""
    }

    /// One tmux word holding `text` exactly (NUL aside): single-quoted, or
    /// ``doubleQuotedDraft(_:)`` when the text holds LF, CR or NUL, which
    /// single quotes cannot carry over a control line. tmux itself refuses
    /// control characters in window and session names.
    static func argument(_ text: String) -> String {
        let needsEscapes = text.unicodeScalars.contains { $0 == "\n" || $0 == "\r" || $0 == "\0" }
        return needsEscapes ? doubleQuotedDraft(text) : singleQuoted(text)
    }

    /// ``argument(_:)`` for a word tmux format-expands: each `#` doubled,
    /// so `#{…}` and `#(…)` arrive as text.
    static func formatLiteral(_ text: String) -> String {
        argument(text.replacingOccurrences(of: "#", with: "##"))
    }

    /// A target word: pane and window ids bare (`%3`, `@2`), as tmux
    /// prints them; anything else, session ids (`$1`) included, quoted.
    static func target(_ target: String) -> String {
        isID(target, sigils: ["%", "@"]) ? target : argument(target)
    }

    /// A key, option or buffer name: bare when it is a plain word (letters,
    /// digits, `_`, `@`, `-`, not starting with `-`), quoted otherwise.
    static func word(_ text: String) -> String {
        isPlainWord(text) ? text : argument(text)
    }

    // MARK: Input

    /// `set-buffer -b <name> -- "<text>"`: stores a draft byte-exact (T15).
    /// tmux stores nothing for empty text, so a later `paste-buffer` of that
    /// name fails; callers send no delivery for an empty draft.
    static func setBuffer(name: String, text: String) -> String {
        "set-buffer -b \(word(name)) -- \(doubleQuotedDraft(text))"
    }

    /// `paste-buffer -p -d -b <name> -t <target>`: bracketed when the pane's
    /// app asked for it, and the buffer deleted afterwards.
    static func pasteBuffer(name: String, target: String) -> String {
        "paste-buffer -p -d -b \(word(name)) -t \(Self.target(target))"
    }

    /// `send-keys -t <target> <keys…>`. `keys` are tmux key names already
    /// checked by ``TmuxKeys``: tmux types an unknown name literally (T20).
    static func sendKeys(target: String, keys: [String]) -> String {
        let separator = keys.contains { $0.hasPrefix("-") } ? " --" : ""
        let words = keys.map { " " + word($0) }.joined()
        return "send-keys -t \(Self.target(target))\(separator)\(words)"
    }

    /// `send-keys -t <target> -H <hex…>`: raw bytes, for keys without a tmux
    /// name (tmux 3.0+).
    static func sendKeysHex(target: String, bytes: [UInt8]) -> String {
        let hex = bytes.map { " " + String(format: "%02x", $0) }.joined()
        return "send-keys -t \(Self.target(target)) -H\(hex)"
    }

    /// `send-keys -l -t <target> -- '<text>'`: types `text` literally.
    static func sendKeysLiteral(target: String, text: String) -> String {
        "send-keys -l -t \(Self.target(target)) -- \(argument(text))"
    }

    // MARK: Panes, windows, sessions

    /// `capture-pane -p -J -S -<lines> -t <target>`: the last `lines` of
    /// history plus the screen, wrapped lines joined.
    static func capturePane(target: String, lines: Int) -> String {
        "capture-pane -p -J -S -\(max(0, lines)) -t \(Self.target(target))"
    }

    static func killPane(target: String) -> String {
        "kill-pane -t \(Self.target(target))"
    }

    static func killWindow(target: String) -> String {
        "kill-window -t \(Self.target(target))"
    }

    static func renameWindow(target: String, name: String) -> String {
        "rename-window -t \(Self.target(target)) -- \(formatLiteral(name))"
    }

    static func renameSession(target: String, name: String) -> String {
        "rename-session -t \(Self.target(target)) -- \(formatLiteral(name))"
    }

    static func selectWindow(target: String) -> String {
        "select-window -t \(Self.target(target))"
    }

    /// `set -p -t <target> -- <name> <value>`: a pane user option such as
    /// `@waycar_status`. The value is stored as given, unexpanded.
    static func setPaneOption(target: String, name: String, value: String) -> String {
        "set -p -t \(Self.target(target)) -- \(word(name)) \(argument(value))"
    }

    static func unsetPaneOption(target: String, name: String) -> String {
        "set -p -u -t \(Self.target(target)) -- \(word(name))"
    }

    /// herdr's "seen" for tmux: a `done` pane becomes `idle`, any other
    /// value is written back as it is, in one server-side step (design
    /// §4.3). One `%begin`/`%end` block: `if -F` would add a second block
    /// for its inner command and shift every later reply. An unset option
    /// would come back set to the empty string, so the caller sends this
    /// only to a pane it has just read as `done`.
    static func focusDoneToIdle(paneTarget: String) -> String {
        let value = "#{?#{==:#{@waycar_status},done},idle,#{@waycar_status}}"
        return "set-option -p -F -t \(target(paneTarget)) @waycar_status \(argument(value))"
    }

    /// `display -p '<format>'`, evaluated for `target` when given. The
    /// format is expanded on purpose.
    static func display(format: String, target: String? = nil) -> String {
        let scope = target.map { " -t \(Self.target($0))" } ?? ""
        return "display -p\(scope) \(argument(format))"
    }

    /// `refresh-client -B '<name>::<format>'`: a format subscription whose
    /// changes arrive as `%subscription-changed` (T7).
    static func subscribe(name: String, format: String) -> String {
        "refresh-client -B \(argument(name + "::" + format))"
    }

    /// `new-window -d -t '$S:' -c <cwd> -n <name> -e K=V… -P -F '<format>'
    /// '<command>'`: a background window at the end of the session, printing
    /// `printFormat` for it. With no `command` the window runs the default
    /// shell. Environment is written in key order.
    static func newWindow(
        sessionTarget: String,
        cwd: String? = nil,
        name: String? = nil,
        environment: [String: String] = [:],
        command: String? = nil,
        printFormat: String
    ) -> String {
        var words = ["new-window -d -t", target(sessionTarget + ":")]
        words += directoryOption(cwd)
        if let name { words += ["-n", formatLiteral(name)] }
        words += environmentOptions(environment)
        words += ["-P -F", argument(printFormat)]
        if let command { words += ["--", argument(command)] }
        return words.joined(separator: " ")
    }

    /// `new-session -d -s <name> -c <cwd> -e K=V… -P -F '<format>'
    /// ['<command>']`: a detached session, printing `printFormat` for it.
    static func newSession(
        name: String,
        cwd: String? = nil,
        environment: [String: String] = [:],
        command: String? = nil,
        printFormat: String
    ) -> String {
        var words = ["new-session -d -s", formatLiteral(name)]
        words += directoryOption(cwd)
        words += environmentOptions(environment)
        words += ["-P -F", argument(printFormat)]
        if let command { words += ["--", argument(command)] }
        return words.joined(separator: " ")
    }

    /// The shell-level window command that starts an agent through the
    /// user's login shell and leaves a login shell behind when it exits
    /// (T22): `exec "$SHELL" -lic '<agentCommand>; exec "$SHELL" -l'`, the
    /// agent command's own `'` written `'\''`. Pass the result through
    /// ``newWindow(sessionTarget:cwd:name:environment:command:printFormat:)``,
    /// which quotes it for tmux.
    static func loginShellWrapper(agentCommand: String) -> String {
        let script = agentCommand + "; exec \"$SHELL\" -l"
        return "exec \"$SHELL\" -lic '" + script.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Put the Launch Tag in the creation command, before the Agent or
    /// shell can run. An untargeted `set-option` after `new-window -d` on
    /// the control line targets the old pane (3.2a, 3.4 and 3.7c), not the
    /// new one. Inside the pane, TMUX_PANE and TMUX identify it exactly.
    static func taggedLaunchCommand(_ command: String?, launchID: UUID?) -> String? {
        guard let launchID else { return command }
        let script = HerdrHostPath.pathExport
            + "; tmux set-option -p -t \"$TMUX_PANE\" @waycar_launch "
            + launchID.uuidString + " || exit; " + (command ?? "exec \"$SHELL\" -l")
        // The account shell may be fish; the PATH export is POSIX sh, like
        // the transport's control commands, and precedes the login shell.
        return "/bin/sh -c " + singleQuoted(script)
    }

    // MARK: Replay

    /// Whether running `command` twice leaves what running it once does, so
    /// a line tmux's `%exit` left unanswered (below 3.6, design §1 T24) may
    /// go out again: reads, kills (a second finds its target gone and
    /// answers `can't find …`, which callers take as done), renames,
    /// selects and option sets. Input, pastes, creation and pane moves never
    /// are (ADR 0018). Judged by the verb of Waycar's own commands, none of
    /// which appends to an option (`set-option -a`).
    static func isIdempotent(_ command: String) -> Bool {
        guard let verb = command.split(separator: " ", maxSplits: 1).first else { return false }
        return idempotentVerbs.contains(String(verb))
    }

    private static let idempotentVerbs: Set<String> = [
        "capture-pane", "display", "list-panes", "list-sessions", "list-windows",
        "kill-pane", "kill-session", "kill-window", "rename-session", "rename-window",
        "select-pane", "select-window", "set-option",
    ]

    // MARK: Helpers

    private static func directoryOption(_ cwd: String?) -> [String] {
        cwd.map { ["-c", formatLiteral($0)] } ?? []
    }

    private static func environmentOptions(_ environment: [String: String]) -> [String] {
        environment.sorted { $0.key < $1.key }
            .flatMap { ["-e", argument($0.key + "=" + $0.value)] }
    }

    private static func isID(_ text: String, sigils: Set<Character>) -> Bool {
        guard let sigil = text.first, sigils.contains(sigil) else { return false }
        let digits = text.dropFirst()
        return !digits.isEmpty && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private static func isPlainWord(_ text: String) -> Bool {
        guard let first = text.first, first != "-" else { return false }
        return text.allSatisfy { character in
            character.isASCII
                && (character.isLetter || character.isNumber
                    || character == "_" || character == "@" || character == "-")
        }
    }
}
