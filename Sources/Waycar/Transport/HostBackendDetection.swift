import Foundation

/// Which backends a Host has, from one exec (ADR 0026, design §4.1): herdr
/// when `herdr` resolves on the Host PATH (`HerdrHostPath`) or its socket
/// exists, tmux with the version `tmux -V` reports. Asked to, the same exec
/// reports the Waycar plugin (#209): herdr's plugin list and the Host
/// Tools' version and root. The output is delimited by markers, so
/// login-shell chatter before them is ignored.
enum HostBackendDetection {
    static let beginMarker = "__WAYCAR_BACKENDS__"
    static let endMarker = "__WAYCAR_BACKENDS_END__"
    static let herdrBinaryLine = "herdr=path"
    static let herdrSocketLine = "herdr=socket"
    static let tmuxPrefix = "tmux="
    static let zellijPrefix = "zellij="
    static let zellijPathPrefix = "zellijpath="
    /// herdr-core's version (`hc <digits>` with the prefix removed) and its
    /// absolute path follow these two, printed only for a binary whose
    /// `--version` says `hc <digits>`; `hc: herbstclient 0.9` never passes.
    static let corePrefix = "core="
    static let corePathPrefix = "corepath="
    static let codexPrefix = "codex="
    static let codexPathPrefix = "codexpath="
    static let codexSocketPrefix = "codexsocket="
    static let codexDaemonBegin = "__WAYCAR_CODEX_DAEMON__"
    static let codexDaemonEnd = "__WAYCAR_CODEX_DAEMON_END__"
    static let codexExitPrefix = "codexexit="
    /// `opencode --version`'s first line (`opencode v2.2.7` on OpenCode 2,
    /// a bare `1.19.5` on OpenCode 1) and the binary's absolute path.
    static let opencodePrefix = "opencode="
    static let opencodePathPrefix = "opencodepath="
    /// Printed only for OpenCode 2 at or above the floor: `service status`'s
    /// first line (a URL or `stopped`), the registration file's path, and
    /// its `url`, `pid` and `version` members, one `"key":value` match per
    /// line. Never the password: the file is never printed whole.
    static let opencodeStatusPrefix = "opencodestatus="
    static let opencodeServicePathPrefix = "opencodeservice="
    static let opencodeRegistrationPrefix = "opencodereg="
    /// `herdr plugin list --json`, possibly several lines, sits between
    /// these; printed only when `herdr` is on the PATH.
    static let pluginListBegin = "__WAYCAR_HERDR_PLUGINS__"
    static let pluginListEnd = "__WAYCAR_HERDR_PLUGINS_END__"
    /// The Host Tools root's `version = "…"` line follows this (empty when
    /// the root has none); always printed when the Host Tools exist.
    static let hostToolsVersionPrefix = "__WAYCAR_HOST_TOOLS__="
    /// The Host Tools root follows this (empty when it could not be
    /// resolved); printed beside the version line.
    static let hostToolsRootPrefix = "__WAYCAR_HOST_TOOLS_ROOT__="
    /// Printed instead when the Host Tools are not installed.
    static let hostToolsNoneLine = "__WAYCAR_HOST_TOOLS_NONE__"
    /// A program that did not answer within `probeLimitSeconds`: its
    /// `HostDetectionProbe` follows. Codex's `daemon version` reports the
    /// same through its exit line (`HostWatchdog.stoppedStatus`).
    static let timedOutPrefix = "timedout="

    /// How long each Host program the script runs may take before
    /// `waycar_watch` stops it; the others still run. A Homebrew cask macOS
    /// has not approved yet never gets past its launch check from SSH (codex
    /// 0.167.1 sat at `_dyld_start` with no CPU, and SIGTERM ended it; live
    /// on macOS, 2026-11-12), and neither does any wedged CLI. Two such
    /// programs still fit the request deadline.
    static let probeLimitSeconds = 5

    /// The detection exec for a Host whose herdr socket is `socket`. A
    /// home-relative socket is resolved against the exec's own `$HOME`, as
    /// the home probe would resolve it, so detection stays one round trip.
    /// A socket path that cannot be quoted is not tested; `herdr` on the PATH
    /// still counts. `probesPlugin` adds the Waycar plugin probe; without it
    /// the presence leaves the plugin unprobed, so a connect that needs only
    /// the backends (tmux's) pays for no plugin list or Host Tools lookup.
    /// Every program it runs is bounded by `probeLimitSeconds`.
    /// `searchesSystemDirectories` false leaves the machine-wide install
    /// prefixes out of its PATH, for real-SSH fixtures only.
    static func command(
        socket: HerdrSocketLocation, probesPlugin: Bool, loginPATH: String? = nil,
        searchesSystemDirectories: Bool = true
    ) -> String {
        let socketArguments: String
        switch socket {
        case .absolutePath(let path):
            socketArguments = RemoteShellPath.quotedAbsolute(path).map { "abs \($0)" } ?? "none ''"
        case .defaultSession, .namedSession:
            // `path(homeDirectory: "")` is the home-relative remainder, "/…".
            socketArguments = RemoteShellPath.quotedAbsolute(socket.path(homeDirectory: ""))
                .map { "home \($0)" } ?? "none ''"
        }
        let extraPATH = searchesSystemDirectories ? HerdrHostPath.extraPATH : HerdrHostPath.homeExtraPATH
        let script = "\(pathExport(searchesSystemDirectories: searchesSystemDirectories)); "
            + "\(HostWatchdog.definition); \(probeFunction)"
            + "printf \"\(beginMarker)\\n\"; "
            + "if command -v herdr >/dev/null 2>&1; then printf \"\(herdrBinaryLine)\\n\"; fi; "
            + "case \"$1\" in home) s=\"$HOME$2\";; abs) s=\"$2\";; *) s=;; esac; "
            + "if [ -n \"$s\" ] && [ -S \"$s\" ]; then printf \"\(herdrSocketLine)\\n\"; fi; "
            + "if waycar_probe \(HostDetectionProbe.tmux.rawValue) tmux -V; then "
            + "printf \"\(tmuxPrefix)%s\\n\" \"$wo\"; fi; "
            + coreProbe
            + zellijProbe
            + codexProbe(extraPATH: extraPATH)
            + opencodeProbe(extraPATH: extraPATH)
            + (probesPlugin ? pluginProbe : "")
            + "printf \"\(endMarker)\\n\\000\"; "
            + UltimateInstanceDiscovery.command
            + "; exit 0"
        return HostSSHSession.cLocaleCommand(
            "/bin/sh -c '\(script)' waycar-detect \(socketArguments) \(ShellWord.quoted(loginPATH ?? ""))")
    }

    /// The PATH every probe searches: the exec's own, then the usual tool
    /// directories a bare SSH exec lacks and herdr-core's
    /// (`HerdrHostPath.corePathExport`). Without `searchesSystemDirectories`
    /// only those in the account's home are added.
    static func pathExport(searchesSystemDirectories: Bool) -> String {
        searchesSystemDirectories
            ? HerdrHostPath.corePathExport
            : "export PATH=\"$PATH:\(HerdrHostPath.homeExtraPATH):\(HerdrHostPath.coreHomeExtraPATH)\""
    }

    /// `waycar_probe <probe> <command> [args...]` runs one Host program
    /// under `waycar_watch` with no input and no stderr, leaves its output in
    /// `wo` and returns its status. Past `probeLimitSeconds` it prints the
    /// probe's `timedOutPrefix` line, empties `wo` (whatever the program
    /// printed before it hung is no answer) and returns
    /// `HostWatchdog.stoppedStatus`.
    private static let probeFunction = "waycar_probe() { _waycar_n=$1; shift; "
        + "wo=$(waycar_watch \(probeLimitSeconds) \"$@\" 2>/dev/null </dev/null); _waycar_s=$?; "
        + "if [ $_waycar_s -eq \(HostWatchdog.stoppedStatus) ]; then wo=; "
        + "printf \"\(timedOutPrefix)%s\\n\" \"$_waycar_n\"; fi; return $_waycar_s; }; "

    /// `wo`'s first line.
    private static let firstOutputLine = "$(printf \"%s\\n\" \"$wo\" | head -n 1)"

    /// herdr-core's part of the detection script (design §4, C2, C14): the
    /// first of `herdr-core` and `hc` that `command -v` finds under the
    /// herdr PATH (which holds the Herdr app's directories) and whose
    /// `--version` prints `hc <digits>`. `--version` never starts a core; no
    /// `hc ls`, `hc server status` or `hc connect`, which all do. No single
    /// quote: the script sits inside `/bin/sh -c '…'`. A binary that does
    /// not answer is skipped for the next.
    private static let coreProbe: String = "for hcc in herdr-core hc; do "
        + "hcp=$(command -v \"$hcc\" 2>/dev/null) || continue; "
        + "case \"$hcp\" in /*) ;; *) continue;; esac; "
        + "[ -x \"$hcp\" ] || continue; "
        + "waycar_probe \"$hcc\" \"$hcp\" --version; "
        + "[ $? -ne \(HostWatchdog.stoppedStatus) ] || continue; "
        + "hcv=\(firstOutputLine); "
        + "case \"$hcv\" in \"hc \"[0-9]*) "
        + "printf \"\(corePrefix)%s\\n\(corePathPrefix)%s\\n\" \"${hcv#hc }\" \"$hcp\"; break;; esac; "
        + "done; "

    /// Uses the detection PATH (home tools, Cargo, Homebrew and Nix), never starts a session.
    private static let zellijProbe = "zp=$(command -v zellij 2>/dev/null); "
        + "case \"$zp\" in /*) if waycar_probe zellij \"$zp\" --version; then "
        + "zv=\(firstOutputLine); case \"$zv\" in \"zellij \"[0-9]*) "
        + "printf \"\(zellijPrefix)%s\\n\(zellijPathPrefix)%s\\n\" \"${zv#zellij }\" \"$zp\";; esac; fi;; esac; "

    /// Codex discovery is a subshell so its extra PATH never affects the
    /// other probes. Only these two Codex commands are side-effect-free
    /// (X1); cap the daemon answer including its exit marker at 16 KiB.
    /// An oversized/truncated answer cannot be mistaken for a running server.
    /// A `--version` that does not answer skips `daemon version`.
    private static func codexProbe(extraPATH: String) -> String {
        "( set -- \"$3\"; \(CodexServerCommand.searchPATHScript(extraPATH: extraPATH))"
            + "cp=$(command -v codex 2>/dev/null) || exit 0; "
            + "case \"$cp\" in /*) ;; *) exit 0;; esac; [ -x \"$cp\" ] || exit 0; "
            + "waycar_probe \(HostDetectionProbe.codexVersion.rawValue) \"$cp\" --version; "
            + "[ $? -ne \(HostWatchdog.stoppedStatus) ] || exit 0; "
            + "cv=\(firstOutputLine); "
            + "ch=${CODEX_HOME:-$HOME/.codex}; case \"$ch\" in /*) "
            + "printf \"\(codexSocketPrefix)%s/app-server-control/app-server-control.sock\\n\" \"${ch%/}\";; esac; "
            + "printf \"\(codexPrefix)%s\\n\(codexPathPrefix)%s\\n\(codexDaemonBegin)\\n\" \"$cv\" \"$cp\"; "
            + "{ waycar_watch \(probeLimitSeconds) \"$cp\" app-server daemon version 2>/dev/null </dev/null; "
            + "printf \"\\n\(codexExitPrefix)%s\\n\" \"$?\"; } | head -c 16384; "
            + "printf \"\\n\(codexDaemonEnd)\\n\"; ) ; "
    }

    /// OpenCode 2 discovery (design: Detection; O1, O2), a subshell like
    /// Codex's, with `~/.opencode/bin` (both installers' home) on PATH. Only
    /// `--version` and, for `opencode v2` at or above 2.2.0, `service
    /// status`, which start nothing; never `opencode api` or anything else
    /// that reaches a server. The registration file is read with
    /// `grep -o` for three members only, so its password never leaves the
    /// Host (nor reaches a detection error's output preview).
    private static func opencodeProbe(extraPATH: String) -> String {
        "( set -- \"$3\"; \(OpenCodeServerCommand.searchPATHScript(extraPATH: extraPATH))"
            + "op=$(command -v opencode 2>/dev/null) || exit 0; "
            + "case \"$op\" in /*) ;; *) exit 0;; esac; [ -x \"$op\" ] || exit 0; "
            + "waycar_probe \(HostDetectionProbe.opencodeVersion.rawValue) \"$op\" --version; "
            + "[ $? -ne \(HostWatchdog.stoppedStatus) ] || exit 0; "
            + "ov=\(firstOutputLine); "
            + "printf \"\(opencodePrefix)%s\\n\(opencodePathPrefix)%s\\n\" \"$ov\" \"$op\"; "
            + opencodeServiceProbe
    }

    /// OpenCode 2 at or above 2.2.0 only: `service status`, then the
    /// registration's three members.
    private static let opencodeServiceProbe = "case \"$ov\" in \"opencode v\"[0-9]*) ;; *) exit 0;; esac; "
        + "v=${ov#opencode v}; ma=${v%%.*}; mi=${v#*.}; mi=${mi%%.*}; "
        + "case \"$ma$mi\" in \"\"|*[!0-9]*) exit 0;; esac; "
        + "[ \"$ma\" -gt 2 ] || { [ \"$ma\" -eq 2 ] && [ \"$mi\" -ge 2 ]; } || exit 0; "
        + "waycar_probe \(HostDetectionProbe.opencodeService.rawValue) \"$op\" service status; "
        + "os=\(firstOutputLine); "
        + "sf=\"${XDG_STATE_HOME:-$HOME/.local/state}/opencode/service.json\"; "
        + "printf \"\(opencodeStatusPrefix)%s\\n\(opencodeServicePathPrefix)%s\\n\" \"$os\" \"$sf\"; "
        + "[ -r \"$sf\" ] && grep -o -E "
        + "\"\\\"(url|version)\\\"[[:space:]]*:[[:space:]]*\\\"[^\\\"]*\\\"|\\\"pid\\\"[[:space:]]*:[[:space:]]*[0-9]+\" "
        + "\"$sf\" 2>/dev/null | head -n 3 | sed \"s/^/\(opencodeRegistrationPrefix)/\"; "
        + "exit 0 ) ; "

    /// The plugin part of the detection script. It runs after the socket
    /// test: the shared Host Tools snippet reuses `s`.
    private static let pluginProbe: String = "if command -v herdr >/dev/null 2>&1; then "
        + "waycar_probe \(HostDetectionProbe.herdrPlugins.rawValue) herdr plugin list --json; "
        + "printf \"\(pluginListBegin)\\n%s\\n\(pluginListEnd)\\n\" \"$wo\"; fi; "
        + WaycarHostToolsShell.resolveCLIAndRoot
        + "if [ -n \"$cli\" ]; then pv=; if [ -n \"$root\" ]; then "
        + "pv=$(grep \"^version *=\" \"$root/herdr-plugin.toml\" 2>/dev/null | head -n 1); fi; "
        + "printf \"\(hostToolsVersionPrefix)%s\\n\(hostToolsRootPrefix)%s\\n\" \"$pv\" \"$root\"; "
        + "else printf \"\(hostToolsNoneLine)\\n\"; fi; "

    /// Parses the detection output: the lines between the last begin marker
    /// and the end marker after it. Nil when the markers are missing, so a
    /// truncated or foreign answer is never read as "nothing installed".
    /// Lines inside the herdr plugin list are JSON, never backend lines.
    static func presence(fromOutput output: Data) -> HostBackendPresence? {
        let boundary = output.firstIndex(of: 0)
        let backendOutput = boundary.map { Data(output[..<$0]) } ?? output
        guard var presence = backendPresence(fromOutput: backendOutput) else { return nil }
        if let boundary {
            presence.ultimate = UltimateInstanceDiscovery.parse(Data(output[output.index(after: boundary)...]))
        }
        return presence
    }

    private static func backendPresence(fromOutput output: Data) -> HostBackendPresence? {
        // `\r\n` is one Character, so splitting on "\n" would never split
        // CRLF output; `isNewline` takes `\n`, `\r\n` and `\r` alike.
        let lines = String(decoding: output, as: UTF8.self)
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard
            let end = lines.lastIndex(of: Substring(endMarker)),
            let begin = lines[..<end].lastIndex(of: Substring(beginMarker))
        else { return nil }
        var herdr = false
        var herdrOnPath = false
        var tmuxVersion: String?
        var coreVersion: String?
        var zellijVersion: String?
        var zellijPath: String?
        var corePath: String?
        var codexVersion: String?
        var codexPath: String?
        var codexSocket: String?
        var codexDaemon: [Substring] = []
        var inCodexDaemon = false
        var opencode = OpenCodeLines()
        var pluginList: [Substring]?
        var inPluginList = false
        var hostTools: HostToolsProbe?
        var hostToolsRoot: String?
        var unanswered: [HostDetectionProbe] = []
        for line in lines[(begin + 1)..<end] {
            if inCodexDaemon {
                if line == codexDaemonEnd {
                    inCodexDaemon = false
                } else {
                    codexDaemon.append(line)
                }
            } else if !inPluginList && line.hasPrefix(timedOutPrefix) {
                if let probe = HostDetectionProbe(rawValue: String(line.dropFirst(timedOutPrefix.count))),
                    !unanswered.contains(probe)
                {
                    unanswered.append(probe)
                }
            } else if !inPluginList && line == codexDaemonBegin {
                inCodexDaemon = true
                codexDaemon = []
            } else if !inPluginList && line.hasPrefix(codexPrefix) {
                let value = line.dropFirst(codexPrefix.count)
                if value.hasPrefix("codex-cli ") {
                    codexVersion = nonEmpty(String(value.dropFirst("codex-cli ".count)))
                }
            } else if !inPluginList && line.hasPrefix(codexPathPrefix) {
                codexPath = nonEmpty(String(line.dropFirst(codexPathPrefix.count)))
            } else if !inPluginList && line.hasPrefix(codexSocketPrefix) {
                codexSocket = nonEmpty(String(line.dropFirst(codexSocketPrefix.count)))
            } else if !inPluginList && line.hasPrefix(opencodePrefix) {
                opencode.version = nonEmpty(String(line.dropFirst(opencodePrefix.count)))
            } else if !inPluginList && line.hasPrefix(opencodePathPrefix) {
                opencode.path = nonEmpty(String(line.dropFirst(opencodePathPrefix.count)))
            } else if !inPluginList && line.hasPrefix(opencodeStatusPrefix) {
                opencode.status = nonEmpty(String(line.dropFirst(opencodeStatusPrefix.count)))
            } else if !inPluginList && line.hasPrefix(opencodeServicePathPrefix) {
                opencode.registrationPath = nonEmpty(String(line.dropFirst(opencodeServicePathPrefix.count)))
            } else if !inPluginList && line.hasPrefix(opencodeRegistrationPrefix) {
                opencode.registration.append(line.dropFirst(opencodeRegistrationPrefix.count))
            } else if inPluginList {
                if line == pluginListEnd {
                    inPluginList = false
                } else {
                    pluginList?.append(line)
                }
            } else if line == pluginListBegin {
                inPluginList = true
                pluginList = []
            } else if line == herdrBinaryLine {
                herdr = true
                herdrOnPath = true
            } else if line == herdrSocketLine {
                herdr = true
            } else if line.hasPrefix(tmuxPrefix) {
                tmuxVersion = Self.tmuxVersion(fromVersionOutput: line.dropFirst(tmuxPrefix.count))
            } else if line.hasPrefix(zellijPrefix) {
                zellijVersion = nonEmpty(String(line.dropFirst(zellijPrefix.count)))
            } else if line.hasPrefix(zellijPathPrefix) {
                zellijPath = nonEmpty(String(line.dropFirst(zellijPathPrefix.count)))
            } else if line.hasPrefix(corePrefix) {
                coreVersion = nonEmpty(String(line.dropFirst(corePrefix.count)))
            } else if line.hasPrefix(corePathPrefix) {
                corePath = nonEmpty(String(line.dropFirst(corePathPrefix.count)))
            } else if line == hostToolsNoneLine {
                hostTools = .notInstalled
            } else if line.hasPrefix(hostToolsVersionPrefix) {
                hostTools = .installed(
                    version: tomlVersion(fromLine: line.dropFirst(hostToolsVersionPrefix.count)))
            } else if line.hasPrefix(hostToolsRootPrefix) {
                let root = line.dropFirst(hostToolsRootPrefix.count)
                hostToolsRoot = root.isEmpty ? nil : String(root)
            }
        }
        // An unterminated list swallowed whatever followed it: the plugin
        // part is unreadable, the backends still count.
        let plugin: WaycarPluginDetection? = inPluginList
            ? nil
            : waycarPlugin(
                herdrOnPath: herdrOnPath,
                pluginList: pluginList.map { $0.joined(separator: "\n") },
                hostTools: hostTools, hostToolsRoot: hostToolsRoot,
                hostsCoreOnly: corePresence(version: coreVersion, path: corePath) != nil
                    && !(tmuxVersion.map(HostBackendPresence.meetsTmuxFloor) ?? false))
        if !inCodexDaemon,
            codexDaemon.last(where: { !$0.isEmpty }) == "\(codexExitPrefix)\(HostWatchdog.stoppedStatus)",
            !unanswered.contains(.codexDaemon)
        {
            unanswered.append(.codexDaemon)
        }
        // A server whose status never answered is not running, whatever it
        // printed before it hung.
        if unanswered.contains(.opencodeService) { opencode.status = nil }
        return HostBackendPresence(
            herdr: herdr, tmuxVersion: tmuxVersion, waycarPlugin: plugin,
            core: corePresence(version: coreVersion, path: corePath),
            zellij: zellijPath.flatMap { path in
                guard path.hasPrefix("/"), let version = zellijVersion else { return nil }
                return ZellijPresence(version: version, path: path)
            },
            codex: codexPresence(
                version: codexVersion, path: codexPath, probeSocketPath: codexSocket,
                daemon: inCodexDaemon ? [] : codexDaemon),
            opencode: opencode.presence,
            unansweredProbes: unanswered.isEmpty ? nil : unanswered)
    }

    /// What the OpenCode part of the output printed.
    private struct OpenCodeLines {
        var version: String?
        var path: String?
        var status: String?
        var registrationPath: String?
        var registration: [Substring] = []

        /// OpenCode 2 only: `opencode v<digits>…` from an absolute path.
        /// OpenCode 1's bare `1.x.y` is no OpenCode Backend (O1). A status
        /// counts as running only when it is a URL Waycar can dial.
        var presence: OpenCodePresence? {
            guard let version, version.hasPrefix("opencode v"), let path, path.hasPrefix("/") else { return nil }
            let number = String(version.dropFirst("opencode v".count))
            guard number.first?.isASCII == true, number.first?.isNumber == true else { return nil }
            var presence = OpenCodePresence(path: path, version: number)
            if let registrationPath, registrationPath.hasPrefix("/") {
                presence.registrationPath = registrationPath
            }
            if let status, OpenCodeEndpoint(url: status) != nil { presence.serverURL = status }
            for line in registration {
                guard let match = line.firstMatch(of: /^"(url|version|pid)"\s*:\s*(?:"([^"]*)"|([0-9]+))$/)
                else { continue }
                switch match.1 {
                case "url": presence.registeredURL = HostBackendDetection.nonEmpty(match.2.map(String.init))
                case "version": presence.registeredVersion = HostBackendDetection.nonEmpty(match.2.map(String.init))
                default: presence.registeredPID = match.3.flatMap { Int($0) }
                }
            }
            return presence
        }
    }

    private static func codexPresence(
        version: String?, path: String?, probeSocketPath: String?, daemon: [Substring]
    ) -> CodexPresence? {
        guard let version, version.first?.isASCII == true, version.first?.isNumber == true,
            let path, path.hasPrefix("/")
        else { return nil }
        var presence = CodexPresence(
            version: version, path: path,
            probeSocketPath: probeSocketPath.flatMap { $0.hasPrefix("/") ? $0 : nil })
        let lines = daemon.filter { !$0.isEmpty }
        guard let exit = lines.last, exit == "\(codexExitPrefix)0",
            let result = CodexServerCommand.daemonResult(
                Data(lines.dropLast().joined(separator: "\n").utf8)),
            result.status == "running", let socket = result.socketPath, socket.hasPrefix("/")
        else { return presence }
        presence.socketPath = socket
        presence.appServerVersion = result.appServerVersion
        return presence
    }

    /// A core only when both lines came and read sensibly: a version that
    /// starts with a digit (`hc <digits>` was checked on the Host, and is
    /// checked again here) and an absolute path.
    private static func corePresence(version: String?, path: String?) -> CorePresence? {
        guard let version, let path, version.first?.isASCII == true, version.first?.isNumber == true,
            path.hasPrefix("/")
        else { return nil }
        return CorePresence(version: version, path: path)
    }

    /// What the Host Tools line said.
    private enum HostToolsProbe {
        case notInstalled
        /// Installed; nil when the root's toml has no readable version.
        case installed(version: String?)
    }

    /// The plugin detection, in precedence order: an enabled entry in
    /// herdr's plugin list under a known id, `waycar` before the legacy ones
    /// (herdr mode, at herdr's version; `plugin_root` only for `waycar`,
    /// since install.sh replaces only that entry and links a new plugin
    /// beside a legacy one); else the Host Tools at their root: herdr mode
    /// when herdr is on the PATH with a list that could not be read
    /// (install.sh then picks herdr anyway), core mode on a Host with no herdr
    /// whose backend is herdr-core alone (`hostsCoreOnly`: core found, no
    /// usable tmux), else tmux mode; else not installed. Nil when
    /// the output carries no plugin part at all, as from a probe that never
    /// asked.
    private static func waycarPlugin(
        herdrOnPath: Bool, pluginList: String?, hostTools: HostToolsProbe?, hostToolsRoot: String?,
        hostsCoreOnly: Bool
    ) -> WaycarPluginDetection? {
        guard pluginList != nil || hostTools != nil else { return nil }
        let entries = pluginList.flatMap(pluginEntries(fromList:))
        let currentID = SSHTransportSettings.notificationPluginID
        let knownIDs = [currentID] + SSHTransportSettings.legacyNotificationPluginIDs
        let enabled = entries?.filter { $0.enabled != false } ?? []
        for id in knownIDs {
            if let entry = enabled.first(where: { $0.pluginID == id }) {
                let root = id == currentID ? nonEmpty(entry.pluginRoot) : nil
                return .installed(WaycarPluginInstall(
                    version: nonEmpty(entry.version), mode: .herdr, root: root))
            }
        }
        if case .installed(let version)? = hostTools {
            let mode: WaycarPluginInstall.Mode =
                if herdrOnPath && entries == nil {
                    .herdr
                } else if !herdrOnPath && hostsCoreOnly {
                    .core
                } else {
                    .tmux
                }
            return .installed(WaycarPluginInstall(version: version, mode: mode, root: hostToolsRoot))
        }
        return .notInstalled
    }

    /// The entries of `herdr plugin list --json`; nil when it is not that
    /// JSON (an empty answer included). Unknown fields are ignored.
    private static func pluginEntries(fromList json: String) -> [PluginList.Entry]? {
        (try? JSONDecoder().decode(PluginList.self, from: Data(json.utf8)))?.result.plugins
    }

    private struct PluginList: Decodable {
        struct Body: Decodable {
            let plugins: [Entry]
        }

        struct Entry: Decodable {
            let pluginID: String?
            let version: String?
            let enabled: Bool?
            let pluginRoot: String?

            private enum CodingKeys: String, CodingKey {
                case pluginID = "plugin_id"
                case version
                case enabled
                case pluginRoot = "plugin_root"
            }
        }

        let result: Body
    }

    /// The value of a toml `version = "1.4.0"` line; nil when the line is
    /// empty or holds no quoted value.
    static func tomlVersion(fromLine line: Substring) -> String? {
        guard let open = line.firstIndex(of: "\""),
            let close = line[line.index(after: open)...].firstIndex(of: "\"")
        else { return nil }
        return nonEmpty(String(line[line.index(after: open)..<close]))
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    /// The version from `tmux -V` output: "tmux 3.7c" -> "3.7c",
    /// "tmux next-3.6" -> "next-3.6". Nil when nothing follows the name.
    static func tmuxVersion(fromVersionOutput output: Substring) -> String? {
        var words = output.split(whereSeparator: \.isWhitespace)
        if words.first == "tmux" { words.removeFirst() }
        let version = words.joined(separator: " ")
        return version.isEmpty ? nil : version
    }
}
