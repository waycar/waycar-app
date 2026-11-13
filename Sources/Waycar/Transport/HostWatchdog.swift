/// A POSIX `sh` function that bounds one Host-side command, for exec
/// scripts whose run must end on the Host before the app gives up on the
/// channel; otherwise it keeps an SSH session (and a `MaxSessions` slot)
/// busy after the app has stopped listening.
///
/// `waycar_watch <seconds> <command> [args...]` runs the command in the
/// background under a watcher that checks the wall clock about once a
/// second (a count of `sleep 1` runs long on a loaded Host). Once
/// `<seconds>` pass (at once when the limit is zero or negative) the
/// watcher freezes the command (SIGSTOP), sends SIGTERM to its direct
/// children (`pkill -P`, where present: git's ssh or remote helper) and to
/// the command, then resumes it (SIGCONT). Freezing first keeps the command
/// from reacting to a dead child with a status of its own before its own
/// SIGTERM lands.
///
/// The function reports 143 (128 + SIGTERM) exactly when the watcher
/// fired, whatever status the stopped command exited with; otherwise the
/// command's own status. The watcher ignores SIGTERM only while it
/// signals, so it finishes signalling and reports that it fired; before
/// that, the function's SIGTERM ends it as soon as the command ends on its
/// own. The watcher holds none of the command's output and is reaped, so
/// bash-as-sh prints no job notice. Paste ``definition`` into a
/// `/bin/sh -c` body before the first call; it contains no single quote.
enum HostWatchdog {
    /// What `waycar_watch` returns when the watcher stopped the command.
    static let stoppedStatus: Int32 = 128 + 15

    /// The watcher's exit status when it fired; internal to the function.
    private static let firedStatus = 99

    static let definition = "waycar_watch() { "
        + "_waycar_l=$1; shift; \"$@\" & _waycar_p=$!; "
        + "(_waycar_d=$(($(date +%s) + $_waycar_l)); "
        + "while kill -0 $_waycar_p; do "
        + "if [ \"$(date +%s)\" -ge $_waycar_d ]; then trap \"\" TERM; "
        + "kill -STOP $_waycar_p; pkill -TERM -P $_waycar_p; kill -TERM $_waycar_p; "
        + "kill -CONT $_waycar_p; exit \(firedStatus); fi; "
        + "sleep 1; done) </dev/null >/dev/null 2>&1 & _waycar_w=$!; "
        + "wait $_waycar_p; _waycar_s=$?; "
        + "kill $_waycar_w 2>/dev/null; wait $_waycar_w 2>/dev/null; "
        + "[ $? -ne \(firedStatus) ] || _waycar_s=\(stoppedStatus); "
        + "return $_waycar_s; }"
}

/// How the app picks the program behind a Host Tools feature, in the same
/// SSH exec that runs it. Two Host eras exist and the app serves both:
/// a Node-era plugin (before 2.0.0) ships `src/<script>.js`, run through
/// `bin/node.sh`; a native plugin (2.0.0 and later) has no `src/` and runs
/// `bin/waycar <subcommand>`. A Node-era Host keeps its Node script even when
/// it also has `bin/waycar`, because that script is the version the Host's
/// other files were built against. Node-era plugins from 1.2.0 ship `bin/waycar`
/// as a Node launcher (next to `src/waycar-cli.js`), which has no `chat-*`
/// subcommand and exits 2, so `src/waycar-cli.js` marks `bin/waycar`
/// as not native.
enum HostToolProbe {
    /// Shell text for a `/bin/sh -c '…'` body (it contains no single quote)
    /// that enters the plugin root in `$1` and sets `$waycar_run` to the
    /// command line to run from there: the Node script if `src/<script>.js`
    /// exists, else `bin/waycar <subcommand> <arguments>` if `bin/waycar` is
    /// executable and not the Node launcher, else exits `missingStatus` (a plugin that predates the
    /// feature, or no plugin root). `script`, `subcommand` and `arguments`
    /// are constants chosen by the app, never Host values.
    static func selection(
        script: String, subcommand: String, arguments: String = "", missingStatus: Int32
    ) -> String {
        let tail = arguments.isEmpty ? "" : " \(arguments)"
        return "cd \"$1\" 2>/dev/null || exit \(missingStatus); "
            + "if [ -f src/\(script).js ]; then waycar_run=\"sh bin/node.sh src/\(script).js\(tail)\"; "
            + "elif [ -x bin/waycar ] && [ ! -e src/waycar-cli.js ]; then waycar_run=\"bin/waycar \(subcommand)\(tail)\"; "
            + "else exit \(missingStatus); fi; "
    }
}
