import Foundation
import Testing

@testable import Waycar

@Suite("Preflight report")
struct PreflightReportTests {
    private let fingerprintA = HostKeyFingerprint(publicKeyBlob: Data("blob-a".utf8))
    private let fingerprintB = HostKeyFingerprint(publicKeyBlob: Data("blob-b".utf8))

    @Test(arguments: HostBackend.allCases)
    func keysOnlyPasswordHostOffersDeviceKeyRecovery(backend: HostBackend) {
        let report = PreflightReport.failure(
            .passwordLoginUnavailable, authMethod: .password, backend: backend, hostName: "Studio Mac")
        #expect(report.backend == backend)
        #expect(report.needsDeviceKey)
        #expect(report.stoppedRuntime == nil)
        #expect(report[.connection] == .failed(
            hint: "Studio Mac accepts only keys. Run the command below in Terminal on "
                + "Studio Mac, then tap Check Again."))
        #expect(!report.isFullyPassed)
    }

    @Test func successPassesEveryCheck() {
        let report = PreflightReport.allPassed
        for check in PreflightCheck.allCases {
            #expect(report[check] == .passed)
        }
        #expect(report.isFullyPassed)
    }

    @Test func failurePassesEarlierChecksAndBlocksLaterOnes() {
        let socketPath = "/home/dev/.config/herdr/herdr.sock"
        let report = PreflightReport.failure(
            .socketNotFound(path: socketPath), authMethod: .deviceKey)

        #expect(report[.connection] == .passed)
        #expect(report[.remoteEnvironment] == .passed)
        guard case .failed(let hint) = report[.herdrInstalled] else {
            Issue.record("herdr check should fail")
            return
        }
        #expect(
            hint == "No Herdr TUI at \(socketPath). Install herdr on the Host, or fix the session name.")
        #expect(report[.serverRunning] == .blocked)
        #expect(report[.protocolCompatible] == .blocked)
        #expect(!report.isFullyPassed)
    }

    /// SSH access plus a running herdr are the whole Host contract now
    /// (ADR 0011): the checklist must not send anyone off to install a helper.
    @Test func theChecklistNeverAsksForSocat() {
        for check in PreflightCheck.allCases {
            #expect(!check.title.localizedCaseInsensitiveContains("socat"))
        }
    }

    /// A stale socket may be a stopped herdr, or a server whose SSH refuses
    /// stream-local forwarding: it offers the Start and names the policy.
    @Test func streamLocalFailureOffersTheStartThenTheForwardingPolicy() {
        let path = "/home/dev/.config/herdr/herdr.sock"
        let report = PreflightReport.failure(
            .streamLocalOpenFailed(path: path), authMethod: .deviceKey)
        #expect(report.stoppedRuntime == .herdr)
        #expect(
            report[.serverRunning]
                == .stopped(
                    hint: "Could not open the Herdr TUI socket at \(path). Herdr TUI may have "
                        + "stopped: tap Start Herdr TUI. If it is running, enable SSH "
                        + "stream-local forwarding and run the checks again."))
        #expect(report[.herdrInstalled] == .passed)
        #expect(report[.protocolCompatible] == .blocked)
        #expect(!report.isFullyPassed)
    }

    /// A stopped herdr is installed: the install row passes, and the server
    /// row is the calm stopped state pointing at Start Herdr TUI (#389).
    @Test func herdrNotRunningIsTheStoppedStateWithInstallPassed() {
        let report = PreflightReport.failure(
            .herdrNotRunning(path: "/home/dev/.config/herdr/herdr.sock"),
            authMethod: .deviceKey)
        #expect(report.stoppedRuntime == .herdr)
        #expect(report[.herdrInstalled] == .passed)
        #expect(
            report[.serverRunning]
                == .stopped(
                    hint: "Herdr TUI is installed but not running. Tap Start Herdr TUI to start it."))
        #expect(report[.protocolCompatible] == .blocked)
        #expect(!report.isFullyPassed)
    }

    /// A stopped Herdr Core is the same calm state on core's checklist.
    @Test func coreNotRunningIsTheStoppedStateOnTheHandshake() {
        let report = PreflightReport.failure(
            .coreNotRunning, authMethod: .deviceKey, backend: .core)
        #expect(report.backend == .core)
        #expect(report.stoppedRuntime == .core)
        #expect(report[.coreInstalled] == .passed)
        #expect(report[.coreVersion] == .passed)
        #expect(
            report[.coreHello]
                == .stopped(
                    hint: "Herdr Core is installed but not running. Tap Start Herdr Core to start it."))
        #expect(report[.coreEvents] == .blocked)
    }

    /// A missing session is no stopped server: a plain failure, no Start.
    @Test func aMissingSessionFailsTheServerCheckWithoutAStart() {
        let path = "/home/dev/.config/herdr/sessions/work/herdr.sock"
        let report = PreflightReport.failure(
            .herdrSessionNotFound(path: path), authMethod: .deviceKey)
        #expect(report.stoppedRuntime == nil)
        #expect(
            report[.serverRunning]
                == .failed(
                    hint: "No herdr session at \(path), and Waycar never creates one. Start the "
                        + "session on the Host, or pick another under Available Sessions."))
    }

    /// Only the runtime's own checklist offers its Start: a herdr socket
    /// failure seen on core's or tmux's checklist is a plain failure there.
    @Test func aStoppedStateNeedsItsOwnRuntimesChecklist() {
        for backend in [HostBackend.core, .tmux] {
            for error in [
                TransportError.herdrNotRunning(path: "/s"), .streamLocalOpenFailed(path: "/s"),
            ] {
                let report = PreflightReport.failure(
                    error, authMethod: .deviceKey, backend: backend)
                #expect(report.stoppedRuntime == nil, "\(error) on \(backend)")
                #expect(
                    !PreflightCheck.checks(for: backend).contains {
                        if case .stopped = report[$0] { true } else { false }
                    })
            }
        }
        #expect(PreflightReport.failure(.sshUnreachable(detail: "down"), authMethod: .deviceKey)
            .stoppedRuntime == nil)
    }

    @Test(arguments: [
        (TransportError.sshUnreachable(detail: "refused"), PreflightCheck.connection),
        (.authenticationFailed, .connection),
        (.deviceKeyCorrupt, .connection),
        (.rsaKeyCorrupt, .connection),
        (.rsaSignatureUnsupported, .connection),
        (.hostKeyRejected(
            presented: HostKeyFingerprint(publicKeyBlob: Data("blob-a".utf8))), .connection),
        (.timedOut, .connection),
        (.cancelled, .connection),
        (.channelFailed(detail: "boom"), .connection),
        (.eventsChannelAlreadyOpen, .connection),
        // Not reachable from connect+ping (preflight never execs herdr).
        (.herdrBinaryNotFound, .connection),
        (.jumpHostFailed(.sshUnreachable(detail: "refused")), .connection),
        (.tcpForwardingUnavailable, .connection),
        (.socketNotFound(path: "/home/dev/.config/herdr/herdr.sock"), .herdrInstalled),
        (.homeDirectoryUnresolvable(detail: "no $HOME"), .remoteEnvironment),
        (.herdrSessionNotFound(path: "/home/dev/.config/herdr/sessions/w/herdr.sock"), .serverRunning),
        // A stopped server is `.stopped` instead (`herdrNotRunningIsTheStoppedState…`).
        // Below the floor: the only direction that still produces this error
        // (#140 made a newer server usable rather than a mismatch).
        (.protocolVersionMismatch(server: 16, supported: 17), .protocolCompatible),
        (.malformedResponse("junk"), .protocolCompatible),
    ])
    func mapsEveryTransportErrorOntoItsCheck(error: TransportError, check: PreflightCheck) {
        let report = PreflightReport.failure(error, authMethod: .deviceKey)
        guard case .failed = report[check] else {
            Issue.record("\(error) should fail the \(check) check")
            return
        }
    }

    @Test func hostKeyMismatchHintNamesBothFingerprints() {
        let report = PreflightReport.failure(
            .hostKeyMismatch(known: fingerprintA, presented: fingerprintB), authMethod: .deviceKey)
        guard case .failed(let hint) = report[.connection] else {
            Issue.record("connection check should fail")
            return
        }
        #expect(hint.contains(fingerprintA.displayString))
        #expect(hint.contains(fingerprintB.displayString))
    }

    @Test func authenticationHintDependsOnTheAuthMethod() {
        let keyReport = PreflightReport.failure(.authenticationFailed, authMethod: .deviceKey)
        let rsaReport = PreflightReport.failure(.authenticationFailed, authMethod: .rsaKey)
        let passwordReport = PreflightReport.failure(.authenticationFailed, authMethod: .password)
        guard case .failed(let keyHint) = keyReport[.connection],
            case .failed(let rsaHint) = rsaReport[.connection],
            case .failed(let passwordHint) = passwordReport[.connection]
        else {
            Issue.record("connection check should fail")
            return
        }
        #expect(keyHint.contains("authorized_keys"))
        #expect(rsaHint.contains("RSA Key"))
        #expect(rsaHint.contains("SSH identities"))
        #expect(passwordHint.contains("password"))
    }

    @Test func unsupportedRSASignatureIsNotReportedAsARejectedKey() {
        let direct = PreflightReport.failure(.rsaSignatureUnsupported, authMethod: .rsaKey)
        let jump = PreflightReport.failure(
            .jumpHostFailed(.rsaSignatureUnsupported), authMethod: .rsaKey)
        guard case .failed(let directHint) = direct[.connection],
            case .failed(let jumpHint) = jump[.connection]
        else {
            Issue.record("connection check should fail")
            return
        }
        #expect(directHint.contains("rsa-sha2-512"))
        #expect(!directHint.contains("rejected"))
        #expect(jumpHint.contains("Jump Host"))
        #expect(jumpHint.contains("rsa-sha2-512"))
    }

    @Test func jumpHostFailureHintNamesTheFirstHop() {
        let report = PreflightReport.failure(
            .jumpHostFailed(.authenticationFailed), authMethod: .password)
        guard case .failed(let hint) = report[.connection] else {
            Issue.record("connection check should fail")
            return
        }
        #expect(hint.contains("Jump Host"))
        #expect(hint.contains("same password"))
    }

    @Test func forwardingPolicyHintNamesTheRequiredServerSetting() {
        let report = PreflightReport.failure(
            .tcpForwardingUnavailable, authMethod: .deviceKey)
        guard case .failed(let hint) = report[.connection] else {
            Issue.record("connection check should fail")
            return
        }
        #expect(hint.contains("Jump Host"))
        #expect(hint.contains("AllowTcpForwarding"))
    }

    @Test func protocolMismatchHintNamesBothVersions() {
        let report = PreflightReport.failure(
            .protocolVersionMismatch(server: 16, supported: 17), authMethod: .deviceKey)
        guard case .failed(let hint) = report[.protocolCompatible] else {
            Issue.record("protocol check should fail")
            return
        }
        #expect(hint.contains("16"))
        #expect(hint.contains("17"))
    }

    @Test func plainFailureAttachesTheGivenHintToTheGivenCheck() {
        let report = PreflightReport.failure(check: .connection, hint: "no password saved")
        #expect(report[.connection] == .failed(hint: "no password saved"))
        #expect(report[.herdrInstalled] == .blocked)
    }

    // MARK: tmux (ADR 0026)

    @Test func herdrChecklistNamesTheTUI() {
        #expect(PreflightCheck.herdrInstalled.title == "Herdr TUI installed")
        #expect(PreflightCheck.serverRunning.title == "Herdr TUI running")
        #expect(
            PreflightCheck.checks(for: .herdr)
                == [.connection, .remoteEnvironment, .herdrInstalled, .serverRunning, .protocolCompatible])
        #expect(PreflightReport.allPassed.backend == .herdr)
    }

    @Test func coreChecklistNamesTheCoreRuntime() {
        #expect(PreflightCheck.coreInstalled.title == "Herdr Core installed")
        #expect(PreflightCheck.coreVersion.title == "Herdr Core \(CorePresence.minimumVersion) or later")
        #expect(PreflightCheck.coreHello.title == "Herdr Core answers")
        #expect(PreflightCheck.coreEvents.title == "Herdr Core live updates")
    }

    @Test func tmuxChecklistEndsWithTheSoftHooksRow() {
        #expect(
            PreflightCheck.checks(for: .tmux)
                == [.connection, .remoteEnvironment, .tmuxInstalled, .statusHooks])
    }

    @Test func missingTmuxFailsTheTmuxCheckWithItsPresentation() {
        let report = PreflightReport.failure(
            .tmuxNotInstalled, authMethod: .deviceKey, backend: .tmux)

        #expect(report[.connection] == .passed)
        #expect(report[.remoteEnvironment] == .passed)
        #expect(
            report[.tmuxInstalled]
                == .failed(hint: TransportError.tmuxNotInstalled.presentation.message))
        #expect(report[.statusHooks] == .blocked)
        #expect(!report.isFullyPassed)
    }

    /// Scenario 9: an EL8 box fails preflight on its tmux version.
    @Test func oldTmuxFailsTheTmuxCheckNamingBothVersions() {
        let report = PreflightReport.failure(
            .tmuxTooOld(found: "2.7"), authMethod: .deviceKey, backend: .tmux)

        guard case .failed(let hint) = report[.tmuxInstalled] else {
            Issue.record("tmux check should fail")
            return
        }
        #expect(hint.contains("2.7"))
        #expect(hint.contains("3.2"))
        #expect(report[.statusHooks] == .blocked)
    }

    @Test func tmuxConnectionFailuresStayOnTheConnectionCheck() {
        let report = PreflightReport.failure(
            .sshUnreachable(detail: "refused"), authMethod: .deviceKey, backend: .tmux)

        guard case .failed = report[.connection] else {
            Issue.record("connection check should fail")
            return
        }
        #expect(report[.tmuxInstalled] == .blocked)
        #expect(report[.statusHooks] == .blocked)
    }

    /// The tmux list has no herdr server or protocol rows, so every error
    /// still fails exactly one row of it: the mapping stays total.
    @Test(arguments: [
        TransportError.socketNotFound(path: "/s"),
        .streamLocalOpenFailed(path: "/s"),
        .herdrNotRunning(path: "/s"),
        .protocolVersionMismatch(server: 16, supported: 17),
        .malformedResponse("junk"),
        .apiRejected(code: "tmux_error", message: "no server"),
        .herdrBinaryNotFound,
        .homeDirectoryUnresolvable(detail: "no $HOME"),
        .authenticationFailed,
        .tmuxNotInstalled,
        .tmuxTooOld(found: "3.1c"),
    ])
    func everyErrorFailsExactlyOneTmuxCheck(error: TransportError) {
        let report = PreflightReport.failure(error, authMethod: .deviceKey, backend: .tmux)
        let failed = PreflightCheck.checks(for: .tmux).filter {
            if case .failed = report[$0] { true } else { false }
        }
        #expect(failed.count == 1, "\(error)")
        #expect(!failed.contains(.statusHooks), "\(error)")
    }

    @Test func missingHostToolsWarnButNeverFailTheRun() {
        let report = PreflightReport.passed(on: .tmux, statusHooks: .hostToolsMissing)

        #expect(report.isFullyPassed)
        #expect(report[.tmuxInstalled] == .passed)
        guard case .warning(let hint) = report[.statusHooks] else {
            Issue.record("the hooks row should warn")
            return
        }
        #expect(hint.contains(WaycarPluginRequirement.installCommand))
    }

    @Test func missingAgentHooksWarnNamingTheAgents() {
        let hooks = StatusHooksState.reported(
            hooksReport([
                agentHooks("claude", installed: true),
                agentHooks("codex", installed: false),
            ]))
        let report = PreflightReport.passed(on: .tmux, statusHooks: hooks)

        #expect(report.isFullyPassed)
        #expect(hooks.missingAgents == ["Codex"])
        guard case .warning(let hint) = report[.statusHooks] else {
            Issue.record("the hooks row should warn")
            return
        }
        #expect(hint.contains("Codex"))
        #expect(!hint.contains("Claude Code"))
    }

    @Test func codexHooksAwaitingReviewWarnWithTheHooksStep() {
        let hooks = StatusHooksState.reported(
            hooksReport([agentHooks("codex", installed: true, needsCodexReview: true)]))
        let report = PreflightReport.passed(on: .tmux, statusHooks: hooks)

        #expect(report.isFullyPassed)
        #expect(report[.statusHooks] == .warning(hint: StatusHooksState.codexReviewNote))
    }

    @Test func installedHooksPassTheSoftRow() {
        let hooks = StatusHooksState.reported(
            hooksReport([
                agentHooks("claude", installed: true),
                agentHooks("codex", installed: true, needsCodexReview: false),
            ]))

        #expect(PreflightReport.passed(on: .tmux, statusHooks: hooks)[.statusHooks] == .passed)
    }

    @Test func herdrRunsIgnoreHooksState() {
        let report = PreflightReport.passed(on: .herdr, statusHooks: .hostToolsMissing)
        #expect(report == .allPassed)
    }

    private func agentHooks(
        _ agent: String, installed: Bool, needsCodexReview: Bool? = nil
    ) -> StatusHooksReport.AgentHooks {
        StatusHooksReport.AgentHooks(
            agent: agent, installed: installed, configPath: "/home/dev/.\(agent)/hooks.json",
            needsCodexReview: needsCodexReview)
    }

    private func hooksReport(_ agents: [StatusHooksReport.AgentHooks]) -> StatusHooksReport {
        StatusHooksReport(
            version: 1,
            hostTools: StatusHooksReport.HostTools(version: "0.9.0", pluginRoot: "/home/dev/.waycar"),
            backends: StatusHooksReport.Backends(herdr: false, tmux: "3.4"),
            configDir: nil,
            agents: agents)
    }
}
