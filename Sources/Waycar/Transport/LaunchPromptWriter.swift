import Foundation

/// A Codex profile file holding one launch's prompt as
/// `developer_instructions`. Codex layers `<name>.config.toml` from
/// `$CODEX_HOME` on top of the user's config for `codex -p <name>` and sends
/// the instructions as a developer message, in addition to its own base
/// instructions (`model_instructions_file` would replace those instead).
/// Being a scalar, the profile's `developer_instructions` replaces any the
/// user's own config.toml sets. Codex 0.162 has no default profile to
/// collide with: it refuses to start on a top-level `profile = "…"`.
enum CodexProfileTOML {
    static func render(developerInstructions: String) -> String {
        "developer_instructions = \(basicString(developerInstructions))\n"
    }

    /// A TOML basic string: `"` and `\` escaped, control characters as
    /// TOML escapes (which DEL and C0 controls must be), everything else
    /// verbatim UTF-8.
    static func basicString(_ value: String) -> String {
        var escaped = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\t": escaped += "\\t"
            case "\r": escaped += "\\r"
            case "\u{08}": escaped += "\\b"
            case "\u{0C}": escaped += "\\f"
            case "\u{00}"..."\u{1F}", "\u{7F}":
                let hex = String(scalar.value, radix: 16, uppercase: true)
                escaped += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default:
                escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped + "\""
    }
}

/// The Host side of Launch Prompt Files: one exec writes every file of a
/// launch, and one exec per connection reads which harness CLIs take them.
/// Both are plain POSIX sh with no SFTP, so they cost one channel each.
enum LaunchPromptWriter {
    /// One stdout line per written file, in request order.
    static let pathOutputPrefix = "__WAYCAR_LAUNCH_PROMPT__="
    static let capabilitiesOutputPrefix = "__WAYCAR_LAUNCH_PROMPT_CAPS__="
    /// The probe's Codex home line, and the marker the pane's shell prints
    /// it under inside the probe.
    static let codexHomeOutputPrefix = "__WAYCAR_CODEX_HOME__="

    /// What one exec sends: the command (without `LC_ALL=C`) and its stdin,
    /// every file's bytes back to back in request order.
    struct Plan: Sendable, Equatable {
        let command: String
        let input: Data
    }

    /// The writer script. `$1` is the Codex home (`ProbeAnswer.codexHome`),
    /// empty when no Codex profile is written; each later argument is
    /// `<kind>:<byte count>:<name>`, `s` for a `.stageDirectory` file and
    /// `c` for a Codex profile. Names are checked plain in Swift, so no spec
    /// needs quoting. Stage files share one fresh `mktemp -d` directory,
    /// 0700 under umask 077, inside a per-user parent no other user can
    /// recreate after cleanup: `$TMPDIR` when the user owns it at mode
    /// 0700 (macOS's per-user `T/`), else a plain absolute
    /// `$XDG_RUNTIME_DIR`, else `$HOME/.cache/waycar/launch-prompts`
    /// (created and forced to 0700). A stage name with a `/` (Copilot's
    /// `.github/instructions/…`) gets its subdirectories made inside it.
    /// A Codex profile goes to the Codex home
    /// (created 0700 when missing) after profiles Waycar wrote over ten
    /// minutes ago are swept: Codex reads its profile once, at startup.
    /// `find -H` enters a Codex home that is a symlink, and the sweep takes
    /// only Waycar's `waycar-<uuid>` shape, never a user's own `waycar-*`
    /// profile. `dd bs=1` reads exactly the file's bytes from the shared
    /// stdin, which a buffered reader such as `head -c` could overrun;
    /// `wc -c` then proves the count.
    static let script =
        "umask 077; codex=$1; shift; dir=; swept=; "
        + "for spec in \"$@\"; do "
        + "kind=${spec%%:*}; rest=${spec#*:}; size=${rest%%:*}; name=${rest#*:}; "
        + "case $kind in "
        + "s) if [ -z \"$dir\" ]; then \(stageParent) "
        + "dir=$(mktemp -d \"$par/waycar.XXXXXXXX\") || exit 1; fi; "
        + "path=$dir/$name; "
        + "case $name in */*) mkdir -p \"${path%/*}\" || exit 1;; esac;; "
        + "c) case $codex in /*) ;; *) exit 1;; esac; "
        + "if [ -z \"$swept\" ]; then mkdir -p \"$codex\" || exit 1; "
        + "find -H \"$codex\" -maxdepth 1 -name \"\(sweptProfilePattern)\" -mmin +10 "
        + "-exec rm -f {} + 2>/dev/null; swept=1; fi; "
        + "path=${codex%/}/$name.config.toml;; "
        + "*) exit 1;; "
        + "esac; "
        + "dd bs=1 count=\"$size\" of=\"$path\" 2>/dev/null || exit 1; "
        + "chmod 600 \"$path\" || exit 1; "
        + "got=$(wc -c < \"$path\") || exit 1; [ $got -eq \"$size\" ] || exit 1; "
        + "printf \"\(pathOutputPrefix)%s\\n\" \"$path\"; "
        + "done"

    /// The file names the sweep removes: `waycar-<uuid>.config.toml`.
    static let sweptProfilePattern = "waycar-????????-????-????-????-????????????.config.toml"

    /// Sets `par` to the stage directory's per-user parent, or exits 1.
    static let stageParent =
        "t=${TMPDIR%/}; xdg=${XDG_RUNTIME_DIR%/}; "
        + "if [ -n \"$t\" ] && [ -d \"$t\" ] && [ -O \"$t\" ] && "
        + "case $(ls -ld \"$t/\" 2>/dev/null) in drwx------*) true;; *) false;; esac; "
        + "then par=$t; "
        + "elif case $xdg in /*[!A-Za-z0-9_./-]*) false;; /?*) true;; *) false;; esac; "
        + "then par=$xdg; "
        + "else case $HOME in /*) ;; *) exit 1;; esac; "
        + "par=${HOME%/}/.cache/waycar/launch-prompts; "
        + "mkdir -p \"$par\" && chmod 700 \"$par\" || exit 1; fi;"

    /// The exec writing `files`. `codexHome` is where Codex profiles go and
    /// is required, absolute and quotable, when `files` hold one.
    static func plan(for files: [LaunchPromptFile], codexHome: String?) throws -> Plan {
        var input = Data()
        var arguments: [String] = []
        var stageNames: Set<String> = []
        var profileNames: Set<String> = []
        for file in files {
            let bytes: Data
            let kind: String
            switch file.destination {
            case .stageDirectory:
                guard isPlainStageName(file.name), stageNames.insert(file.name).inserted else {
                    throw LaunchPromptStagingError.invalidFile
                }
                kind = "s"
                bytes = Data(file.contents.utf8)
            case .codexProfile:
                guard isCodexProfileName(file.name), profileNames.insert(file.name).inserted
                else {
                    throw LaunchPromptStagingError.invalidFile
                }
                kind = "c"
                bytes = Data(
                    CodexProfileTOML.render(developerInstructions: file.contents).utf8)
            }
            arguments.append("\(kind):\(bytes.count):\(file.name)")
            input.append(bytes)
        }
        var quotedCodexHome = "''"
        if !profileNames.isEmpty {
            guard let quoted = codexHome.flatMap(RemoteShellPath.quotedAbsolute) else {
                throw LaunchPromptStagingError.unusablePath
            }
            quotedCodexHome = quoted
        }
        let command = "/bin/sh -c '\(script)' waycar-launch-prompts \(quotedCodexHome) "
            + arguments.joined(separator: " ")
        return Plan(command: command, input: input)
    }

    /// The written files, from the writer's stdout: one absolute path per
    /// file, in order, each where that file belongs. Stage files share one
    /// `waycar.*` directory and must be plain, since their paths ride the
    /// launch line; a Codex profile is named there, never pathed, so its
    /// path only has to be absolute.
    static func stagedFiles(
        _ files: [LaunchPromptFile], from output: Data
    ) throws -> [StagedLaunchPromptFile] {
        let paths = markerValues(in: output, prefix: pathOutputPrefix)
        guard paths.count == files.count else { throw LaunchPromptStagingError.writeFailed }
        var stageDirectory: Substring?
        var staged: [StagedLaunchPromptFile] = []
        for (file, path) in zip(files, paths) {
            switch file.destination {
            case .stageDirectory:
                guard isPlainAbsolutePath(path) else { throw LaunchPromptStagingError.unusablePath }
                let suffix = "/\(file.name)"
                guard path.hasSuffix(suffix) else { throw LaunchPromptStagingError.writeFailed }
                let directory = path.dropLast(suffix.count)
                guard
                    directory.split(separator: "/").last?.hasPrefix("waycar.") == true,
                    stageDirectory == nil || stageDirectory == directory
                else {
                    throw LaunchPromptStagingError.writeFailed
                }
                stageDirectory = directory
            case .codexProfile:
                guard path.hasPrefix("/"), path.hasSuffix("/\(file.name).config.toml") else {
                    throw LaunchPromptStagingError.writeFailed
                }
            }
            staged.append(StagedLaunchPromptFile(file: file, path: path))
        }
        return staged
    }

    /// `[A-Za-z0-9._-]+`, neither `.` nor `..`.
    static func isPlainFileName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".."
            && name.unicodeScalars.allSatisfy { isPlain($0) && $0 != "/" }
    }

    /// One or more plain file names joined by `/`: a path inside the stage
    /// directory that cannot leave it.
    static func isPlainStageName(_ name: String) -> Bool {
        name.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { isPlainFileName(String($0)) }
    }

    /// `waycar-` then a lowercase UUID: exactly what the sweep removes, and
    /// a plain name, which Codex's `-p` needs.
    static func isCodexProfileName(_ name: String) -> Bool {
        let prefix = "waycar-"
        guard name.hasPrefix(prefix) else { return false }
        let id = String(name.dropFirst(prefix.count))
        return UUID(uuidString: id)?.uuidString.lowercased() == id
    }

    /// Absolute and `[A-Za-z0-9_./-]` only, so it can ride a typed launch
    /// line unquoted.
    static func isPlainAbsolutePath(_ path: String) -> Bool {
        path.hasPrefix("/") && path.unicodeScalars.allSatisfy(isPlain)
    }

    private static func isPlain(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "A"..."Z", "a"..."z", "0"..."9", "_", ".", "/", "-": true
        default: false
        }
    }

    // MARK: Capabilities

    /// What the capability probe learned about a Host.
    struct ProbeAnswer: Sendable, Equatable {
        let capabilities: LaunchPromptCapabilities
        /// The Codex home a pane's `codex` reads profiles from, absolute and
        /// quotable; nil when the probe found none, which also turns
        /// `capabilities.codexProfileFile` off.
        let codexHome: String?
    }

    /// Each harness's `--help` may take this long on the Host; past it the
    /// watchdog stops it and the probe fails.
    static let capabilityHelpLimitSeconds = 8
    /// The pane shell's startup may take this long; past it the probe
    /// SIGKILLs it (and its process group, where `setsid` exists) and uses
    /// the exec's own `CODEX_HOME`.
    static let capabilityShellLimitSeconds = 5
    /// The whole probe's exec and wait budget: every watched step at its
    /// limit (each may overrun by a one-second tick), plus the round trip.
    static let capabilityProbeBudget: Duration = .seconds(30)

    /// The probe. `claude --help` and `codex --help` run under the Host
    /// PATH fix and `waycar_watch`, their output's whitespace runs folded to
    /// one space so a wrapped help line still matches. A missing CLI (126
    /// or 127) reads unsupported; a watchdog stop or any other failing
    /// `--help` exits non-zero, so nothing is cached and the next launch
    /// asks again.
    ///
    /// The Codex home is resolved the way a pane resolves it: herdr types
    /// `codex` into the user's interactive login shell, whose rc files may
    /// set a `CODEX_HOME` this exec never sees. That shell prints the
    /// marker with `$CODEX_HOME` (spelled for sh and fish alike); an empty
    /// value means `$HOME/.codex`, and no marker at all (a shell that did
    /// not start, speaks neither, or outlived its limit) falls back to the
    /// exec's own value. The shell writes to a private temp file, not a
    /// pipe, so a background job it leaves holding stdout cannot stall the
    /// read; it runs under `setsid` where present so a SIGKILL to its group
    /// takes its children too, else the kill reaches it and its direct
    /// children only.
    ///
    /// Prints `<claude><codex>` as two `0`/`1` digits, then the Codex home.
    static var capabilityProbeCommand: String {
        let paneCodexHome =
            #""printf \"\\n\#(codexHomeOutputPrefix)%s\\n\" \"\$CODEX_HOME\"""#
        let script = "\(HerdrHostPath.pathExport); \(HostWatchdog.definition); "
            + "waycar_help() { "
            + "h=$(waycar_watch \(capabilityHelpLimitSeconds) \"$1\" --help 2>&1 </dev/null); "
            + "case $? in 0) ;; 126|127) h=;; *) exit 1;; esac; "
            + "h=$(printf \"%s\" \"$h\" | tr -s \"\\n\\t \" \"   \"); }; "
            + "c=0; x=0; waycar_help claude; "
            + "case $h in *append-system-prompt-file*|*\"append-system-prompt[-file]\"*) c=1;; esac; "
            + "waycar_help codex; "
            + "case $h in *\".config.toml on top of the base user config\"*) x=1;; esac; "
            + "d=${HOME:+$HOME/.codex}; r=; "
            + "f=$(umask 077; mktemp \"${TMPDIR:-/tmp}/waycar-probe.XXXXXXXX\" 2>/dev/null) || f=; "
            + "if [ -n \"$f\" ]; then s=${SHELL:-/bin/sh}; "
            + "if command -v setsid >/dev/null 2>&1; then g=1; "
            + "setsid \"$s\" -lic \(paneCodexHome) </dev/null >\"$f\" 2>/dev/null & "
            + "else g=; \"$s\" -lic \(paneCodexHome) </dev/null >\"$f\" 2>/dev/null & fi; "
            + "p=$!; e=$(($(date +%s) + \(capabilityShellLimitSeconds))); "
            + "while kill -0 $p 2>/dev/null && [ \"$(date +%s)\" -lt $e ]; do sleep 1; done; "
            + "if kill -0 $p 2>/dev/null; then "
            + "[ -z \"$g\" ] || kill -KILL -$p 2>/dev/null; "
            + "pkill -KILL -P $p 2>/dev/null; kill -KILL $p 2>/dev/null; "
            + "wait $p 2>/dev/null; rm -f \"$f\"; else wait $p 2>/dev/null; "
            + "r=$(sed -n \"s/^\(codexHomeOutputPrefix)/=/p\" \"$f\" | tail -n 1); "
            + "rm -f \"$f\"; fi; fi; "
            + "case $r in =?*) r=${r#=};; =) r=$d;; *) r=${CODEX_HOME:-$d};; esac; "
            + "printf \"\(capabilitiesOutputPrefix)%s%s\\n\(codexHomeOutputPrefix)%s\\n\" "
            + "\"$c\" \"$x\" \"$r\""
        return "/bin/sh -c '\(script)'"
    }

    /// The probe's answer, nil when its capability marker is missing or
    /// malformed. A Codex home that is missing, relative or unquotable
    /// leaves Codex without its file route.
    static func probeAnswer(from output: Data) -> ProbeAnswer? {
        guard
            let value = markerValues(in: output, prefix: capabilitiesOutputPrefix).last,
            value.count == 2, value.allSatisfy({ $0 == "0" || $0 == "1" })
        else { return nil }
        let codexHome = markerValues(in: output, prefix: codexHomeOutputPrefix).last
            .flatMap { RemoteShellPath.isQuotableAbsolute($0) ? $0 : nil }
        return ProbeAnswer(
            capabilities: LaunchPromptCapabilities(
                claudeAppendSystemPromptFile: value.first == "1",
                codexProfileFile: value.last == "1" && codexHome != nil),
            codexHome: codexHome)
    }

    /// Every stdout line starting with `prefix`, prefix and any trailing CR
    /// removed, in order. Lines split on LF bytes, not on characters, so a
    /// CR LF ending (one `Character`) cannot glue two lines together.
    private static func markerValues(in output: Data, prefix: String) -> [String] {
        output.split(separator: 0x0A, omittingEmptySubsequences: false).compactMap {
            line -> String? in
            var text = String(decoding: line, as: UTF8.self)
            if text.hasSuffix("\r") { text.removeLast() }
            guard text.hasPrefix(prefix) else { return nil }
            return String(text.dropFirst(prefix.count))
        }
    }
}
