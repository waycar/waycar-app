import Foundation
import Synchronization
import Testing

@testable import Waycar

@Suite("Zellij launches")
struct ZellijLaunchTests {
    private static let tag = UUID(uuidString: "D5BBED96-805A-4EAA-9F0E-65735521AE39")!
    private static var tagged: String {
        ZellijTransportTests.panes.replacingOccurrences(of: "\"pane_command\":\"claude\"",
            with: "\"terminal_command\":\"env WAYCAR_LAUNCH=\(tag.uuidString) /bin/sh -c launch\",\"pane_command\":\"claude\"")
    }

    @Test(arguments: ["client", "headless", "unconfirmed"])
    func selectsTabOrBackgroundAndConfirmsByTag(path: String) async throws {
        let created = Mutex(false)
        let background = Mutex(false)
        let rig = try await ZellijTransportTests.open(launchConfirmationTimeout: .zero) { command, _ in
            if command.contains("new-tab") {
                created.withLock { $0 = path == "client" }
                return FakeHostSSHServices.result(stdout: path == "headless" ? "" : "waycar-zellij-client\n2\n")
            }
            if command.contains("attach -b") {
                created.withLock { $0 = true }
                background.withLock { $0 = true }
                return FakeHostSSHServices.result()
            }
            if command.contains("list-panes") {
                return FakeHostSSHServices.result(stdout: created.withLock { $0 } ? Self.tagged : "[]")
            }
            return FakeHostSSHServices.result(stdout: command.contains("ls -s") ? "fixture\n" : "")
        }
        let agent = try await rig.transport.startAgent(AgentLaunchRequest(
            kind: "claude", name: "worker", workspaceID: "zellij:fixture", cwd: "/work", launchID: Self.tag))
        #expect(agent.kind == "claude")
        #expect(agent.paneID == "zellij:\(path == "client" ? "fixture" : "worker")/terminal_0")
        #expect(background.withLock { $0 } == (path != "client"))
        let creation = try #require(await rig.session.execs.first { $0.command.contains("new-tab") })
        #expect(creation.command.contains("list-clients"))
        #expect(creation.command.contains("--no-focus"))
        #expect(creation.command.contains(Self.tag.uuidString))
        // A lone pane's Agent is named by its tab. `new-tab --name` names it; a background
        // session's tab starts with Zellij's default, so the launch renames it.
        let rename = await rig.session.execs.first { $0.command.contains("rename-tab-by-id") }
        if path == "client" {
            #expect(creation.command.contains("worker") && rename == nil)
        } else {
            #expect(rename?.command.contains("worker") == true)
        }
        try await rig.transport.close()
    }

    @Test(arguments: [true, false])
    func uncertainLaunchReconcilesFreshHostInventory(found: Bool) async throws {
        let created = Mutex(false)
        let rig = try await ZellijTransportTests.open(launchConfirmationTimeout: .zero) { command, _ in
            if command.contains("ls -n") { return FakeHostSSHServices.result(stdout: "fixture [Created 1s ago]\n") }
            if command.contains("attach -b") { created.withLock { $0 = true }; return FakeHostSSHServices.result() }
            if command.contains("list-panes") {
                return FakeHostSSHServices.result(stdout: found || created.withLock { $0 } ? Self.tagged : "[]")
            }
            return FakeHostSSHServices.result(stdout: "fixture\n")
        }
        let agent = try await rig.transport.startAgentInNewWorkspace(AgentLaunchRequest(
            kind: "claude", name: "worker", launchID: Self.tag, mayHaveStarted: true),
            workspace: NewWorkspaceSpec(directory: "/work", label: "worker"))
        #expect(agent.paneID == "zellij:\(found ? "fixture" : "worker")/terminal_0")
        #expect(await rig.session.execs.filter { $0.command.contains("attach -b") }.count == (found ? 0 : 1))
        try await rig.transport.close()
    }

    @Test func codexLaunchUsesSharedPathProbeAndKeepsNoDaemon() async throws {
        let rig = try await ZellijTransportTests.open(launchConfirmationTimeout: .zero) { command, _ in
            if command == SSHTransportSettings.defaultCodexHelpCommand {
                return FakeHostSSHServices.result(stdout: "--no-daemon")
            }
            if command.contains("list-panes") { return FakeHostSSHServices.result(stdout: Self.tagged) }
            return FakeHostSSHServices.result()
        }
        _ = try await rig.transport.startAgentInNewWorkspace(
            AgentLaunchRequest(kind: "codex", name: "worker", launchID: Self.tag),
            workspace: NewWorkspaceSpec(directory: "/work", label: "worker"))
        #expect(await rig.session.execs.contains { $0.command == SSHTransportSettings.defaultCodexHelpCommand })
        #expect(await rig.session.execs.first { $0.command.contains("attach -b") }?.command.contains("--no-daemon") == true)
        try await rig.transport.close()
    }

    @Test func newTerminalStartsAndReconcilesItsTaggedLoginShell() async throws {
        let rig = try await ZellijTransportTests.open(launchConfirmationTimeout: .zero) { command, _ in
            if command.contains("ls -n") { return FakeHostSSHServices.result(stdout: "shell [Created 1s ago]\n") }
            if command.contains("list-panes") { return FakeHostSSHServices.result(stdout: Self.tagged) }
            return FakeHostSSHServices.result()
        }
        let request = ShellLaunchRequest(name: "shell", launchID: Self.tag)
        let first = try await rig.transport.startShellTerminalInNewWorkspace(request,
            workspace: NewWorkspaceSpec(directory: "/work", label: "shell"))
        let again = try await rig.transport.startShellTerminal(ShellLaunchRequest(
            name: "shell", launchID: Self.tag, mayHaveStarted: true))
        #expect(first == again)
        let starts = await rig.session.execs.filter { $0.command.contains("attach -b") }
        #expect(starts.count == 1)
        #expect(starts.first?.command.contains("WAYCAR_SHELL=1") == true)
        #expect(starts.first?.command.contains(Self.tag.uuidString) == true)
        try await rig.transport.close()
    }

    @Test func shellCarriesTagAndUsesLoginShellAndLoginSessionStartIsOptIn() async throws {
        let line = ZellijCommand.shellLaunchLine(tag: Self.tag.uuidString)
        #expect(line.contains("WAYCAR_SHELL=1"))
        #expect(line.contains("\"$SHELL\" -l"))
        let plain = ZellijTransport.backgroundStart(command: "start-background", inLoginSession: false)
        #expect(plain.command == "start-background" && plain.input.isEmpty)
        let login = ZellijTransport.backgroundStart(command: "start-background", inLoginSession: true)
        #expect(login.command.contains("launchctl bootstrap"))
        #expect(String(decoding: login.input, as: UTF8.self).contains("start-background"))
    }
}
