import Foundation

/// The tmux Attach chain and the PTY exec that runs it (design §4.4, T21).
/// A mosh Attach wraps the same chain: `TmuxTransport.moshAttachCommand`
/// respells it for `HostSSHSession.moshBootstrapExecCommand`.
///
/// The phone gets its own grouped session, created detached and pointed at
/// the target before it attaches, all in one tmux chain, so the desk's
/// current window never changes size first; `destroy-unattached on` ends
/// that session when the phone detaches:
///
///     tmux -u new-session -d -t '$S' -s 'waycar-0a1b2c3d' \; set-option -t 'waycar-0a1b2c3d' destroy-unattached on \; select-window -t 'waycar-0a1b2c3d:@W' \; select-pane -t '%P' \; attach -t 'waycar-0a1b2c3d'
///
/// `-u` tells the tmux client the terminal is UTF-8: an SSH exec usually
/// carries no locale, and without one tmux draws non-ASCII text as `_`.
/// There is no `-d` (it would detach the desk, T13) and no Take Over.
///
/// The command runs under `/bin/sh -c` with ``HerdrHostPath``'s PATH, as
/// herdr's attach does, so a Homebrew or user-local `tmux` resolves and the
/// account shell (fish included) only sees one single-quoted word.
enum TmuxAttachCommand {
    /// The ids one Attach addresses, in tmux's raw spelling.
    struct Target: Sendable, Equatable, Hashable {
        /// `$1`: the session whose group the attach session joins.
        let sessionID: String
        /// `@2`: the window the attach session shows.
        let windowID: String
        /// `%3`: the pane selected in that window.
        let paneID: String

        init(sessionID: String, windowID: String, paneID: String) {
            self.sessionID = sessionID
            self.windowID = windowID
            self.paneID = paneID
        }
    }

    /// Every attach session's name starts with this; inventory hides them.
    static let attachSessionPrefix = "waycar-"

    /// `waycar-` plus 8 random lowercase hex digits.
    static func makeAttachSessionName() -> String {
        var generator = SystemRandomNumberGenerator()
        return makeAttachSessionName(using: &generator)
    }

    static func makeAttachSessionName<Generator: RandomNumberGenerator>(
        using generator: inout Generator
    ) -> String {
        let value = UInt32.random(in: .min ... .max, using: &generator)
        return attachSessionPrefix + String(format: "%08x", value)
    }

    /// True for a name ``makeAttachSessionName()`` could have made.
    static func isAttachSessionName(_ name: String) -> Bool {
        guard name.hasPrefix(attachSessionPrefix) else { return false }
        let suffix = name.dropFirst(attachSessionPrefix.count)
        return suffix.count == 8 && suffix.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// The tmux chain as argv, `tmux` first, with `;` as its own word. This
    /// is exactly what mosh-server receives after `--`, and what the PTY
    /// exec's `/bin/sh` passes to tmux.
    static func chainArguments(
        target: Target, attachSessionName: String
    ) throws -> [String] {
        try validate(target: target, attachSessionName: attachSessionName)
        let name = attachSessionName
        var words: [String] = [
            "tmux", "-u", "new-session", "-d", "-t", target.sessionID, "-s", name, ";",
            "set-option", "-t", name, "destroy-unattached", "on", ";",
        ]
        words += [
            "select-window", "-t", "\(name):\(target.windowID)", ";",
            "select-pane", "-t", target.paneID, ";",
            "attach",
        ]
        words += ["-t", name]
        return words
    }

    /// The chain as one shell command: `;` written `\;`, and every `-t`/`-s`
    /// value single-quoted, so `$S` never expands.
    static func chainShellCommand(
        target: Target, attachSessionName: String
    ) throws -> String {
        let arguments = try chainArguments(
            target: target, attachSessionName: attachSessionName)
        var words: [String] = []
        for (index, argument) in arguments.enumerated() {
            let isValue = index > 0 && ["-t", "-s"].contains(arguments[index - 1])
            if argument == ";" {
                words.append("\\;")
            } else if isValue {
                words.append("'\(argument)'")
            } else {
                words.append(argument)
            }
        }
        return words.joined(separator: " ")
    }

    /// The PTY exec: PATH fix-up, the bootstrap marker
    /// (``AttachBootstrapHandshake``) printed last, then `exec` of the
    /// chain, all inside `/bin/sh -c '…'`.
    static func execCommand(
        target: Target, attachSessionName: String
    ) throws -> String {
        let chain = try chainShellCommand(
            target: target, attachSessionName: attachSessionName)
        let script = "\(HerdrHostPath.pathExport); "
            + "printf \"\(AttachBootstrapHandshake.markerPrintfFormat)\"; "
            + "exec \(chain)"
        return "/bin/sh -c \(shellSingleQuoted(script))"
    }

    // MARK: Helpers

    /// Ids must be tmux's own (`$`, `@`, `%` and digits) and the name one
    /// of ours, so nothing in the chain needs quoting beyond `$`.
    private static func validate(target: Target, attachSessionName: String) throws {
        guard isID(target.sessionID, sigil: "$"),
            isID(target.windowID, sigil: "@"),
            isID(target.paneID, sigil: "%"),
            isAttachSessionName(attachSessionName)
        else {
            throw TransportError.channelFailed(
                detail: "tmux attach target cannot be quoted for the remote command")
        }
    }

    private static func isID(_ text: String, sigil: Character) -> Bool {
        guard text.first == sigil else { return false }
        let digits = text.dropFirst()
        return !digits.isEmpty && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// POSIX single quotes, each `'` written `'\''`.
    private static func shellSingleQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
