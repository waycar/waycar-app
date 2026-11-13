import Foundation
import Testing

@testable import Waycar

@Suite("Host section summary")
struct HostSectionSummaryTests {
    private func hooksReport(agents: [StatusHooksReport.AgentHooks]) -> StatusHooksReport {
        StatusHooksReport(
            version: 1,
            hostTools: .init(version: "2.2.0", pluginRoot: "/home/dev/.waycar"),
            backends: .init(herdr: false, tmux: "3.4"),
            configDir: nil,
            agents: agents)
    }

    // MARK: Preflight

    @Test func noReportIsPending() {
        #expect(HostSectionSummary.preflight(report: nil).severity == .pending)
    }

    @Test func allPassedIsGreenWithCount() {
        let summary = HostSectionSummary.preflight(report: .allPassed)
        #expect(summary.severity == .allPassed)
        #expect(summary.detail == "All 5 checks passed")
    }

    @Test func softWarningIsYellow() {
        let report = PreflightReport.passed(
            on: .tmux, statusHooks: .hostToolsMissing)
        let summary = HostSectionSummary.preflight(report: report)
        #expect(summary.severity == .warning)
        #expect(summary.detail == "Passed with 1 warning")
    }

    @Test(arguments: [
        (PreflightCheck.herdrInstalled, HostBackend.herdr, "Herdr TUI not installed"),
        (.serverRunning, .herdr, "Herdr TUI not running"),
        (.coreInstalled, .core, "Herdr Core not installed"),
        (.protocolCompatible, .herdr, "protocol compatible failed"),
    ])
    func hardFailureIsBlockingAndNamesTheCheck(
        check: PreflightCheck, backend: HostBackend, expected: String
    ) {
        let report = PreflightReport.failure(check: check, hint: "failed", backend: backend)
        let summary = HostSectionSummary.preflight(report: report)
        #expect(summary.severity == .blocking)
        #expect(summary.detail == expected)
    }

    /// A stopped runtime is calm: its own severity, which never expands the
    /// section the way a blocking failure does (#389).
    @Test(arguments: [
        (TransportError.herdrNotRunning(path: "/s"), HostBackend.herdr, "Herdr TUI not running"),
        (.streamLocalOpenFailed(path: "/s"), .herdr, "Herdr TUI not running"),
        (.coreNotRunning, .core, "Herdr Core not running"),
    ])
    func aStoppedRuntimeIsItsOwnCalmState(
        error: TransportError, backend: HostBackend, expected: String
    ) {
        let report = PreflightReport.failure(error, authMethod: .deviceKey, backend: backend)
        let summary = HostSectionSummary.preflight(report: report)
        #expect(summary.severity == .stopped)
        #expect(summary.detail == expected)
    }

    @Test func tmuxPassWithInstalledHooksIsGreen() {
        let report = PreflightReport.passed(
            on: .tmux,
            statusHooks: .reported(
                hooksReport(agents: [
                    .init(agent: "claude", installed: true, configPath: nil, needsCodexReview: nil)
                ])))
        #expect(HostSectionSummary.preflight(report: report).severity == .allPassed)
    }

    // MARK: Status hooks

    @Test func everyHookInstalledIsGreen() {
        let state = StatusHooksState.reported(
            hooksReport(agents: [
                .init(agent: "claude", installed: true, configPath: nil, needsCodexReview: nil),
                .init(agent: "codex", installed: true, configPath: nil, needsCodexReview: false),
            ]))
        let summary = HostSectionSummary.statusHooks(state, installError: nil)
        #expect(summary.severity == .allPassed)
        #expect(summary.detail == "Installed for all 2 agents")
    }

    @Test func missingHooksAreYellow() {
        let state = StatusHooksState.reported(
            hooksReport(agents: [
                .init(agent: "claude", installed: true, configPath: nil, needsCodexReview: nil),
                .init(agent: "codex", installed: false, configPath: nil, needsCodexReview: nil),
            ]))
        let summary = HostSectionSummary.statusHooks(state, installError: nil)
        #expect(summary.severity == .warning)
        #expect(summary.detail == "Missing for Codex")
    }

    @Test func notInstalledAgentsNeverWarn() {
        let state = StatusHooksState.reported(
            hooksReport(agents: [
                .init(
                    agent: "claude", installed: true, detected: true, configPath: nil,
                    needsCodexReview: nil),
                .init(
                    agent: "grok", installed: false, detected: false, configPath: nil,
                    needsCodexReview: nil),
            ]))
        let summary = HostSectionSummary.statusHooks(state, installError: nil)
        #expect(summary.severity == .allPassed)
        #expect(summary.detail == "Installed for 1 agent")
        #expect(state.missingAgents.isEmpty)
        #expect(state.warning == nil)
    }

    @Test func missingHooksOnInstalledAgentsWarnByName() {
        let state = StatusHooksState.reported(
            hooksReport(agents: [
                .init(
                    agent: "codex", installed: false, detected: true, configPath: nil,
                    needsCodexReview: nil),
                .init(
                    agent: "omp", installed: false, detected: true, configPath: nil,
                    needsCodexReview: nil),
                .init(
                    agent: "agy", installed: false, detected: false, configPath: nil,
                    needsCodexReview: nil),
            ]))
        let summary = HostSectionSummary.statusHooks(state, installError: nil)
        #expect(summary.severity == .warning)
        #expect(summary.detail == "Missing for Codex and OMP")
    }

    @Test func noInstalledAgentsIsNeutral() {
        let state = StatusHooksState.reported(
            hooksReport(agents: [
                .init(
                    agent: "grok", installed: false, detected: false, configPath: nil,
                    needsCodexReview: nil),
                .init(
                    agent: "agy", installed: false, detected: false, configPath: nil,
                    needsCodexReview: nil),
            ]))
        let summary = HostSectionSummary.statusHooks(state, installError: nil)
        #expect(summary.severity == .neutral)
        #expect(summary.detail == "No agents installed")
    }

    @Test func hostToolsMissingIsYellow() {
        let summary = HostSectionSummary.statusHooks(.hostToolsMissing, installError: nil)
        #expect(summary.severity == .warning)
    }

    @Test func unreadableIsYellow() {
        let summary = HostSectionSummary.statusHooks(.unreadable("timeout"), installError: nil)
        #expect(summary.severity == .warning)
    }

    @Test func codexReviewNeededIsYellow() {
        let state = StatusHooksState.reported(
            hooksReport(agents: [
                .init(agent: "codex", installed: true, configPath: nil, needsCodexReview: true)
            ]))
        #expect(HostSectionSummary.statusHooks(state, installError: nil).severity == .warning)
    }

    @Test func installErrorIsBlocking() {
        let state = StatusHooksState.reported(hooksReport(agents: []))
        let summary = HostSectionSummary.statusHooks(state, installError: "Install failed: exit 1")
        #expect(summary.severity == .blocking)
    }
}
