import Foundation
import WaycarSSH

// Host-command services: Agent kinds, skills, model windows, CodexBar and
// mosh. None speaks a backend's protocol.
extension HostSSHSession {
    func availableAgentKinds() async throws -> [SupportedAgentKind] {
        let output = try await runHostCommand(agentDiscoveryCommand)
        return SSHTransportSettings.discoveredAgentKinds(
            from: String(decoding: output, as: UTF8.self))
    }

    func listSkills(_ query: SkillListQuery) async throws -> [AgentSkill] {
        let sources = SkillSourceCatalog.sources(for: query.kind)
        guard !sources.isEmpty else { return [] }
        let home = try await remoteHomeDirectory()
        let resolved = sources.compactMap { source -> SkillProbe.ResolvedSource? in
            let root: String?
            switch source.root {
            case .home: root = home
            case .project: root = query.projectRoot
            }
            guard let root, !root.isEmpty else { return nil }
            let trimmed = root.hasSuffix("/") ? String(root.dropLast()) : root
            guard
                let quoted = RemoteShellPath.quotedAbsolute(
                    "\(trimmed)/\(source.relativePath)")
            else { return nil }
            return SkillProbe.ResolvedSource(
                scope: source.scope,
                quotedDirectory: quoted,
                layout: source.layout,
                commandPrefix: source.commandPrefix)
        }
        guard !resolved.isEmpty else { return [] }
        let output = try await runHostCommand(SkillProbe.command(for: resolved))
        return SkillProbe.skills(fromProbeOutput: output, sources: resolved)
    }

    func readSkillFile(atPath path: String) async throws -> String {
        guard let quoted = RemoteShellPath.quotedAbsolute(path) else {
            throw TransportError.channelFailed(detail: "skill path is not quotable")
        }
        let output = try await runHostCommand(
            SkillProbe.readFileCommand(quotedPath: quoted))
        guard let content = SkillProbe.documentContent(in: output) else {
            throw TransportError.malformedResponse(
                "The skill file is gone or unreadable on the Host.")
        }
        return content
    }

    /// Asks omp for the model's window. An omp missing from the Host (exit
    /// 127) is an answer of "unknown", not a failure: the strip shows the
    /// figure without its window, as it does for a model omp does not list.
    func modelContextWindow(selector: String) async throws -> Int? {
        guard let command = AgentModelProbe.command(selector: selector) else { return nil }
        let result = try await withRequestDeadline {
            try await self.runExec(Self.cLocaleCommand(command))
        }
        guard result.exitStatus == 0, result.reachedEOF else { return nil }
        return AgentModelProbe.contextWindow(in: result.stdout, selector: selector)
    }

    /// The Agent Footer's Branch (#169) in one exec, shaped like
    /// `hostResourceUsage`: only the channel wait is bounded from outside,
    /// the exec runs under its own SSH deadline, and `waycar_watch` stops
    /// git on the Host before either. A timeout or watchdog stop throws
    /// `GitBranchProbe.Skipped`, never `TransportError.timedOut`, so the
    /// footer keeps the last branch and the Console never redials a healthy
    /// link; not a work tree and no git on the Host read as no branch.
    func gitBranch(atPath path: String) async throws -> String? {
        guard let command = GitBranchProbe.command(cwd: path) else { return nil }
        let lease: SSHChannelAdmissionLease
        do {
            lease = try await channelAdmission.acquire(
                .ordinarySession, within: GitBranchProbe.admissionBudget)
        } catch {
            if error as? TransportError == .timedOut { throw GitBranchProbe.Skipped() }
            throw HostResourceUsage.replacingTimeout(error)
        }
        let result: SSHExecResult
        do {
            result = try await connection.execute(
                Self.cLocaleCommand(command),
                input: Data(),
                timeout: GitBranchProbe.execBudget)
        } catch {
            await lease.release()
            let mapped = mapOperationError(error)
            if mapped == .timedOut { throw GitBranchProbe.Skipped() }
            throw mapped
        }
        await lease.release()
        if result.exitStatus == HostWatchdog.stoppedStatus { throw GitBranchProbe.Skipped() }
        guard result.exitStatus == 0, result.reachedEOF else { return nil }
        return GitBranchProbe.branch(in: result.stdout)
    }

    /// A probe that runs long is CodexBar's problem, not a dead link: it
    /// surfaces as `CodexBarError.timedOut` so the Console neither redials
    /// nor replays it.
    func locateCodexBar(customPath: String?) async throws -> String? {
        let command = try CodexBarCommand.locateCommand(customPath: customPath)
        do {
            return CodexBarCommand.locatedPath(in: try await runHostCommand(command))
        } catch {
            throw CodexBarError.replacingTimeout(error)
        }
    }

    /// One CodexBar `usage` run under its own budget: it is slower than any
    /// herdr command (seconds per provider), so the ordinary request timeout
    /// would cut healthy runs short. It still queues for an ordinary session
    /// channel like every other exec. Running out of budget is
    /// `CodexBarError.timedOut`, never `TransportError.timedOut`: a slow CLI
    /// is expected, and a link failure would make the Console tear down a
    /// healthy connection and run the CLI a second time.
    func codexBarUsage(executablePath: String) async throws -> AIUsageReport {
        let command = try CodexBarCommand.usageCommand(executablePath: executablePath)
        let timeout = CodexBarCommand.usageTimeout
        let result: SSHExecResult
        do {
            result = try await AsyncDeadline.run(for: timeout) {
                try await self.runExec(Self.cLocaleCommand(command), timeout: timeout)
            }
        } catch is CancellationError {
            throw TransportError.cancelled
        } catch {
            throw CodexBarError.replacingTimeout(error)
        }
        if let failure = CodexBarCommand.usageFailure(exitStatus: result.exitStatus) {
            throw failure
        }
        do {
            return try AIUsageReport.decode(result.stdout)
        } catch {
            let detail = String(decoding: result.stderr.suffix(300), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw CodexBarError.unreadableOutput(detail: detail)
        }
    }

    /// Runs `command` (as given: no locale or PATH fix-up) on an ordinary
    /// exec channel and returns as soon as a stdout line satisfies
    /// `predicate`, or at EOF (`SSHConnection.executeUntilLine`). The
    /// channel finishes in the background and keeps its `.ordinarySession`
    /// admission until it is really closed. `timeout` (default the request
    /// deadline) bounds the SSH exec; like `runExec`, the wait for a slot is
    /// the caller's to bound. More than `maximumOutputBytes` of stdout
    /// before a match throws `SSHError.responseTooLarge`.
    func runExecUntilLine(
        _ command: String,
        maximumOutputBytes: Int = 65_536,
        timeout: Duration? = nil,
        matching predicate: @escaping @Sendable (String) -> Bool
    ) async throws -> SSHExecLineResult {
        try await channelAdmission.withChannel(.ordinarySession, releasedBy: { release in
            do {
                return try await self.connection.executeUntilLine(
                    command,
                    maximumOutputBytes: maximumOutputBytes,
                    timeout: timeout ?? self.requestTimeout,
                    onChannelReleased: release,
                    matching: predicate)
            } catch {
                throw await self.mapOperationError(error)
            }
        })
    }

    /// One Waycar plugin update run (#209) on an ordinary exec channel,
    /// never the tmux `.control` lease. Each non-empty output line reaches
    /// `progress` as it arrives: `runExecUntilLine` hands every stdout line
    /// to its predicate, and the script's exit marker line ends the call. A
    /// non-zero exit, or EOF without the marker, throws
    /// `WaycarPluginUpdate.Failure`; link failures stay `TransportError`.
    func updateWaycarPlugin(
        _ request: WaycarPluginUpdateRequest,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> WaycarPluginUpdateResult {
        let result = try await runExecUntilLine(
            WaycarPluginUpdate.command(for: request),
            timeout: WaycarPluginUpdate.timeout
        ) { line in
            let line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if WaycarPluginUpdate.exitStatus(fromMarkerLine: line) != nil { return true }
            guard !line.isEmpty else { return false }
            progress(line)
            return false
        }
        let lines = WaycarPluginUpdate.lines(fromOutput: result.stdout)
        let status = result.matchedLine.flatMap {
            WaycarPluginUpdate.exitStatus(
                fromMarkerLine: $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
        }
        guard status == 0 else {
            throw WaycarPluginUpdate.failure(fromOutput: lines, exitStatus: status)
        }
        return WaycarPluginUpdate.result(fromOutput: lines)
    }

    /// The install preflight (WAY-338): what a Host has that decides which
    /// Install buttons the panel offers. One exec under the request deadline.
    func preflightInstall() async throws -> HostInstallPreflight {
        let result = try await withRequestDeadline {
            try await self.runExec(HostInstallPreflight.command)
        }
        guard let preflight = HostInstallPreflight(fromOutput: result.stdout) else {
            throw TransportError.channelFailed(
                detail: "install preflight printed: \(Self.preview(result.stdout))")
        }
        return preflight
    }

    /// One backend install run (WAY-338) on an ordinary exec channel, never
    /// the tmux `.control` lease, shaped like `updateWaycarPlugin`: each
    /// non-empty output line reaches `progress` as it arrives and the exec's
    /// exit marker ends the call. A non-zero exit is a returned
    /// `BackendInstallRun`, not a throw: the caller classifies it. Link
    /// failures stay `TransportError`.
    func runBackendInstall(
        _ plan: BackendInstallPlan,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> BackendInstallRun {
        let result = try await runExecUntilLine(
            BackendInstall.execCommand(for: plan),
            maximumOutputBytes: BackendInstall.maximumOutputBytes,
            timeout: BackendInstall.timeout
        ) { line in
            let line = BackendInstall.stripTerminalEscapes(line)
                .trimmingCharacters(in: .whitespaces)
            if BackendInstall.marker(fromLine: line) != nil { return true }
            guard !line.isEmpty else { return false }
            progress(line)
            return false
        }
        return BackendInstall.run(fromOutput: BackendInstall.lines(fromOutput: result.stdout))
    }

    /// Starts herdr's server once (`WaycarSSHTransport.wakeExec`), only when
    /// the user asked: Start Herdr TUI on a `.herdrNotRunning` or
    /// `.streamLocalOpenFailed` Host, or right after Install herdr, since a
    /// fresh install leaves no server and no socket. Nothing else starts it
    /// (#389). Throws `HerdrStartError` with herdr's own output when the
    /// start command fails.
    func wakeHerdrServer(wakeCommand: String, inLoginSession: Bool) async throws {
        let wake = try WaycarSSHTransport.wakeExec(
            wakeCommand: wakeCommand,
            socketPath: try await resolvedSocketPath(),
            socketLocation: socketLocation,
            inLoginSession: inLoginSession)
        let result = try await withRequestDeadline {
            try await self.runExec(wake.command, input: wake.input)
        }
        guard result.exitStatus == 0, result.reachedEOF else {
            throw HerdrStartError(output: Self.preview(result.stderr))
        }
    }

    /// Starts core only after a Start Herdr Core or Install tap (#389).
    /// No locale wrapper: core freezes this caller's environment (C5).
    func startCoreServer(path: String?, loginPATH: String?, inLoginSession: Bool) async throws {
        let start = CoreConnectCommand.start(
            path: path, loginPATH: loginPATH, inLoginSession: inLoginSession)
        let result = try await withRequestDeadline {
            try await self.runExec(start.command, input: start.input)
        }
        guard result.exitStatus == 0, result.reachedEOF else {
            throw HerdrStartError(output: Self.preview(result.stderr))
        }
    }

    /// Only Start Codex server may call this. The daemon hands its starter's
    /// environment to every client, so use the login session without a locale
    /// wrapper, just like core (design X3).
    func startCodexServer(path: String, loginPATH: String?, inLoginSession: Bool) async throws {
        let start = CodexServerCommand.start(
            path: path, loginPATH: loginPATH, inLoginSession: inLoginSession)
        let result = try await withRequestDeadline {
            try await self.runExec(start.command, input: start.input)
        }
        try CodexServerCommand.validateStart(
            exitStatus: result.exitStatus, reachedEOF: result.reachedEOF,
            stdout: result.stdout, stderr: result.stderr)
    }

    /// Only Start OpenCode server may call this, the same way as Codex's:
    /// the server hands its starter's environment to every tool (O4).
    func startOpenCodeServer(path: String, loginPATH: String?, inLoginSession: Bool) async throws {
        let start = OpenCodeServerCommand.start(
            path: path, loginPATH: loginPATH, inLoginSession: inLoginSession)
        let result = try await withRequestDeadline {
            try await self.runExec(start.command, input: start.input)
        }
        try OpenCodeServerCommand.validateStart(
            exitStatus: result.exitStatus, reachedEOF: result.reachedEOF,
            stdout: result.stdout, stderr: result.stderr)
    }

    /// One CPU / memory / swap sample. Only the wait for an ordinary session
    /// channel is bounded from outside (`admissionBudget`): a deadline that
    /// cancelled the exec mid channel-open would make the SSH layer
    /// invalidate the whole connection, Terminals included. The exec itself
    /// runs under the SSH layer's own `execBudget`. Running out of either is
    /// `HostResourceUsage.TimedOut`, never `TransportError.timedOut`, so a
    /// slow or queued sample never makes the Console distrust and redial a
    /// healthy connection.
    func hostResourceUsage() async throws -> HostResourceUsage {
        let lease: SSHChannelAdmissionLease
        do {
            lease = try await channelAdmission.acquire(
                .ordinarySession, within: HostResourceUsage.admissionBudget)
        } catch {
            throw HostResourceUsage.replacingTimeout(error)
        }
        let result: SSHExecResult
        do {
            result = try await connection.execute(
                Self.cLocaleCommand(HostResourceUsage.command),
                input: Data(),
                timeout: HostResourceUsage.execBudget)
        } catch {
            await lease.release()
            throw HostResourceUsage.replacingTimeout(mapOperationError(error))
        }
        await lease.release()
        return try HostResourceUsage.parse(result.stdout)
    }

    // MARK: mosh

    /// Command the mosh availability probe runs on the Host.
    static let moshProbeCommand = "command -v mosh-server"

    /// The probe's wrapped command prints this marker; seeing it
    /// rendered back on the device proves the UDP session end-to-end.
    static let moshHandshakeMarker = "MOSH_HANDSHAKE_OK"

    /// Probe budget: the bootstrap exec plus this watchdog window. The mosh
    /// client never gives up on a silent server by itself, so the watchdog
    /// alone decides that UDP is not getting through.
    static let moshHandshakeWatchdog: Duration = .seconds(6)

    /// Whether mosh can carry an interactive session on this Host, proven by
    /// a real handshake: a throwaway `mosh-server new` bootstrap, then a
    /// short-lived ``MoshAttachSession`` whose output is read on a bounded
    /// watchdog. `command -v mosh-server` only answers whether the binary
    /// is installed — it cannot see a UDP path that a firewall or NAT
    /// blocks even on a healthy Host.
    func probeMoshServer() async throws -> Bool {
        let output = try await runHostCommand(Self.moshProbeCommand)
        guard !output.isEmpty else { return false }
        try await probeMoshHandshake()
        return true
    }

    /// One full mosh handshake proof. Bootstraps `mosh-server new` around a
    /// trivial keep-alive (not a live Agent's pane), runs a swift-mosh
    /// session through ``MoshAttachSession``, and reads its output under a
    /// watchdog: the marker rendering back, or the server ending the session
    /// cleanly, proves the UDP path; a thrown failure or the watchdog
    /// expiring first marks the handshake failed.
    private func probeMoshHandshake() async throws {
        let bootstrap: MoshBootstrap
        do {
            let socketPath = try await resolvedSocketPath()
            bootstrap = try await runMoshBootstrap { bindsToPeer in
                try WaycarSSHTransport.moshProbeBootstrapCommand(
                    socketPath: socketPath, bindsToPeer: bindsToPeer)
            } missingBanner: { output in
                .moshSessionFailed(
                    detail: "mosh-server did not print a MOSH CONNECT banner."
                        + " Exec output tail: \(Self.outputTail(output))")
            }
        } catch let error as TransportError {
            throw error
        } catch {
            throw TransportError.moshSessionFailed(
                detail: "The mosh bootstrap could not run. (\(error))")
        }
        let session = MoshAttachSession.make(
            bootstrap: bootstrap, cols: 80, rows: 24)
        defer { Task { await session.end() } }
        try await Self.awaitHandshakeProof(session)
    }

    /// Races the session's output against the watchdog; the first to decide
    /// wins and the other is cancelled. Output proves the session when the
    /// wrapped command's marker renders back, or when it finishes cleanly —
    /// the server only ends a session over UDP, after the command exits. A
    /// thrown ``TransportError/moshSessionFailed(detail:)`` carries the
    /// client's own reason to the Host detail row.
    private static func awaitHandshakeProof(_ session: TerminalAttachSession) async throws {
        let marker = Data(moshHandshakeMarker.utf8)
        let window = moshHandshakeWatchdog
        let proven = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                var received = Data()
                for try await bytes in session.output {
                    received.append(bytes)
                    if received.range(of: marker) != nil {
                        return true
                    }
                }
                return !Task.isCancelled
            }
            group.addTask {
                try? await Task.sleep(for: window)
                return false
            }
            let first = try await group.next() ?? false
            group.cancelAll()
            return first
        }
        guard proven else {
            throw TransportError.moshSessionFailed(
                detail: "The Host did not answer over UDP within "
                    + "\(Int(window.components.seconds))s.")
        }
    }

    /// The last two non-empty lines of a command's output, for failure
    /// details: a failed `mosh-server new` names its reason there.
    static func outputTail(_ data: Data) -> String {
        let text = String(decoding: data, as: UTF8.self)
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.suffix(2).joined(separator: " | ")
    }

    func runMoshBootstrap(
        attachCommand: String, request: TerminalAttachRequest
    ) async throws -> MoshBootstrap {
        try await runMoshBootstrap { bindsToPeer in
            try Self.moshBootstrapExecCommand(
                attachCommand: attachCommand, bindsToPeer: bindsToPeer)
        }
    }

    /// Runs one PTY-less `mosh-server new` exec and parses its `MOSH
    /// CONNECT` banner: the one place that decides how mosh reaches this
    /// Host (#122). `command` builds the exec (herdr's with its socket
    /// scope, tmux's around its attach chain, the probe's around a marker)
    /// and is told to bind mosh-server when `moshUDPHost` is known; the
    /// bootstrap's `host` is `moshUDPHost`, else `sshHost`. A missing banner
    /// throws `missingBanner(output)`.
    ///
    /// It returns on the banner line (#105): the client can start while the
    /// exec's channel is still winding down, which it does in the background
    /// under the channel's admission. The bootstrap rides whatever SSH
    /// priority its caller set: attach paths run it interactive.
    func runMoshBootstrap(
        command: @Sendable (_ bindsToPeer: Bool) throws -> String,
        missingBanner: @Sendable (_ output: Data) -> TransportError = { _ in
            .channelFailed(detail: "mosh-server did not print a MOSH CONNECT banner")
        }
    ) async throws -> MoshBootstrap {
        let exec = Self.cLocaleCommand(
            HerdrHostPath.wrappingBareHerdr(try command(moshUDPHost != nil)))
        let result: SSHExecLineResult
        do {
            result = try await withRequestDeadline {
                try await self.runExecUntilLine(exec, matching: MoshBootstrap.isBannerLine)
            }
        } catch TransportError.timedOut {
            SSHDiagnostics.note("mosh bootstrap budget \(requestTimeout) expired")
            throw TransportError.timedOut
        }
        guard
            let line = result.matchedLine,
            let bootstrap = MoshBootstrap.parse(Data(line.utf8), host: moshUDPHost ?? sshHost)
        else {
            throw missingBanner(result.stdout + result.stderr)
        }
        return bootstrap
    }

    /// The PTY-less exec that bootstraps one mosh session around
    /// `attachCommand`, with the Host PATH fix, the terminal type and the
    /// server lifetime herdr's bootstrap uses
    /// (`WaycarSSHTransport.moshBootstrapCommand` explains each). The command
    /// rides inside the wrapper's single quotes, so it may not contain one.
    static func moshBootstrapExecCommand(attachCommand: String, bindsToPeer: Bool) throws -> String {
        let unquotable: (Character) -> Bool = { character in
            character == "'" || character == "\\"
                || character.unicodeScalars.contains(where: {
                    CharacterSet.controlCharacters.contains($0)
                })
        }
        guard !attachCommand.isEmpty, !attachCommand.contains(where: unquotable) else {
            throw TransportError.channelFailed(
                detail: "mosh bootstrap command cannot be quoted for the remote command")
        }
        return "/bin/sh -c '\(HerdrHostPath.pathExport); "
            + "export TERM=xterm-256color; "
            + "export MOSH_SERVER_NETWORK_TMOUT=60; "
            + moshServerInvocation(bindsToPeer: bindsToPeer)
            + "-- \(attachCommand)' mosh"
    }

    /// The `exec mosh-server new …` every mosh bootstrap ends in, up to the
    /// `--` before the wrapped command. With `bindsToPeer`, mosh-server gets
    /// `-s`, binding the address the SSH connection arrived on at the Host
    /// (the local half of `SSH_CONNECTION`), unless that address is
    /// loopback: sshd then sits behind a TCP proxy on the Host (sslh,
    /// HAProxy, stunnel), `-s` would bind loopback, and mosh-server stays
    /// unbound as before (#122). The script holds no single quote and reads
    /// neither `$1` nor `$2`, so it rides inside either builder's
    /// `/bin/sh -c '…'`.
    static func moshServerInvocation(bindsToPeer: Bool) -> String {
        guard bindsToPeer else {
            return "exec mosh-server new -c 256 -l LANG=en_US.UTF-8 "
        }
        return "mosh_addr=${SSH_CONNECTION% *}; "
            + "case ${mosh_addr##* } in \"\"|127.*|::1|::ffff:127.*) mosh_bind= ;; "
            + "*) mosh_bind=-s ;; esac; "
            + "exec mosh-server new $mosh_bind -c 256 -l LANG=en_US.UTF-8 "
    }
}

/// One explicit server start and its stdin; shared by Herdr TUI, Core and Codex.
struct HostServerStartExec: Sendable, Equatable {
    let command: String
    let input: Data
}

/// One-shot GUI-session launchd jobs. Keep the TUI command byte-identical:
/// all three backends use the same lifecycle, status descriptors and fallback.
enum HostLoginSessionStart {
    static func script(
        variables: [String], ready: String, capturesOutput: Bool = false
    ) -> String {
        "if [ \"$(uname -s)\" = Darwin ] && u=$(id -u) "
            + "&& launchctl print \"gui/$u\" >/dev/null 2>&1 "
            + "&& d=$(mktemp -d /tmp/dev.waycar.herdr-wake.XXXXXX); then "
            + "if cat > \"$d/job\" "
            + "&& env -i PATH=\"$PATH\" HOME=\"$HOME\" \(variables.joined(separator: " ")) "
            + "/bin/sh -c \"export -p\" > \"$d/env\" "
            + "&& printf \"\(plist)\" \"${d##*/}\" \"$d\" > \"$d/job.plist\" "
            + "&& : > \"$d/err\" && : > \"$d/rc\" && exec 3< \"$d/err\" 4< \"$d/rc\" "
            + (capturesOutput ? "&& : > \"$d/out\" && exec 5< \"$d/out\" " : "")
            + "&& launchctl bootstrap \"gui/$u\" \"$d/job.plist\" >/dev/null 2>&1; then "
            + "i=0; while [ -d \"$d\" ] && [ $i -lt 120 ]; "
            + "do sleep 0.1; i=$((i+1)); done; "
            + "read r <&4; "
            + (capturesOutput ? "cat <&5; " : "")
            + "[ \"$r\" = 0 ] && \(ready) && exit 0; cat <&3 >&2; exit 1; fi; "
            + "rm -rf \"$d\"; fi; "
    }

    /// Interactive keeps the server and its Agents out of launchd's
    /// background resource limits. Only fixed text and the temp folder here.
    private static let plist =
        "<plist><dict><key>Label</key><string>%s</string>"
        + "<key>ProgramArguments</key><array><string>/bin/sh</string>"
        + "<string>%s/job</string></array>"
        + "<key>ProcessType</key><string>Interactive</string>"
        + "<key>RunAtLoad</key><true/></dict></plist>"

    /// Passed on stdin, not quoted in the exec. Open descriptors let the
    /// exec read status and stderr even after the job removes its folder.
    static func job(command: String, capturesOutput: Bool = false) -> String {
        """
        d=${0%/*}
        { . "$d/env" && cd "$HOME" && \(command) < /dev/null; } \(capturesOutput ? "> \"$d/out\" " : "")2> "$d/err"
        echo $? > "$d/rc"
        rm -rf "$d"
        launchctl bootout "gui/$(id -u)/${d##*/}"

        """
    }
}

/// An explicit runtime start command failed on the Host. The SSH link
/// worked, so this carries the runtime's output rather than a
/// `TransportError`.
struct HerdrStartError: LocalizedError, Equatable {
    /// The start's stderr (its first 200 bytes), trimmed; empty when it
    /// printed nothing.
    let output: String

    init(output: String) {
        self.output = output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var errorDescription: String? {
        output.isEmpty ? "Herdr TUI did not start." : "Herdr TUI did not start: \(output)"
    }
}
