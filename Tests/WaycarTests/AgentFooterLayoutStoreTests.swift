import Foundation
import Testing

@testable import Waycar

@MainActor
@Suite("Agent footer layout store")
struct AgentFooterLayoutStoreTests {
    private let key = AgentFooterLayoutStore.defaultsKey(for: .phone)

    private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suiteName = "hm-agent-footer-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    private static let custom = AgentFooterLayout(
        isEnabled: true, lines: [[.row(.agent)], [.branch, .model]], textSize: .small)

    @Test func eachDeviceTypeHasItsOwnKey() {
        #expect(AgentFooterLayoutStore.defaultsKey(for: .phone)
            != AgentFooterLayoutStore.defaultsKey(for: .pad))
    }

    @Test func anEmptyStoreShowsTheDefault() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = AgentFooterLayoutStore(defaults: defaults, idiom: .phone)
        #expect(store.layout == .default)
        #expect(!store.isCustomized)
    }

    @Test func aSavedLayoutPersistsAndTheDefaultRemovesIt() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = AgentFooterLayoutStore(defaults: defaults, idiom: .phone)
        try store.setLayout(Self.custom)
        #expect(store.isCustomized)
        #expect(AgentFooterLayoutStore(defaults: defaults, idiom: .phone).layout == Self.custom)
        #expect(AgentFooterLayoutStore(defaults: defaults, idiom: .pad).layout == .default)

        try store.setLayout(.default)
        #expect(defaults.data(forKey: key) == nil)
        #expect(!store.isCustomized)
    }

    @Test func anUnreadableCatalogRefusesWritesUntilReset() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let bytes = Data(#"{"version":99,"layout":{}}"#.utf8)
        defaults.set(bytes, forKey: key)
        let store = AgentFooterLayoutStore(defaults: defaults, idiom: .phone)
        #expect(store.isCatalogUnreadable)
        #expect(store.layout == .default)
        #expect(throws: AgentFooterLayoutStoreError.catalogUnreadable) { try store.setLayout(Self.custom) }
        #expect(defaults.data(forKey: key) == bytes)

        store.resetUnreadableCatalog()
        #expect(!store.isCatalogUnreadable)
        try store.setLayout(Self.custom)
        #expect(store.layout == Self.custom)
    }

    @Test func canReadRejectsAnUnknownVersion() {
        let layout = #"{"isEnabled":true,"lines":[["agent","directory"]],"textSize":"medium"}"#
        #expect(AgentFooterLayoutStore.canRead(Data(#"{"version":1,"layout":\#(layout)}"#.utf8)))
        #expect(!AgentFooterLayoutStore.canRead(Data(#"{"version":2,"layout":\#(layout)}"#.utf8)))
        #expect(!AgentFooterLayoutStore.canRead(Data("nope".utf8)))
    }

    @Test func reloadPicksUpAnotherDevicesLayout() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = AgentFooterLayoutStore(defaults: defaults, idiom: .phone)
        try AgentFooterLayoutStore(defaults: defaults, idiom: .phone).setLayout(Self.custom)
        store.reload()
        #expect(store.layout == Self.custom)
    }
}
