import Foundation
import Testing

@testable import Waycar

@MainActor
struct QuickActionTests {
    @Test func shortcutTypeMapsOnlyNewChat() {
        #expect(QuickAction(shortcutType: QuickAction.newChatType) == .newChat)
        #expect(QuickAction(shortcutType: "com.otreva.waycar.new-agent") == nil)
        #expect(QuickAction(shortcutType: "") == nil)
    }

    @Test func centerHandsOutThePendingActionOnce() {
        let center = QuickActionCenter()
        #expect(center.consume() == nil)

        center.post(.newChat)
        #expect(center.pending == .newChat)
        #expect(center.consume() == .newChat)
        #expect(center.pending == nil)
        #expect(center.consume() == nil)
    }

    @Test func chatInputFocusIsOneShotPerAgent() {
        let store = makeStore()
        let host = Host.fixture()
        let first = ConsoleAgent.ID(hostID: host.id, paneID: "w1:p1")
        let second = ConsoleAgent.ID(hostID: host.id, paneID: "w1:p2")

        #expect(!store.consumeChatInputFocus(first))
        store.requestChatInputFocus(first)
        #expect(!store.consumeChatInputFocus(second))
        #expect(store.consumeChatInputFocus(first))
        #expect(!store.consumeChatInputFocus(first))

        // A newer request replaces the older one.
        store.requestChatInputFocus(first)
        store.requestChatInputFocus(second)
        #expect(!store.consumeChatInputFocus(first))
        #expect(store.consumeChatInputFocus(second))
    }

    @Test func chatInputFocusExpiresAfterItsLifetime() {
        let store = makeStore()
        var clock = Date(timeIntervalSinceReferenceDate: 0)
        store.now = { clock }
        let id = ConsoleAgent.ID(hostID: Host.fixture().id, paneID: "w1:p1")
        let lifetime = ConsoleStore.chatInputFocusLifetime

        store.requestChatInputFocus(id)
        clock += lifetime
        #expect(store.consumeChatInputFocus(id))

        store.requestChatInputFocus(id)
        clock += lifetime + 0.001
        #expect(!store.consumeChatInputFocus(id))
        // The expired request is gone, not left for a later visit: rewound,
        // a lingering request would read as fresh.
        clock -= lifetime + 0.001
        #expect(!store.consumeChatInputFocus(id))
    }

    private func makeStore() -> ConsoleStore {
        ConsoleStore(snapshotRetryDelay: .milliseconds(10)) { _, _, subscriptions in
            EventsSession(
                subscriptions: subscriptions,
                connect: { throw TransportError.sshUnreachable(detail: "unscripted host") },
                keepalive: nil)
        }
    }
}
