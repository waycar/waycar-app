import Foundation

/// The exec lines Waycar runs for herdr-core (design §5 and §8): the
/// connection that carries RPC and events, and the PTY attach. Both are
/// `/bin/sh -c` scripts whose Host values arrive as positional arguments
/// (`ShellWord`-quoted), never spliced into the script, so the account shell
/// (fish included) sees one plain command line.
///
/// herdr-core's own client runs `sh -c 'p=$(command -v herdr-core) ||
/// p=$HOME/.local/bin/herdr-core; [ -x "$p" ] || { echo "herdr-core is not
/// installed here" >&2; exit 127; }; exec "$p" connect'`. These lines keep
/// that shape and add a side-effect-free liveness probe (#389), the Host's
/// login PATH, and a marker printed
/// just before `exec`, so login noise (a `.bashrc` that echoes above its
/// non-interactive guard, C21) can be discarded.
enum CoreConnectCommand {
    /// What `exit 127` is accompanied by when no herdr-core binary is found.
    static let notInstalledText = "herdr-core is not installed here"
    static let notRunningText = "herdr-core is not running here"
    /// Reserved by Waycar; core's CLI uses 1–8 for its failures.
    static let notRunningStatus: Int32 = 125

    /// Mirrors plugin/rust/core.rs `socket_path`: no core command is safe
    /// for discovery. Config-file socket overrides are not read. Pin the
    /// result so the probe, connect and explicit start use the same socket.
    static let socketScript =
        "s=${HC_SESSION:-default}; s=\"${s#\"${s%%[![:space:]]*}\"}\"; "
        + "s=\"${s%\"${s##*[![:space:]]}\"}\"; s=${s:-default}; "
        + "h=${HC_SOCKET:-${HC_TERMINAL_SOCKET:-}}; "
        + "if [ -z \"$h\" ]; then "
        + "case ${XDG_RUNTIME_DIR:-} in /*) h=\"$XDG_RUNTIME_DIR/herdr-core/$s.sock\";; "
        + "*) r=\"/run/user/$(id -u)/herdr-core\"; "
        + "if [ -d \"$r\" ]; then h=\"$r/$s.sock\"; else "
        + "case ${XDG_STATE_HOME:-} in /*) r=$XDG_STATE_HOME;; *) r=\"$HOME/.local/state\";; esac; "
        + "h=\"$r/herdr-core/$s/$s.sock\"; fi;; esac; fi; export HC_SOCKET=\"$h\"; "

    /// A plain Unix connect only, never `hc`: Perl's `IO::Socket::UNIX`, else
    /// (off macOS, whose `python3` may be the CLT stub that opens a dialog)
    /// Python's `socket`; each answers 0 for a listener and 1 for none, and
    /// any other status (no such interpreter or module) falls through. A Host
    /// with neither gets the socket-file test, which a stale socket left by a
    /// crash passes: there `herdr-core connect` would still start a core.
    static let runningProbeScript =
        "w=2; if command -v perl >/dev/null 2>&1; then "
        + "perl -MIO::Socket::UNIX -e \"exit(IO::Socket::UNIX->new(Peer => pop, Type => SOCK_STREAM) ? 0 : 1)\" \"$HC_SOCKET\" 2>/dev/null; "
        + "w=$?; fi; "
        + "if [ $w -gt 1 ] && [ \"$(uname -s)\" != Darwin ] && command -v python3 >/dev/null 2>&1; then "
        + "python3 -c \"import socket,sys; socket.socket(socket.AF_UNIX).connect(sys.argv[1])\" \"$HC_SOCKET\" 2>/dev/null; "
        + "w=$?; fi; "
        + "if [ $w -gt 1 ]; then [ -S \"$HC_SOCKET\" ]; w=$?; fi; [ $w = 0 ]"

    /// The line the connect command prints just before it execs
    /// `herdr-core connect`; the client discards everything up to it.
    static let connectMarker = "@@WAYCAR-CORE-CONNECT@@"

    /// The `PATH` the line exports. With a resolved login PATH: that, then
    /// the usual directories (a directory that did not exist when the PATH
    /// was resolved, `~/.local/bin` before the first install, is still
    /// searched, C22). Without one: the usual directories, then the SSH
    /// session's own PATH (design §5). The explicit start uses this same
    /// PATH: the first caller's environment is frozen into core (C5).
    private static let pathScript =
        "if [ -n \"$1\" ]; then "
        + "export PATH=\"$1:\(HerdrHostPath.extraPATH):\(HerdrHostPath.coreExtraPATH)\"; "
        + "else export PATH=\"\(HerdrHostPath.extraPATH):\(HerdrHostPath.coreExtraPATH):$PATH\"; fi; "

    /// The binary: the detected absolute path when there is one, else the
    /// first `herdr-core` on PATH, else the installer's directory. Exit 127
    /// with `notInstalledText` on stderr when there is none.
    private static let binaryScript =
        "p=\"$2\"; if [ -z \"$p\" ]; then p=$(command -v herdr-core) "
        + "|| p=\"$HOME/.local/bin/herdr-core\"; fi; "
        + "[ -x \"$p\" ] || { echo \"\(notInstalledText)\" >&2; exit 127; }; "

    /// The exec that opens herdr-core's framed connection (`hc connect`):
    /// no PTY, stdout carries the protocol. `path` is the binary detection
    /// found; `loginPATH` the Host's resolved login PATH.
    static func connect(path: String?, loginPATH: String?) -> String {
        "/bin/sh -c '\(pathScript)\(binaryScript)\(socketScript)"
            + "\(runningProbeScript) || { echo \"\(notRunningText)\" >&2; exit \(notRunningStatus); }; "
            + "printf \"%s\\n\" \"\(connectMarker)\"; exec \"$p\" connect' core "
            + "\(ShellWord.quoted(loginPATH ?? "")) \(ShellWord.quoted(path ?? ""))"
    }

    /// The login-session job's start. The binary's path reaches the job in
    /// its env file and is unset before `hc` runs, so the core, which
    /// freezes its starter's environment (C5), never hands it to a terminal.
    static let jobStart =
        "c=$WAYCAR_CORE_PATH && unset WAYCAR_CORE_PATH && \"$c\" server status >/dev/null"

    /// Starts core once and returns; only a Start or Install tap may run it.
    /// `server status` starts a detached core and waits until it answers.
    static func start(path: String?, loginPATH: String?, inLoginSession: Bool) -> HostServerStartExec {
        let plain = "\"$p\" server status >/dev/null < /dev/null"
        let login = inLoginSession
            ? HostLoginSessionStart.script(
                variables: [
                    "HC_SOCKET=\"$HC_SOCKET\"", "WAYCAR_CORE_PATH=\"$p\"",
                    "${HC_SESSION+HC_SESSION=\"$HC_SESSION\"}",
                    "${XDG_RUNTIME_DIR+XDG_RUNTIME_DIR=\"$XDG_RUNTIME_DIR\"}",
                    "${XDG_STATE_HOME+XDG_STATE_HOME=\"$XDG_STATE_HOME\"}",
                ], ready: "{ \(runningProbeScript); }")
            : ""
        return HostServerStartExec(
            command: "/bin/sh -c '\(pathScript)\(binaryScript)\(socketScript)\(login)\(plain)' core "
                + "\(ShellWord.quoted(loginPATH ?? "")) \(ShellWord.quoted(path ?? ""))",
            input: inLoginSession
                ? Data(HostLoginSessionStart.job(command: jobStart).utf8)
                : Data())
    }

    /// The exec of one terminal's PTY attach (`herdr-core attach <address>`).
    /// It probes the socket first, as the connect line does: a core that
    /// stopped after the connection came up exits 125 (`.coreNotRunning`)
    /// rather than `attach` starting a new one. It prints the same APC marker the herdr and tmux attach lines do
    /// (`AttachBootstrapHandshake`), which the Attach's output gate drops
    /// everything before. Throws when `address` could not be quoted safely:
    /// `'`, `\` or a control character, as for herdr.
    static func attach(address: String, path: String?, loginPATH: String?) throws -> String {
        guard isQuotable(address) else {
            throw TransportError.channelFailed(
                detail: "attach target cannot be quoted for the remote command")
        }
        return "/bin/sh -c '\(pathScript)\(binaryScript)\(socketScript)"
            + "\(runningProbeScript) || { echo \"\(notRunningText)\" >&2; exit \(notRunningStatus); }; "
            + "printf \"\(AttachBootstrapHandshake.markerPrintfFormat)\"; "
            + "exec \"$p\" attach \"$3\"' core "
            + "\(ShellWord.quoted(loginPATH ?? "")) \(ShellWord.quoted(path ?? "")) "
            + ShellWord.quoted(address)
    }

    /// Whether `command` is one of these lines, for mapping its exit 127 and
    /// 125 (`HerdrHostPath.missingBinaryError`).
    static func isCoreLine(_ command: String) -> Bool {
        command.contains(notInstalledText)
    }

    private static func isQuotable(_ address: String) -> Bool {
        !address.isEmpty
            && !address.contains(where: { character in
                character == "'" || character == "\\"
                    || character.unicodeScalars.contains(where: {
                        CharacterSet.controlCharacters.contains($0)
                    })
            })
    }
}

/// The Host's login PATH, resolved once per Host over an SSH exec of its
/// login shell and remembered (`HostConnectionMemory.loginPATH`). A core a
/// user explicitly starts gets it (design §5, decision 7).
enum CoreLoginPath {
    private static let marker = "@@WAYCAR-LOGIN-PATH@@"

    /// `$SHELL -lc 'printf <marker>%s<marker> "$PATH"'`, run under `/bin/sh`
    /// so the script text reaches the login shell untouched whatever it is.
    /// Marker-delimited: whatever the login shell's startup files print is
    /// ignored.
    static let command =
        "/bin/sh -c 'exec \"${SHELL:-/bin/sh}\" -lc \"$1\"' login "
        + ShellWord.quoted("printf \"\(marker)%s\(marker)\" \"$PATH\"")

    static func resolve(on session: any HostSSHServices, timeout: Duration) async -> String? {
        guard let result = try? await session.runExec(command, input: Data(), timeout: timeout),
            result.exitStatus == 0
        else { return nil }
        return parse(String(decoding: result.stdout, as: UTF8.self))
    }

    /// The PATH between the markers, or nil when the output has none, it is
    /// empty, or it holds anything that could not be a PATH (a newline, a
    /// control character).
    static func parse(_ output: String) -> String? {
        guard let start = output.range(of: marker),
            let end = output.range(of: marker, range: start.upperBound..<output.endIndex)
        else { return nil }
        let value = String(output[start.upperBound..<end.lowerBound])
        guard !value.isEmpty, value.contains("/"),
            !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return value
    }
}
