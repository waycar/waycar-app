import Foundation

/// The onboarding checklist (#14): the M0 `TransportError` taxonomy rendered
/// as actionable checks, no new probing machinery (spec #20). One connect +
/// ping exercises the whole chain, so a run fails at exactly one check —
/// everything before it demonstrably worked, everything after it is unknown.
/// Each backend has its own list (`checks(for:)`); herdr's is the original.
enum PreflightCheck: CaseIterable, Sendable {
    /// SSH reachable, credentials accepted, host key trusted.
    case connection
    /// The login shell exposes a usable absolute home directory.
    case remoteEnvironment
    /// The herdr socket path exists on the Host.
    case herdrInstalled
    /// The socket accepts connections (a wake attempt already ran).
    case serverRunning
    /// The server speaks a protocol version this build supports.
    case protocolCompatible
    /// tmux is on the Host PATH and at least 3.2.
    case tmuxInstalled
    case zellijInstalled
    case zellijVersion
    case zellijAnswers
    /// herdr-core is on the Host: a binary that printed `hc <digits>`.
    case coreInstalled
    /// That herdr-core is at or above the floor Waycar drives
    /// (`CorePresence.minimumVersion`) and offers the methods it needs.
    case coreVersion
    /// The connect line ran (login chatter skipped) and herdr-core answered
    /// `hello` with a generation Waycar speaks.
    case coreHello
    /// One `events.subscribe` returned a snapshot of the Host's terminals.
    case coreEvents
    /// Waycar's agent status hooks. Soft: it warns, never fails a run.
    case statusHooks

    /// The checklist one backend's preflight runs, in order.
    static func checks(for backend: HostBackend) -> [PreflightCheck] {
        switch backend {
        case .ultimate, .codex, .opencode:
            [.connection, .remoteEnvironment]
        case .herdr:
            [.connection, .remoteEnvironment, .herdrInstalled, .serverRunning, .protocolCompatible]
        case .core:
            [
                .connection, .remoteEnvironment, .coreInstalled, .coreVersion, .coreHello,
                .coreEvents,
            ]
        case .tmux:
            [.connection, .remoteEnvironment, .tmuxInstalled, .statusHooks]
        case .zellij:
            [.connection, .remoteEnvironment, .zellijInstalled, .zellijVersion, .zellijAnswers, .statusHooks]
        }
    }

    var title: String {
        switch self {
        case .connection: "SSH connection"
        case .remoteEnvironment: "remote environment"
        case .herdrInstalled: "Herdr TUI installed"
        case .serverRunning: "Herdr TUI running"
        case .protocolCompatible: "protocol compatible"
        case .tmuxInstalled: "tmux installed"
        case .zellijInstalled: "Zellij installed"
        case .zellijVersion: "Zellij 0.46 or later"
        case .zellijAnswers: "Zellij answers"
        case .coreInstalled: "Herdr Core installed"
        case .coreVersion: "Herdr Core \(CorePresence.minimumVersion) or later"
        case .coreHello: "Herdr Core answers"
        case .coreEvents: "Herdr Core live updates"
        case .statusHooks: "Status hooks"
        }
    }
}

enum PreflightCheckStatus: Equatable, Sendable {
    case passed
    /// This check's failure caused the run to stop; `hint` is the fix-it.
    case failed(hint: String)
    /// Unknown: an earlier check failed before this one could run.
    case blocked
    /// A soft check found something to fix; the run still passed.
    case warning(hint: String)
    /// The runtime this check needs is installed but not running (#389): a
    /// normal state, not a fault, with its Start on the Host page. The run
    /// stops here as on `failed`; `hint` says what to do.
    case stopped(hint: String)
}

/// One-row roll-up for Host detail's collapsible Preflight and Status Hooks
/// sections: the sections show this summary until expanded. Blocking means a
/// hard check failed and stopped the run (`PreflightCheckStatus.failed`);
/// warnings are the soft findings (`.warning`), which never fail a run.
struct HostSectionSummary: Equatable, Sendable {
    enum Severity: Equatable, Sendable {
        /// No result yet (first run still in flight).
        case pending
        /// Nothing applies (no installed agent has hook support).
        case neutral
        case allPassed
        case warning
        case blocking
        /// The runtime is installed but not running (#389): calm, and it
        /// does not expand itself.
        case stopped
    }

    let severity: Severity
    /// Short state line shown beside the title ("All 5 checks passed").
    let detail: String

    /// The Preflight section's summary over `report`'s checklist.
    static func preflight(report: PreflightReport?) -> HostSectionSummary {
        guard let report else {
            return HostSectionSummary(severity: .pending, detail: "Checking…")
        }
        let checks = PreflightCheck.checks(for: report.backend)
        var warnings = 0
        for check in checks {
            switch report[check] {
            case .stopped:
                return HostSectionSummary(
                    severity: .stopped, detail: "\(report.backend.displayName) not running")
            case .failed:
                let detail = switch check {
                case .herdrInstalled: "Herdr TUI not installed"
                case .serverRunning: "Herdr TUI not running"
                case .coreInstalled: "Herdr Core not installed"
                default: "\(check.title) failed"
                }
                return HostSectionSummary(severity: .blocking, detail: detail)
            case .warning:
                warnings += 1
            case .passed, .blocked:
                break
            }
        }
        if warnings > 0 {
            return HostSectionSummary(
                severity: .warning,
                detail: warnings == 1 ? "Passed with 1 warning" : "Passed with \(warnings) warnings")
        }
        return HostSectionSummary(severity: .allPassed, detail: "All \(checks.count) checks passed")
    }

    /// The Status Hooks section's summary: green only when every detected
    /// agent CLI has its hooks installed and nothing needs attention. A
    /// failed install (`installError`) is the one real failure state.
    static func statusHooks(_ state: StatusHooksState, installError: String?) -> HostSectionSummary {
        if installError != nil {
            return HostSectionSummary(severity: .blocking, detail: "Install failed")
        }
        switch state {
        case .hostToolsMissing:
            return HostSectionSummary(severity: .warning, detail: "Host tools not installed")
        case .unreadable:
            return HostSectionSummary(severity: .warning, detail: "Could not read hooks")
        case .reported(let report):
            let missing = state.missingAgents
            if !missing.isEmpty {
                return HostSectionSummary(
                    severity: .warning,
                    detail: missing.count == 1
                        ? "Missing for \(missing[0])"
                        : "Missing for \(ListFormatter.localizedString(byJoining: missing))")
            }
            if state.needsCodexReview {
                return HostSectionSummary(severity: .warning, detail: "Codex review needed")
            }
            let count = report.agents.count { $0.detected != false }
            if count == 0 {
                return HostSectionSummary(severity: .neutral, detail: "No agents installed")
            }
            return HostSectionSummary(
                severity: .allPassed,
                detail: count == 1 ? "Installed for 1 agent" : "Installed for all \(count) agents")
        }
    }
}

/// What the soft Status hooks check found on a Host with tmux (design §4.3,
/// §4.5): the Host tools' report, or that they did not answer.
enum StatusHooksState: Equatable, Sendable {
    /// The Host tools answered `waycar hooks status`.
    case reported(StatusHooksReport)
    /// The Host tools are not installed (or too old to report hooks).
    case hostToolsMissing
    /// The report could not be read over the connection.
    case unreadable(String)

    /// Agent CLIs, by display name, that are on the Host but whose hooks are
    /// not installed. An agent whose CLI the Host tools did not find
    /// (`detected == false`) is never a warning.
    var missingAgents: [String] {
        guard case .reported(let report) = self else { return [] }
        return report.agents
            .filter { !$0.installed && $0.detected != false }
            .map { Self.displayName(ofAgent: $0.agent) }
    }

    /// Codex keeps new hooks inactive until the user approves them in `/hooks`.
    var needsCodexReview: Bool {
        guard case .reported(let report) = self else { return false }
        return report.agents.contains { $0.needsCodexReview == true }
    }

    /// The soft row's hint; nil when every hook is installed and live.
    var warning: String? {
        switch self {
        case .hostToolsMissing:
            return "Waycar's host tools are not installed, so Agents show Unknown. "
                + "Install them on the Host with \(WaycarPluginRequirement.installCommand)"
        case .unreadable(let detail):
            return "Could not read the status hooks. (\(detail))"
        case .reported:
            var notes: [String] = []
            let missing = missingAgents
            if !missing.isEmpty {
                notes.append(
                    "Status hooks are missing for \(ListFormatter.localizedString(byJoining: missing)), "
                        + "so those Agents show Unknown.")
            }
            if needsCodexReview {
                notes.append(Self.codexReviewNote)
            }
            return notes.isEmpty ? nil : notes.joined(separator: " ")
        }
    }

    static let codexReviewNote = "Open Codex once and approve Waycar's hooks in /hooks."

    /// "claude" → "Claude Code"; unknown names stay as the Host tools wrote them.
    static func displayName(ofAgent agent: String) -> String {
        SupportedAgentKind(rawValue: agent)?.displayName ?? agent
    }
}

/// Outcome of one preflight run, queryable per check.
struct PreflightReport: Equatable, Sendable {
    /// The backend whose checklist this run covered.
    let backend: HostBackend
    /// nil means every hard check passed.
    private let failure: Failure?
    /// The soft Status hooks row (tmux only); never fails the run.
    private let statusHooks: StatusHooksState?

    private struct Failure: Equatable, Sendable {
        let check: PreflightCheck
        let hint: String
        /// The run's runtime, when the failure says it is installed but
        /// stopped (`TransportError.startableRuntime`).
        var stoppedRuntime: HostBackend?
    }

    /// The runtime this run found installed but not running (#389), whose
    /// Start the Host page offers: Herdr TUI on herdr's checklist, Herdr
    /// Core on core's. nil for any other outcome.
    var stoppedRuntime: HostBackend? { failure?.stoppedRuntime }

    private init(backend: HostBackend, failure: Failure?, statusHooks: StatusHooksState? = nil) {
        self.backend = backend
        self.failure = failure
        self.statusHooks = statusHooks
    }

    /// herdr's checklist, all green.
    static let allPassed = PreflightReport(backend: .herdr, failure: nil)

    /// Every hard check on `backend` passed. On tmux, `statusHooks` decides
    /// the soft row: a warning, never a failure.
    static func passed(on backend: HostBackend, statusHooks: StatusHooksState? = nil) -> PreflightReport {
        PreflightReport(
            backend: backend, failure: nil, statusHooks: backend == .tmux || backend == .zellij ? statusHooks : nil)
    }

    /// A failure outside the transport taxonomy (e.g. no stored password).
    static func failure(
        check: PreflightCheck, hint: String, backend: HostBackend = .herdr
    ) -> PreflightReport {
        PreflightReport(backend: backend, failure: Failure(check: check, hint: hint))
    }

    /// herdr-core's presence-based checks, from the detection that already
    /// ran: found, then at or above the floor. The Host answered over SSH
    /// to get here, so the connection checks stand passed.
    static func core(presence: HostBackendPresence) -> PreflightReport {
        guard let core = presence.core else {
            return failure(
                check: .coreInstalled,
                hint: "Herdr Core was not found on the Host. Install herdr-core there, then run the checks again.",
                backend: .core)
        }
        guard core.meetsFloor else {
            return failure(
                check: .coreVersion,
                hint: "The Host has Herdr Core \(core.version); Waycar needs "
                    + "\(CorePresence.minimumVersion) or later. Run `herdr-core update` on the Host.",
                backend: .core)
        }
        return passed(on: .core)
    }

    /// Maps a transport failure onto the check it disproves on `backend`'s
    /// checklist. tmux has one check past the connection, so everything
    /// herdr spreads over install, server and protocol lands on it.
    static func failure(
        _ error: TransportError, authMethod: Host.AuthMethod, backend: HostBackend
    ) -> PreflightReport {
        switch backend {
        case .ultimate, .codex:
            return failure(check: .connection, hint: error.presentation.message, backend: backend)
        case .opencode:
            // A refused direct-tcpip names the sshd setting to change.
            if error == HostSSHSession.openCodeForwardingDenied {
                return failure(
                    check: .connection,
                    hint: "The Host refused SSH TCP forwarding to the OpenCode server. Set "
                        + "AllowTcpForwarding local (or yes) in its sshd_config, allow the server's "
                        + "port in PermitOpen, then run the checks again.",
                    backend: .opencode)
            }
            return failure(check: .connection, hint: error.presentation.message, backend: backend)
        case .herdr:
            return failure(error, authMethod: authMethod)
        case .core:
            // herdr-core's own failures name their check; the SSH layer's
            // (connection, environment) keep theirs; anything else lands on
            // the handshake.
            switch error {
            case .coreNotInstalled:
                return failure(
                    check: .coreInstalled, hint: error.presentation.message, backend: .core)
            case .coreNeedsUpdate:
                return failure(
                    check: .coreVersion, hint: error.presentation.message, backend: .core)
            case .coreNotRunning:
                return PreflightReport(
                    backend: .core,
                    failure: Failure(
                        check: .coreHello,
                        hint:
                            "Herdr Core is installed but not running. Tap Start Herdr Core to start it.",
                        stoppedRuntime: .core))
            case .coreNeedsWaycarUpdate, .coreRefused:
                return failure(
                    check: .coreHello, hint: error.presentation.message, backend: .core)
            case .channelFailed(let detail), .malformedResponse(let detail):
                return failure(
                    check: .coreHello,
                    hint: "Herdr Core did not answer Waycar's hello. (\(detail))", backend: .core)
            case .apiRejected(let code, let message):
                return failure(
                    check: .coreHello,
                    hint: "Herdr Core answered but rejected the check: \(message) (\(code))",
                    backend: .core)
            default:
                break
            }
            let herdr = failure(error, authMethod: authMethod)
            guard let herdrFailure = herdr.failure else { return passed(on: .core) }
            let check: PreflightCheck =
                switch herdrFailure.check {
                case .connection, .remoteEnvironment: herdrFailure.check
                default: .coreHello
                }
            return PreflightReport(
                backend: .core, failure: Failure(check: check, hint: herdrFailure.hint))
        case .zellij:
            switch error {
            case .zellijNotInstalled:
                return failure(check: .zellijInstalled, hint: error.presentation.message, backend: .zellij)
            case .zellijTooOld:
                return failure(check: .zellijVersion, hint: error.presentation.message, backend: .zellij)
            default:
                let report = failure(error, authMethod: authMethod)
                let check: PreflightCheck = switch report.failure?.check {
                case .connection?: .connection
                case .remoteEnvironment?: .remoteEnvironment
                default: .zellijAnswers
                }
                return failure(check: check, hint: error.presentation.message, backend: .zellij)
            }
        case .tmux:
            let hint: String
            switch error {
            case .tmuxNotInstalled, .tmuxTooOld:
                hint = error.presentation.message
            case .malformedResponse(let detail):
                hint = "tmux's reply did not parse. (\(detail))"
            case .apiRejected(let code, let message):
                hint = "tmux answered but rejected the check: \(message) (\(code))"
            default:
                let herdr = failure(error, authMethod: authMethod)
                guard let herdrFailure = herdr.failure else { return passed(on: .tmux) }
                let check: PreflightCheck =
                    switch herdrFailure.check {
                    case .connection, .remoteEnvironment: herdrFailure.check
                    default: .tmuxInstalled
                    }
                return PreflightReport(
                    backend: .tmux, failure: Failure(check: check, hint: herdrFailure.hint))
            }
            return PreflightReport(
                backend: .tmux, failure: Failure(check: .tmuxInstalled, hint: hint))
        }
    }

    /// Maps a transport failure onto the check it disproves, with a fix-it
    /// hint. `authMethod` steers the credential hint: a rejected device key
    /// and a wrong password have different fixes.
    static func failure(_ error: TransportError, authMethod: Host.AuthMethod) -> PreflightReport {
        let check: PreflightCheck
        let hint: String
        switch error {
        case .sshUnreachable(let detail):
            check = .connection
            hint = "Could not reach the Host over SSH. Check the address and port. (\(detail))"
        case .authenticationFailed:
            check = .connection
            switch authMethod {
            case .deviceKey:
                hint =
                    "The Host rejected the device key. Copy this Host's key line "
                    + "into ~/.ssh/authorized_keys on the Host, then run the checks again."
            case .rsaKey:
                hint =
                    "The Host rejected the RSA Key. Copy its public key from Edit Host and "
                    + "register it wherever that Host accepts SSH identities."
            case .password:
                hint = "The Host rejected the login. Check the username and password."
            }
        case .deviceKeyCorrupt:
            check = .connection
            hint =
                "The Device Key is corrupted. Edit this Host and choose Replace Device Key, "
                + "then add the new public key to ~/.ssh/authorized_keys on every Device Key Host."
        case .rsaKeyCorrupt:
            check = .connection
            hint =
                "The RSA Key is corrupted. Edit this Host and choose Replace RSA Key, then "
                + "register the new public key on every Host that uses it."
        case .rsaSignatureUnsupported:
            check = .connection
            hint =
                "The Host does not offer RSA-SHA2-512 signatures, which RSA Key requires. "
                + "Registering the key again will not help; enable rsa-sha2-512 on the Host "
                + "or choose another authentication method."
        case .hostKeyRejected:
            check = .connection
            hint = "The host key was not confirmed. Run the checks again and confirm the fingerprint."
        case .hostKeyMismatch(let known, let presented):
            check = .connection
            hint =
                "Host key changed: trusted \(known.displayString), the Host presented "
                + "\(presented.displayString). This can be a reinstalled server or an attack — "
                + "verify with the Host's owner before trusting it."
        case .socketNotFound(let path):
            check = .herdrInstalled
            hint =
                "No Herdr TUI at \(path). Install herdr on the Host, "
                + "or fix the session name."
        case .homeDirectoryUnresolvable(let detail):
            check = .remoteEnvironment
            hint =
                "Could not resolve the remote home directory, so the Herdr TUI socket "
                + "path is unknown. (\(detail))"
        case .invalidDirectoryPath(let path):
            check = .remoteEnvironment
            hint = "That folder path cannot be opened: \(path)."
        case .streamLocalOpenFailed(let path):
            check = .serverRunning
            hint =
                "Could not open the Herdr TUI socket at \(path). Herdr TUI may have stopped: "
                + "tap Start Herdr TUI. If it is running, enable SSH stream-local forwarding "
                + "and run the checks again."
        case .herdrNotRunning:
            check = .serverRunning
            hint = "Herdr TUI is installed but not running. Tap Start Herdr TUI to start it."
        case .herdrSessionNotFound(let path):
            check = .serverRunning
            hint =
                "No herdr session at \(path), and Waycar never creates one. Start the "
                + "session on the Host, or pick another under Available Sessions."
        case .tcpForwardingUnavailable:
            check = .connection
            hint =
                "The Jump Host refused TCP forwarding. Enable AllowTcpForwarding "
                + "in its SSH server configuration and try again."
        case .protocolVersionMismatch(let server, let supported):
            check = .protocolCompatible
            // Only reachable below the floor now: a newer Host connects and
            // carries an advisory notice instead of failing here.
            hint =
                "Herdr TUI on the Host speaks protocol \(server); this app needs at least "
                + "\(supported). Update herdr on the Host."
        case .malformedResponse(let detail):
            check = .protocolCompatible
            hint = "The server's reply did not parse as Herdr TUI protocol. (\(detail))"
        case .timedOut:
            check = .connection
            hint = "The Host did not answer in time. Check the connection and try again."
        case .cancelled:
            check = .connection
            hint = "The check was cancelled before it finished."
        case .apiRejected(let code, let message):
            check = .serverRunning
            hint = "Herdr TUI answered but rejected the check: \(message) (\(code))"
        case .moshSessionFailed(let detail):
            // A connect+ping preflight never opens a mosh session; keep the
            // closed taxonomy total anyway.
            check = .connection
            hint = "The mosh session failed. (\(detail))"
        case .channelFailed(let detail):
            check = .connection
            hint = "The connection failed unexpectedly. (\(detail))"
        case .eventsChannelAlreadyOpen, .terminalChannelAlreadyOpen:
            // Not reachable from a connect+ping preflight; keep the closed
            // taxonomy total anyway.
            check = .connection
            hint = "The connection is busy. Try again."
        case .herdrBinaryNotFound:
            // Preflight is one connect + ping and never execs herdr, so this
            // case cannot fire here. Keep the closed taxonomy total anyway.
            check = .connection
            hint = "The herdr CLI was not found on the Host."
        case .coreNotInstalled, .coreNotRunning, .coreNeedsUpdate, .coreNeedsWaycarUpdate,
            .coreRefused:
            // herdr-core's own failures reach a checklist through the core
            // branch of `failure(_:authMethod:backend:)`; keep this one
            // total.
            check = .protocolCompatible
            hint = error.presentation.message
        case .zellijNotInstalled, .zellijTooOld:
            check = .zellijInstalled
            hint = error.presentation.message
        case .tmuxNotInstalled:
            check = .herdrInstalled
            hint = "Neither Herdr TUI nor tmux was found on the Host. Install tmux 3.2 or later, or herdr."
        case .tmuxTooOld(let found):
            check = .protocolCompatible
            hint = "The Host has tmux \(found); Waycar needs tmux 3.2 or later. Update tmux on the Host."
        case .jumpHostFailed(let underlying):
            // The first hop broke, so the Host itself was never contacted and
            // nothing about it has been disproved. Name the Jump Host as the
            // thing to fix, or the user goes and debugs the wrong machine.
            check = .connection
            hint = Self.jumpHostHint(underlying, authMethod: authMethod)
        }
        return PreflightReport(
            backend: .herdr,
            failure: Failure(
                check: check, hint: hint,
                stoppedRuntime: error.startableRuntime == .herdr ? .herdr : nil))
    }

    /// Guidance for a first-hop failure. Deliberately not a recursive call
    /// into the Host-facing hints: every one of those tells the user to go fix
    /// something on the Host, which is exactly the wrong machine here.
    private static func jumpHostHint(
        _ error: TransportError, authMethod: Host.AuthMethod
    ) -> String {
        switch error {
        case .sshUnreachable(let detail):
            "Could not reach the Jump Host. Check its address and port. (\(detail))"
        case .authenticationFailed:
            switch authMethod {
            case .deviceKey:
                "The Jump Host rejected the Device Key. Add this Host's key line to "
                    + "~/.ssh/authorized_keys there, then run the checks again."
            case .rsaKey:
                "The Jump Host rejected the RSA Key. Register its public key on the Jump Host, "
                    + "then run the checks again."
            case .password:
                "The Jump Host rejected the login. It must accept the same password configured "
                    + "for this Host; separate passwords are not supported."
            }
        case .hostKeyRejected:
            "The Jump Host's key was not confirmed. Run the checks again and confirm "
                + "the fingerprint."
        case .hostKeyMismatch(let known, let presented):
            "Jump Host key changed: trusted \(known.displayString), it presented "
                + "\(presented.displayString). This can be a reinstalled server or an "
                + "attack — verify with its owner before trusting it."
        case .deviceKeyCorrupt:
            "The Device Key is corrupted, so the Jump Host could not be reached. Edit "
                + "this Host and choose Replace Device Key."
        case .rsaKeyCorrupt:
            "The RSA Key is corrupted, so the Jump Host could not be reached. Edit this Host "
                + "and choose Replace RSA Key."
        case .rsaSignatureUnsupported:
            "The Jump Host does not offer RSA-SHA2-512 signatures, which RSA Key requires on "
                + "both hops. Enable rsa-sha2-512 there or choose another authentication method."
        case .timedOut:
            "The Jump Host did not answer in time. Check the connection and try again."
        case .cancelled:
            "The check was cancelled before it finished."
        case .tcpForwardingUnavailable:
            "The Jump Host refused TCP forwarding. Enable AllowTcpForwarding "
                + "in its SSH server configuration and try again."
        default:
            "Could not connect through the Jump Host. \(error.presentation.explanation)"
        }
    }

    subscript(check: PreflightCheck) -> PreflightCheckStatus {
        guard let failure else {
            if check == .statusHooks, let hint = statusHooks?.warning {
                return .warning(hint: hint)
            }
            return .passed
        }
        let checks = PreflightCheck.checks(for: backend)
        guard
            let failedIndex = checks.firstIndex(of: failure.check),
            let index = checks.firstIndex(of: check)
        else { return .blocked }
        if index < failedIndex { return .passed }
        if index == failedIndex {
            return failure.stoppedRuntime == nil
                ? .failed(hint: failure.hint) : .stopped(hint: failure.hint)
        }
        return .blocked
    }

    /// Every hard check passed. A soft warning (Status hooks) still counts.
    var isFullyPassed: Bool {
        failure == nil
    }
}
