import Foundation
import Testing

@testable import Waycar

@Suite("Zellij backend wiring")
struct ZellijBackendTests {
    @Test func detectionParsesVersionPathFloorAndOrder() throws {
        let output = """
            __WAYCAR_BACKENDS__
            herdr=path
            tmux=tmux 3.4
            zellij=0.46.0
            zellijpath=/home/user/.cargo/bin/zellij
            __WAYCAR_BACKENDS_END__
            """
        let presence = try #require(HostBackendDetection.presence(fromOutput: Data(output.utf8)))
        #expect(presence.zellij?.path == "/home/user/.cargo/bin/zellij")
        #expect(presence.zellij?.meetsFloor == true)
        #expect(presence.backends == [.herdr, .tmux, .zellij])
        #expect(!ZellijPresence(version: "0.45.1", path: "/bin/zellij").meetsFloor)
        #expect(!ZellijPresence(version: "unknown", path: "/bin/zellij").meetsFloor)
        #expect(ZellijPresence(version: "1.0.0", path: "/bin/zellij").meetsFloor)
        #expect(HostDetectionProbe.zellij.command == "zellij --version")
        #expect(HostDetectionProbe.zellij.backend == .zellij)
        let command = HostBackendDetection.command(socket: .defaultSession, probesPlugin: false)
        #expect(command.contains("waycar_probe zellij"))
        #expect(!command.contains("action list-panes"))
    }

    @Test func oldPresenceCachesStillDecode() throws {
        let cache = Data(#"{"herdr":true,"tmuxVersion":"3.4"}"#.utf8)
        let presence = try JSONDecoder().decode(HostBackendPresence.self, from: cache)
        #expect(presence.zellij == nil)
        #expect(presence.backends == [.herdr, .tmux])
    }

    @Test func capabilitiesOfferLaunchWithoutTakeoverOrWorktrees() {
        #expect(HostBackend.zellij.hasTerminal)
        #expect(!HostBackend.zellij.fillsHerdrSlot)
        #expect(!HostBackend.zellij.capabilities.takeover)
        #expect(HostBackend.zellij.capabilities.startsAgents)
        #expect(!HostBackend.zellij.capabilities.worktrees)
        #expect(HostBackend.zellij.capabilities.renaming)
        #expect(HostBackend.zellij.displayName == "Zellij")
        #expect(HostBackendGap(presence: HostBackendPresence(herdr: false, tmuxVersion: nil,
            zellij: .init(version: "0.46.0", path: "/bin/zellij"))) == nil)
        #expect(HostBackendGap(presence: HostBackendPresence(herdr: false, tmuxVersion: nil,
            zellij: .init(version: "0.45.1", path: "/bin/zellij"))) == .noBackend)
    }

    @Test @MainActor func zellijOnlyHostUsesZellijAsItsDefaultLaunchBackend() throws {
        let suite = "ZellijBackendTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ConsoleStore(
            pins: PinnedAgentsStore(defaults: defaults), unread: UnreadAgentsStore(defaults: defaults),
            chatMode: ChatModeStore(defaults: defaults), rowLayouts: AgentRowLayoutStore(defaults: defaults),
            backendPreferences: HostBackendPreferences(defaults: defaults))
        let host = Host.fixture()
        let session = EventsSession(subscriptions: [], connect: { throw TransportError.cancelled }, keepalive: nil)
        store.projections[ConsoleScope(hostID: host.id, backend: .zellij)] = HostConsoleProjection(
            host: host, session: session, backend: .zellij, snapshotRetryDelay: .seconds(1), onChange: {})
        #expect(store.defaultNewAgentBackend(on: host.id) == .zellij)
        store.projections = [:]
    }

    @Test func preflightHasSeparateInstalledVersionAndAnswerChecks() {
        #expect(
            PreflightCheck.checks(for: .zellij) == [
                .connection, .remoteEnvironment, .zellijInstalled, .zellijVersion, .zellijAnswers,
                .statusHooks,
            ])
        let old = PreflightReport.failure(
            .zellijTooOld(found: "0.45.1"), authMethod: .deviceKey, backend: .zellij)
        #expect(old[.zellijInstalled] == .passed)
        guard case .failed = old[.zellijVersion] else {
            Issue.record("wrong failing check")
            return
        }
        #expect(PreflightReport.passed(on: .zellij)[.zellijAnswers] == .passed)
    }

    @Test func hookMinimumChangesOnlyForZellijHostsAndBackendsDecodeOptionally() throws {
        let installed = WaycarPluginDetection.installed(.init(version: "2.5.0", mode: .tmux))
        #expect(
            WaycarPluginRequirement.status(of: installed, backends: [.tmux]) == .current(version: "2.5.0"))
        #expect(
            WaycarPluginRequirement.status(of: installed, backends: [.core]) == .current(version: "2.5.0"))
        #expect(
            WaycarPluginRequirement.status(of: installed, backends: [.zellij])
                == .outdated(installed: "2.5.0", required: "2.6.0"))
        let before = try JSONDecoder().decode(
            StatusHooksReport.Backends.self, from: Data(#"{"herdr":false}"#.utf8))
        #expect(before.zellij == nil)
        let after = try JSONDecoder().decode(
            StatusHooksReport.Backends.self, from: Data(#"{"herdr":false,"zellij":"0.46.0"}"#.utf8))
        #expect(after.zellij == "0.46.0")
    }

    @Test @MainActor func visibilityDefaultsOnAndKeepsOtherRuntimeKeys() throws {
        let suite = "ZellijBackendTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let hostID = UUID()
        let prefs = HostBackendPreferences(defaults: defaults)
        #expect(prefs.showsZellij(for: hostID))
        prefs.setShowsRuntime(false, runtime: .core, for: hostID)
        prefs.setShowsZellij(false, for: hostID)
        let reloaded = HostBackendPreferences(defaults: defaults)
        #expect(!reloaded.showsZellij(for: hostID))
        #expect(!reloaded.showsRuntime(.core, for: hostID))
        #expect(reloaded.showsTmux(for: hostID))
        prefs.setShowsZellij(true, for: hostID)
        #expect(HostBackendPreferences(defaults: defaults).showsZellij(for: hostID))
    }

    @Test func hidingZellijPreservesOtherNotificationFields() throws {
        let config = Data(#"{"core_enabled":true,"custom":"value"}"#.utf8)
        let data = try ConsoleStore.settingZellijEnabled(false, in: config)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(value["zellij_enabled"] == .bool(false))
        #expect(value["core_enabled"] == .bool(true))
        #expect(value["custom"] == .string("value"))
    }

    @Test func tmuxCoreAndZellijShareFourSessionSlots() async throws {
        let admission = SSHChannelAdmission()
        let tmux = try await admission.acquire(.control)
        let core = try await admission.acquire(.core)
        let zellij = try await admission.acquire(.zellij)
        let ordinary = try await admission.acquire(.ordinarySession)
        let snapshot = await admission.snapshot()
        #expect(snapshot.control == 1 && snapshot.core == 1 && snapshot.zellij == 1)
        #expect(snapshot.ordinarySession == 1 && snapshot.connection == 4)
        await #expect(throws: TransportError.timedOut) {
            _ = try await admission.acquire(.ordinarySession, within: .milliseconds(10))
        }
        await tmux.release()
        await core.release()
        await zellij.release()
        await ordinary.release()
        #expect(await admission.snapshot().connection == 0)
    }
}
