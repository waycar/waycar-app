import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Waycar

/// OpenCode 2 sessions as chat-first Agents on the shared server-chat layer
/// (`docs/design/opencode-backend.md`), as Codex threads are.
@MainActor
@Suite("OpenCode Console and Chat")
struct OpenCodeConsoleChatTests {
    static func session(_ id: String, status: AgentStatus) -> AgentInfo {
        AgentInfo(
            agentStatus: status, focused: false, paneID: "opencode:\(id)", revision: 0,
            tabID: "opencode:\(id)", terminalID: "opencode:\(id)", workspaceID: "opencode:cwd:/work/app",
            agent: "opencode",
            agentSession: AgentSessionInfo(agent: "opencode", kind: .id, source: "opencode", value: id),
            cwd: "/work/app", name: "Task \(id)")
    }

    nonisolated static let running = OpenCodePresence(
        path: "/home/me/.opencode/bin/opencode", version: "2.2.7", serverURL: "http://127.0.0.1:49374")

    static func fixture(sessions: [AgentInfo], host: Host = .fixture()) -> (ConsoleStore, Host, ScriptedTransport) {
        let transport = ScriptedTransport(snapshot: .fixture(
            agents: sessions, workspaces: [.fixture(workspaceID: "opencode:cwd:/work/app", label: "app")]))
        let defaults = UserDefaults(suiteName: "opencode-console-\(UUID())") ?? .standard
        let store = ConsoleStore(
            pins: PinnedAgentsStore(defaults: defaults),
            unread: UnreadAgentsStore(defaults: defaults),
            closedSessions: ClosedSessionsStore(),
            chatMode: ChatModeStore(defaults: defaults),
            rowLayouts: AgentRowLayoutStore(defaults: defaults),
            backendPreferences: HostBackendPreferences(defaults: defaults),
            makeSession: { _, backend, subscriptions in
                // Only OpenCode's projection owns the scripted transport.
                let owner = backend == .opencode ? transport : ScriptedTransport()
                return EventsSession(subscriptions: subscriptions, connect: { owner }, keepalive: nil)
            },
            detectBackends: { _ in
                HostBackendPresence(herdr: false, tmuxVersion: nil, ultimate: [], opencode: Self.running)
            })
        return (store, host, transport)
    }

    @Test func projectsSessionsAsChatAgentsAndHonoursVisibility() async throws {
        let statuses: [AgentStatus] = [.working, .blocked, .done, .idle]
        let (store, host, _) = Self.fixture(sessions: statuses.enumerated().map {
            Self.session("ses_\($0.offset)", status: $0.element)
        })
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitUntil { store.verifiedAgents.count == statuses.count }
        for (index, status) in statuses.enumerated() {
            let row = try #require(store.agents.first { $0.agent.paneID == "opencode:ses_\(index)" })
            #expect(row.agent.status == status)
            #expect(row.backend == .opencode && !row.canShowTerminal)
            #expect(store.isChatMode(row))
            #expect(AgentCardPresentation(agent: row, layout: .waycarDefault).caption == "opencode · \(host.displayName)")
            #expect(AgentRowRenderer.value(for: .runtime, agent: row) == "OpenCode")
        }
        #expect(store.backendPreferences.showsServerChat(.opencode, for: host.id))
        let server = ServerChatBackend.opencode
        #expect(server.sessionDescription + "s" == "OpenCode sessions" && server.serverName == "OpenCode server")
        #expect(server.visibilityKey == "opencode" && server.sessionID(paneID: "opencode:ses_1") == "ses_1")
        #expect(HostBackend.opencode.serverChat == .opencode && !HostBackend.opencode.hasTerminal)
        let pane = server.linkedPaneRequest(sessionID: "ses_1", name: "n", launchID: nil, mayHaveStarted: false)
        #expect(pane.kind == "opencode" && pane.arguments == ["--session", "ses_1"] && !pane.joinsCodexServer)
        store.setShowsServerChat(false, .opencode, for: host.id)
        try await waitUntil { store.agents.isEmpty }
        store.backendPreferences.reload()
        #expect(!store.backendPreferences.showsServerChat(.opencode, for: host.id))
        #expect(store.backendPreferences.showsServerChat(.codex, for: host.id))
        store.setShowsServerChat(true, .opencode, for: host.id)
        try await waitUntil { store.verifiedAgents.count == statuses.count }
    }

    @Test func structuredAnswersStopAndOpeningADoneSessionReachTheTransport() async throws {
        let (store, host, transport) = Self.fixture(sessions: [
            Self.session("ses_b", status: .blocked), Self.session("ses_d", status: .done)])
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitUntil { store.verifiedAgents.count == 2 }
        let row = try #require(store.agents.first { $0.agent.paneID == "opencode:ses_b" })
        let request = AgentPendingRequest(id: "per_1", kind: .command(command: "swift test", cwd: "/work/app", reason: nil))
        await transport.setPendingRequests([request])
        let transcript = store.makeChatTranscriptStore(for: row)
        transcript.start()
        defer { transcript.stop() }
        try await waitUntil { transcript.requests == [request] && transcript.canAnswerRequests }
        await transcript.answer(request, with: .allow)
        let answer = try #require(await transport.requestAnswers.first)
        #expect(answer.target == "opencode:ses_b" && answer.id == "per_1" && answer.answer == .allow)
        try await store.abortAgentRun("opencode:ses_b", on: host.id)
        #expect(await transport.abortedRuns == ["opencode:ses_b"])
        // Opening a Done session's Chat focuses it: OpenCode marks it viewed.
        try await store.focusAgent("opencode:ses_d", on: host.id)
        #expect(await transport.agentFocuses.map(\.target) == ["opencode:ses_d"])
    }

    @Test func pushOpensOpenCodeChatAndGlanceSurfacesIncludeSessions() async throws {
        let (store, host, _) = Self.fixture(sessions: [Self.session("ses_e3358202bffezzzzzzzzzzzzzz", status: .blocked)])
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitUntil { store.verifiedAgents.count == 1 }
        let row = try #require(store.agents.first)
        // Host Tools 2.5.0 posts OpenCode pushes as `opencode:<sessionID>`.
        let router = AgentNotificationRouter()
        router.open(.init(hostID: host.id, paneID: "opencode:ses_e3358202bffezzzzzzzzzzzzzz"))
        #expect(router.path.isEmpty && router.pendingTarget != nil)
        router.agentsDidChange(store.agents)
        #expect(router.path == [row.id])
        #expect(router.backend(of: row.id) == .opencode)
        let desire = try #require(AgentActivityContentBuilder.desire(from: store.agents, hostName: host.displayName))
        #expect(desire.counts.blocked == 1 && desire.agents.first?.paneID == "opencode:ses_e3358202bffezzzzzzzzzzzzzz")
        let watch = WatchStateBuilder.state(
            from: WatchStateSource(
                agents: store.verifiedAgents, hosts: [host], statuses: store.hostStatuses,
                awaitingSnapshot: [], chatModeAgents: [row.id], voiceTranscription: false),
            stamps: WatchStatusStamps(), now: .now)
        #expect(watch.rows.first?.id.paneID == "opencode:ses_e3358202bffezzzzzzzzzzzzzz")
        #expect(watch.rows.first?.isChatMode == true)
    }

    /// The real transport over a fake OpenCode 2 server, in the Console and
    /// in the Chat it opens: the sessions list, and a pending shell
    /// permission on Chat Mode's Needs your OK card.
    @Test func theConsoleAndChatRenderAnOpenCodeSessionAndItsApproval() async throws {
        let hosted = try await Self.hostedConsole()
        defer { hosted.end() }
        try await waitUntil("the Console should list the OpenCode sessions") {
            hosted.root.layoutIfNeeded()
            return Self.accessibilityLabels(in: hosted.root).contains { $0.contains("Fix flaky tests") }
        }
        hosted.openChat()
        try await waitUntil("the Chat should show the approval") {
            hosted.root.layoutIfNeeded()
            let labels = Self.accessibilityLabels(in: hosted.root)
            return labels.contains { $0.contains("Needs your OK") } && labels.contains { $0.contains("swift test") }
        }
        let labels = Self.accessibilityLabels(in: hosted.root)
        #expect(labels.contains { $0.contains("Run the tests and fix what fails.") }, "\(labels)")
    }

    /// A Console over one demo Host whose only projection is OpenCode's real
    /// transport, in a key window.
    struct Hosted {
        let window: UIWindow
        let root: UIView
        let transport: OpenCodeTransport
        let projection: HostConsoleProjection
        let console: ConsoleStore
        let openChat: @MainActor () -> Void

        @MainActor func end() {
            projection.end()
            console.projections.removeAll()
            window.isHidden = true
            window.rootViewController = nil
            Task { try? await transport.close() }
        }
    }

    static func hostedConsole() async throws -> Hosted {
        let composition = DemoScreenshotComposition.make()
        let host = try #require(composition.hosts.hosts.first)
        let sessions = [
            OpenCodeTransportTests.session("ses_review", dir: "/home/me/waycar", title: "Fix flaky tests"),
            OpenCodeTransportTests.session("ses_docs", dir: "/home/me/waycar", title: "Update the help docs",
                                           idle: 1_794_434_990_000, viewed: 1_794_434_900_000),
            OpenCodeTransportTests.session("ses_parse", dir: "/home/me/parser", title: "Refactor the parser",
                                           idle: 1_794_434_900_000, viewed: 1_794_434_990_000),
        ]
        let permission: JSONValue = .object([
            "id": .string("per_1"), "sessionID": .string("ses_review"), "action": .string("shell"),
            "resources": .array([.string("swift test --filter ParserTests")])])
        let history: JSONValue = .object(["data": .array([
            .object(["id": .string("msg_2"), "type": .string("assistant"), "time": .object(["created": .number(1_794_434_995_000)]),
                     "content": .array([.object(["type": .string("text"),
                                                 "text": .string("I'll run the parser suite first.")])])]),
            .object(["id": .string("msg_1"), "type": .string("user"), "time": .object(["created": .number(1_794_434_994_000)]),
                     "text": .string("Run the tests and fix what fails.")]),
        ]), "cursor": .object(["next": .null])])
        let (transport, _, _) = try await OpenCodeTransportTests.open(OpenCodeTransportTests.handler(
            sessions: { sessions }, active: { ["ses_review"] }, permissions: ["ses_review": [permission]],
            extra: { request in
                switch request.route {
                case "/api/info": .json(.object(["version": .string("2.2.7")]))
                case "/api/session/ses_review/message": .json(history)
                default: nil
                }
            }))
        let session = EventsSession(subscriptions: [], connect: { transport }, keepalive: nil)
        let console = ConsoleStore()
        let projection = HostConsoleProjection(host: host, session: session, backend: .opencode,
                                              snapshotRetryDelay: .milliseconds(10), onChange: { console.rebuild() })
        console.projections[ConsoleScope(hostID: host.id, backend: .opencode)] = projection
        projection.start(isActive: true)
        let id = ConsoleAgent.ID(hostID: host.id, paneID: "opencode:ses_review")
        try await waitUntil("the session should be listed") { console.listedAgent(id) != nil }
        composition.notificationRouter.path = []
        let view = ConsoleView(
            hosts: composition.hosts, console: console,
            terminal: TerminalSettings(
                themes: composition.terminalThemes, zoom: composition.terminalZoom,
                fonts: composition.terminalFonts, snippets: composition.snippets, toolbars: composition.toolbars),
            appearance: composition.appearance, pushRegistration: composition.pushRegistration,
            notificationPreferences: composition.notificationPreferences, relaySettings: composition.relaySettings,
            agentSummaries: composition.agentSummaries, notificationRouter: composition.notificationRouter,
            bannerStore: composition.bannerStore, liveActivities: composition.liveActivities,
            activity: composition.activity, aiUsage: composition.aiUsage)
        let controller = UIHostingController(rootView: view)
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 440, height: 956), rootViewController: controller)
        try await DisplayTickMonitor.shared.waitForTicks(20)
        let root = try #require(controller.view)
        let router = composition.notificationRouter
        return Hosted(window: window, root: root, transport: transport, projection: projection,
                      console: console, openChat: { router.path = [id] })
    }

    static func accessibilityLabels(in root: UIView) -> [String] {
        var visited = Set<ObjectIdentifier>()
        var labels: [String] = []
        func visit(_ node: NSObject) {
            guard visited.insert(ObjectIdentifier(node)).inserted else { return }
            if let label = node.accessibilityLabel { labels.append(label) }
            for case let child as NSObject in node.accessibilityElements ?? [] { visit(child) }
            let count = node.accessibilityElementCount()
            if count > 0, count != NSNotFound {
                for index in 0..<count {
                    if let child = node.accessibilityElement(at: index) as? NSObject { visit(child) }
                }
            }
            if let view = node as? UIView { view.subviews.forEach { visit($0) } }
        }
        visit(root)
        return labels
    }
}
