import Foundation
import Testing

@testable import Waycar

/// A restarted tmux server hands its pane ids out again (a new server starts
/// at `%0`): a Chat Marker left for the old server's `%0` must not make the
/// new server's same-kind Agent in `%0` a chat, nor follow it.
@MainActor
@Suite("tmux Chat Marker in a recycled pane", .timeLimit(.minutes(1)))
struct TmuxChatMarkerRecycleTests {
    private static let oldServer = "1790979932.4242"
    private static let newServer = "1790990000.5151"

    /// The tmux snapshot of one session `$0` whose pane `%0` runs claude in
    /// `session`, as the transport builds it on the server `server`.
    private static func snapshot(server: String, session: String) -> SessionSnapshot {
        TmuxInventory.snapshot(
            sessions: [
                TmuxSessionRecord(
                    id: "$0", name: "main", group: "", grouped: false, attached: 0,
                    path: "/work/w1")
            ],
            windows: [
                TmuxWindowRecord(
                    id: "@0", sessionID: "$0", index: 0, name: "claude", active: true,
                    zoomed: false)
            ],
            panes: [
                TmuxPaneRecord(
                    id: "%0", sessionID: "$0", windowID: "@0", active: true,
                    currentCommand: "2.1.286", waycarStatus: "idle", waycarAgent: "claude",
                    currentPath: "/work/w1", waycarSession: session)
            ],
            kinds: ["%0": "claude"], version: "3.7c", server: server)
    }

    @Test func aMarkerFromTheOldServerDoesNotApplyToTheRecycledPane() async throws {
        let suiteName = "hm-tmux-chat-recycle-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let host = Host.fixture()
        let id = ConsoleAgent.ID(hostID: host.id, paneID: "tmux:%0")

        let before = Self.snapshot(server: Self.oldServer, session: "s-1")
        let agent = try #require(before.agents.first)
        let stale = ChatModeMarker(
            paneID: "tmux:%0", terminalID: agent.terminalID, kind: "claude", cwd: "/work/w1",
            session: ChatModeMarker.Session(kind: "id", value: "s-1"),
            launchedAt: Date(timeIntervalSince1970: 1_790_000_000))
        #expect(stale.terminalID == "tmux:%0@\(Self.oldServer)")

        let transport = ScriptedTransport(snapshot: before)
        await transport.setChatModeMarkers([stale])
        let store = ConsoleStore(
            snapshotRetryDelay: .milliseconds(10),
            pins: PinnedAgentsStore(defaults: defaults),
            unread: UnreadAgentsStore(defaults: defaults),
            chatMode: ChatModeStore(defaults: defaults)
        ) { _, _, subscriptions in
            EventsSession(subscriptions: subscriptions, connect: { transport }, keepalive: nil)
        }
        store.setHosts([host])
        defer { store.setHosts([]) }
        await store.resume()
        try await waitUntil("the old server's chat should be shown as a chat") {
            !store.hostsAwaitingSnapshot.contains(host.id)
                && store.chatMode.marker(for: id) == stale
                && store.agents.first { $0.id == id }.map { store.isChatMode($0) } == true
        }

        // The gap: the server restarted and its `%0` runs another claude.
        await store.suspend()
        try await waitUntil("suspending should leave the rows awaiting a snapshot") {
            store.hostsAwaitingSnapshot.contains(host.id)
        }
        await transport.setSnapshot(Self.snapshot(server: Self.newServer, session: "s-2"))
        let readsBefore = await transport.chatModeMarkerReadCount
        await store.resume()
        try await waitUntil("the new server's rows should be verified and the markers read") {
            let reads = await transport.chatModeMarkerReadCount
            return reads > readsBefore && !store.hostsAwaitingSnapshot.contains(host.id)
                && store.agents.first { $0.id == id }?.agent.agentSession?.value == "s-2"
        }
        try await Task.sleep(for: .milliseconds(100))

        let row = try #require(store.agents.first { $0.id == id })
        #expect(row.agent.terminalID == "tmux:%0@\(Self.newServer)")
        #expect(!store.isChatMode(row))
        #expect(await transport.chatModeMarkerWrites.isEmpty)
    }
}
