import Foundation
import Testing

@testable import Waycar

@MainActor
@Suite("Agent toolbar layout store")
struct AgentToolbarLayoutStoreTests {
    private let key = AgentToolbarLayoutStore.defaultsKey(for: .phone)

    private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suiteName = "hm-agent-toolbar-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    private static let interrupt = AgentToolbarItem.Content.key(
        AgentToolbarKeyChord(.character("c"), modifiers: .control))
    private static let escape = AgentToolbarItem.Content.key(AgentToolbarKeyChord(.escape))
    private static let shiftTab = AgentToolbarItem.Content.key(AgentToolbarKeyChord(.shiftTab))
    private static let enter = AgentToolbarItem.Content.key(AgentToolbarKeyChord(.enter))
    private static let more = AgentToolbarItem.Content.action(.moreMenu)

    private func contents(_ layout: AgentToolbarLayout) -> [AgentToolbarItem.Content] {
        layout.items.map(\.content)
    }

    private func compactKey(id: UUID = UUID()) -> CustomKey {
        CustomKey(id: id, label: "compact", steps: .text("/compact", pressEnter: true))
    }

    private func availability(
        skills: Bool = true,
        snippetIDs: Set<UUID> = [],
        customKeyIDs: Set<UUID> = []
    ) -> AgentToolbarAvailability {
        AgentToolbarAvailability(
            skillsAvailable: skills, worktreeDetailsAvailable: false,
            snippetIDs: snippetIDs, customKeyIDs: customKeyIDs)
    }

    @Test func anUntouchedToolbarFollowsTheDefaultAndStoresNothing() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = AgentToolbarLayoutStore(defaults: defaults, idiom: .phone)
        #expect(contents(store.layout) == [
            Self.escape, .key(.init(.tab)), Self.shiftTab,
            .key(.init(.up)), .key(.init(.down)), .key(.init(.left)), .key(.init(.right)),
            .key(.init(.backspace)), .key(.init(.shiftEnter)), .action(.paste),
            Self.enter, Self.more, .action(.toolsKeyboard),
        ])
        #expect(!store.isCustomized)

        // Saving the default back (fresh row ids) is not a customization.
        try store.setLayout(AgentToolbarLayout(items: store.layout.items.map { AgentToolbarItem($0.content) }))
        #expect(!store.isCustomized)
        #expect(defaults.data(forKey: key) == nil)
    }

    @Test func aCustomLayoutPersistsAndReloads() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = AgentToolbarLayoutStore(defaults: defaults, idiom: .phone)
        let observer = AgentToolbarLayoutStore(defaults: defaults, idiom: .phone)
        let custom = AgentToolbarLayout(items: [
            AgentToolbarItem(Self.escape), AgentToolbarItem(Self.interrupt),
            AgentToolbarItem(.modifier(.control)),
        ])
        try store.setLayout(custom)

        #expect(store.layout == custom)
        #expect(store.isCustomized)
        #expect(AgentToolbarLayoutStore(defaults: defaults, idiom: .phone).layout == custom)
        let written = String(decoding: try #require(defaults.data(forKey: key)), as: UTF8.self)
        #expect(written.contains(#""layout""#) && !written.contains(#""layouts""#))

        #expect(observer.layout != custom)
        observer.reload()
        #expect(observer.layout == custom)
        #expect(observer.catalogLoadError == nil)
    }

    @Test func phoneAndPadLayoutsAreIndependent() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let phone = AgentToolbarLayoutStore(defaults: defaults, idiom: .phone)
        let pad = AgentToolbarLayoutStore(defaults: defaults, idiom: .pad)
        let phoneLayout = AgentToolbarLayout(items: [AgentToolbarItem(Self.interrupt)])
        let padLayout = AgentToolbarLayout(items: [AgentToolbarItem(Self.escape), AgentToolbarItem(Self.enter)])
        try phone.setLayout(phoneLayout)
        #expect(defaults.data(forKey: AgentToolbarLayoutStore.defaultsKey(for: .pad)) == nil)
        pad.reload()
        #expect(!pad.isCustomized && pad.layout == .default)

        try pad.setLayout(padLayout)
        phone.reload()
        #expect(phone.layout == phoneLayout)
        #expect(AgentToolbarLayoutStore(defaults: defaults, idiom: .pad).layout == padLayout)
        #expect(AgentToolbarLayoutStore(defaults: defaults, idiom: .phone).layout == phoneLayout)
        #expect(defaults.data(forKey: "agent-toolbar-layouts") == nil)
    }

    @Test func theLegacySharedCatalogIsAdoptedOnceThenRemoved() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let legacyKey = AgentToolbarLayoutStore.legacyDefaultsKey
        let legacyLayout = AgentToolbarLayout(items: [AgentToolbarItem(Self.interrupt)])
        let seed = AgentToolbarLayoutStore(defaults: defaults, idiom: .pad)
        try seed.setLayout(legacyLayout)
        let legacyBytes = try #require(defaults.data(forKey: AgentToolbarLayoutStore.defaultsKey(for: .pad)))
        defaults.removeObject(forKey: AgentToolbarLayoutStore.defaultsKey(for: .pad))
        defaults.set(legacyBytes, forKey: legacyKey)

        // Empty device key: the legacy catalog is adopted and the legacy key removed.
        let phone = AgentToolbarLayoutStore(defaults: defaults, idiom: .phone)
        #expect(phone.layout == legacyLayout)
        #expect(defaults.data(forKey: key) == legacyBytes)
        #expect(defaults.data(forKey: legacyKey) == nil)

        // Reset does not bring it back.
        try phone.resetLayout()
        #expect(AgentToolbarLayoutStore(defaults: defaults, idiom: .phone).layout == .default)

        // An existing device catalog is never overwritten; the legacy key still goes.
        let padLayout = AgentToolbarLayout(items: [AgentToolbarItem(Self.escape)])
        try AgentToolbarLayoutStore(defaults: defaults, idiom: .pad).setLayout(padLayout)
        defaults.set(legacyBytes, forKey: legacyKey)
        #expect(AgentToolbarLayoutStore(defaults: defaults, idiom: .pad).layout == padLayout)
        #expect(defaults.data(forKey: legacyKey) == nil)
    }

    @Test func canReadAcceptsOnlyVersionOneJSON() {
        #expect(AgentToolbarLayoutStore.canRead(Data(#"{"version":1,"layout":{"items":[]},"customKeys":[]}"#.utf8)))
        #expect(AgentToolbarLayoutStore.canRead(Data(#"{"version":1}"#.utf8)))
        #expect(!AgentToolbarLayoutStore.canRead(Data(#"{"version":2,"customKeys":[]}"#.utf8)))
        #expect(!AgentToolbarLayoutStore.canRead(Data(#"{"layout":{}}"#.utf8)))
        #expect(!AgentToolbarLayoutStore.canRead(Data("not json".utf8)))
    }

    /// A catalog written by a newer build (or an older shape): an action and
    /// an item kind this build does not know are dropped one by one; the rest
    /// loads and the next write no longer carries them.
    @Test func unknownActionsAndItemsDropAndTheRestLoads() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let escapeID = UUID(), interruptID = UUID(), enterID = UUID()
        let json = """
            {"version":1,"layout":{"items":[
              {"id":"\(escapeID)","content":{"kind":"key","chord":{"key":"escape","mods":[]}}},
              {"id":"\(UUID())","content":{"kind":"action","action":"teleport"}},
              {"id":"\(UUID())","content":{"kind":"action","action":"send"}},
              {"id":"\(UUID())","content":{"kind":"hologram"}},
              {"id":"\(interruptID)","content":{"kind":"key","chord":{"key":"char","char":"c","mods":["control"]}}},
              {"id":"\(enterID)","content":{"kind":"key","chord":{"key":"enter","mods":[]}}}
            ]},"customKeys":[]}
            """
        defaults.set(Data(json.utf8), forKey: key)
        let store = AgentToolbarLayoutStore(defaults: defaults, idiom: .phone)
        #expect(store.catalogLoadError == nil)
        #expect(store.layout.items.map(\.id) == [escapeID, interruptID, enterID])

        try store.upsertCustomKey(compactKey(), addToBar: false)
        let written = String(decoding: try #require(defaults.data(forKey: key)), as: UTF8.self)
        #expect(!written.contains("teleport") && !written.contains("hologram") && !written.contains(#""send""#))
        #expect(AgentToolbarLayoutStore(defaults: defaults, idiom: .phone).layout.items.map(\.id) == [escapeID, interruptID, enterID])
    }

    @Test func unreadableCatalogShowsDefaultsRefusesWritesAndKeepsItsBytes() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        for json in ["not json", #"{"version":2,"layout":{}}"#, #"{"version":1,"customKeys":{}}"#] {
            let corrupt = Data(json.utf8)
            defaults.set(corrupt, forKey: key)
            let store = AgentToolbarLayoutStore(defaults: defaults, idiom: .phone)
            #expect(store.catalogLoadError == .catalogUnreadable)
            #expect(store.layout == .default)
            #expect(throws: AgentToolbarLayoutStoreError.catalogUnreadable) {
                try store.setLayout(AgentToolbarLayout(items: [AgentToolbarItem(Self.escape)]))
            }
            #expect(throws: AgentToolbarLayoutStoreError.catalogUnreadable) { try store.resetLayout() }
            #expect(throws: AgentToolbarLayoutStoreError.catalogUnreadable) {
                try store.upsertCustomKey(compactKey(), addToBar: true)
            }
            #expect(throws: AgentToolbarLayoutStoreError.catalogUnreadable) {
                try store.deleteCustomKey(UUID())
            }
            #expect(throws: AgentToolbarLayoutStoreError.catalogUnreadable) {
                try store.setItemSpacing(6)
            }
            #expect(defaults.data(forKey: key) == corrupt)
        }
    }

    @Test func resetUnreadableCatalogDiscardsOnlyAnUnreadableOne() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let readable = AgentToolbarLayoutStore(defaults: defaults, idiom: .phone)
        try readable.upsertCustomKey(compactKey(), addToBar: true)
        let before = defaults.data(forKey: key)
        readable.resetUnreadableCatalog()
        #expect(defaults.data(forKey: key) == before && readable.customKeys.count == 1)

        defaults.set(Data("not json".utf8), forKey: key)
        let store = AgentToolbarLayoutStore(defaults: defaults, idiom: .phone)
        store.resetUnreadableCatalog()
        #expect(store.catalogLoadError == nil && store.customKeys.isEmpty)
        #expect(defaults.data(forKey: key) == nil)
        try store.upsertCustomKey(compactKey(), addToBar: true)
        #expect(AgentToolbarLayoutStore(defaults: defaults, idiom: .phone).isCustomized)
    }

    @Test func resetRestoresTheDefaultAndKeepsCustomKeys() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = AgentToolbarLayoutStore(defaults: defaults, idiom: .phone)
        try store.setLayout(AgentToolbarLayout(items: [AgentToolbarItem(Self.interrupt)]))
        try store.resetLayout()
        #expect(!store.isCustomized)
        #expect(defaults.data(forKey: key) == nil)

        let compact = compactKey()
        try store.upsertCustomKey(compact, addToBar: true)
        try store.resetLayout()
        #expect(!store.isCustomized)
        #expect(store.customKeys.map(\.id) == [compact.id])
        let reloaded = AgentToolbarLayoutStore(defaults: defaults, idiom: .phone)
        #expect(reloaded.customKeys.map(\.id) == [compact.id])
        #expect(!reloaded.isOnBar(compact.id))
    }

    @Test func itemSpacingRoundTripsAndResetsWithTheLayout() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = AgentToolbarLayoutStore(defaults: defaults, idiom: .phone)
        #expect(store.itemSpacing == AgentToolbarCatalog.defaultItemSpacing)
        try store.setItemSpacing(6)
        #expect(store.isCustomized)
        let json = try #require(defaults.data(forKey: key))
        #expect(String(decoding: json, as: UTF8.self).contains(#""itemSpacing":6"#))
        #expect(AgentToolbarLayoutStore(defaults: defaults, idiom: .phone).itemSpacing == 6)

        try store.resetLayout()
        #expect(store.itemSpacing == AgentToolbarCatalog.defaultItemSpacing)
        #expect(!store.isCustomized)
        #expect(defaults.data(forKey: key) == nil)
    }

    @Test func itemSpacingIsClampedAndSnappedToTheStep() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = AgentToolbarLayoutStore(defaults: defaults, idiom: .phone)
        let cases: [(Double, Double)] = [(-5, 1), (0, 1), (1, 1), (2, 2), (7.2, 7), (24, 24), (100, 24), (.nan, 12)]
        for (input, expected) in cases {
            try store.setItemSpacing(input)
            #expect(store.itemSpacing == expected, "\(input)")
        }
        defaults.set(Data(#"{"version":1,"customKeys":[],"itemSpacing":99}"#.utf8), forKey: key)
        #expect(AgentToolbarLayoutStore(defaults: defaults, idiom: .phone).itemSpacing == 24)
    }

    @Test func missingOrUnreadableItemSpacingFallsBackToTheDefault() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        for json in [#"{"version":1,"customKeys":[]}"#, #"{"version":1,"customKeys":[],"itemSpacing":"wide"}"#] {
            defaults.set(Data(json.utf8), forKey: key)
            let store = AgentToolbarLayoutStore(defaults: defaults, idiom: .phone)
            #expect(store.catalogLoadError == nil)
            #expect(store.itemSpacing == AgentToolbarCatalog.defaultItemSpacing)
            #expect(!store.isCustomized)
        }
    }

    @Test func addToBarAppendsOnceAndDeletingRemovesTheReference() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = AgentToolbarLayoutStore(defaults: defaults, idiom: .phone)
        let compact = compactKey()
        let content = AgentToolbarItem.Content.customKey(compact.id)
        try store.upsertCustomKey(compact, addToBar: true)
        #expect(store.isOnBar(compact.id))
        #expect(store.layout.items.last?.content == content)

        // Moving it, then saving it again, keeps its place.
        var moved = store.layout
        moved.items.insert(moved.items.removeLast(), at: 0)
        try store.setLayout(moved)
        var renamed = compact
        renamed.label = "  squash  "
        try store.upsertCustomKey(renamed, addToBar: true)
        #expect(store.customKeys.map(\.label) == ["squash"])
        #expect(store.layout.items.first?.content == content)
        #expect(store.layout.items.filter { $0.content == content }.count == 1)

        try store.upsertCustomKey(renamed, addToBar: false)
        #expect(!store.isOnBar(compact.id))
        try store.upsertCustomKey(renamed, addToBar: true)

        try store.deleteCustomKey(compact.id)
        #expect(store.customKeys.isEmpty)
        #expect(!store.layout.contains(content))
        #expect(!AgentToolbarLayoutStore(defaults: defaults, idiom: .phone).layout.contains(content))
    }

    @Test func aNewKeyLeftOffTheBarDoesNotCustomizeIt() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = AgentToolbarLayoutStore(defaults: defaults, idiom: .phone)
        let compact = compactKey()
        try store.upsertCustomKey(compact, addToBar: false)
        #expect(!store.isCustomized && !store.isOnBar(compact.id))
        try store.deleteCustomKey(compact.id)
        #expect(defaults.data(forKey: key) == nil)
    }

    @Test func invalidCustomKeysAreRejectedWithoutWriting() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = AgentToolbarLayoutStore(defaults: defaults, idiom: .phone)
        #expect(throws: CustomKeyValidationError.labelTooLong(limit: 12)) {
            try store.upsertCustomKey(
                CustomKey(label: "thirteen char", steps: .keys([.init(.escape)])), addToBar: true)
        }
        #expect(throws: CustomKeyValidationError.noSteps) {
            try store.upsertCustomKey(CustomKey(label: "none", steps: .keys([])), addToBar: true)
        }
        #expect(throws: CustomKeyValidationError.tooManySteps(limit: 8)) {
            try store.upsertCustomKey(
                CustomKey(label: "many", steps: .keys(Array(repeating: .init(.up), count: 9))), addToBar: true)
        }
        #expect(throws: CustomKeyValidationError.unsupportedControlCharacters) {
            try store.upsertCustomKey(
                CustomKey(label: "esc", steps: .text("\u{1B}[A", pressEnter: false)), addToBar: true)
        }
        #expect(defaults.data(forKey: key) == nil && store.customKeys.isEmpty)

        // A carriage return in the text is normalized, so only the explicit
        // Enter toggle can submit.
        let id = UUID()
        try store.upsertCustomKey(
            CustomKey(id: id, label: "", steps: .text("a\r\nb", pressEnter: false)), addToBar: false)
        #expect(store.customKey(id)?.steps == .text("a\nb", pressEnter: false))
        #expect(store.customKey(id)?.submits == false)
    }

    @Test func duplicatesAreRejectedOnWriteAndDroppedOnRead() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = AgentToolbarLayoutStore(defaults: defaults, idiom: .phone)
        // Identity is what the item refers to, not its row id.
        #expect(throws: AgentToolbarLayoutStoreError.duplicateItem) {
            try store.setLayout(AgentToolbarLayout(items: [
                AgentToolbarItem(Self.interrupt), AgentToolbarItem(Self.interrupt),
            ]))
        }
        #expect(defaults.data(forKey: key) == nil)

        let first = UUID()
        let chord = #"{"kind":"key","chord":{"key":"escape","mods":[]}}"#
        let json = """
            {"version":1,"layout":{"items":[
              {"id":"\(first)","content":\(chord)},{"id":"\(UUID())","content":\(chord)}
            ]}}
            """
        defaults.set(Data(json.utf8), forKey: key)
        #expect(AgentToolbarLayoutStore(defaults: defaults, idiom: .phone).layout.items.map(\.id) == [first])
    }

    @Test func theResolvedLayoutHidesWhatThisAgentCannotRun() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = AgentToolbarLayoutStore(defaults: defaults, idiom: .phone)
        let snippetID = UUID(), goneSnippetID = UUID()
        let compact = compactKey()
        try store.upsertCustomKey(compact, addToBar: false)
        try store.setLayout(AgentToolbarLayout(items: [
            AgentToolbarItem(.action(.skills)), AgentToolbarItem(.snippet(snippetID)),
            AgentToolbarItem(.snippet(goneSnippetID)), AgentToolbarItem(.customKey(compact.id)),
            AgentToolbarItem(.action(.worktreeDetails)), AgentToolbarItem(.modifier(.control)),
            AgentToolbarItem(Self.more),
        ]))

        let noSkills = availability(skills: false, snippetIDs: [snippetID])
        #expect(contents(store.resolvedLayout(availability: noSkills)) == [
            .snippet(snippetID), .modifier(.control), Self.more,
        ])

        let everything = availability(snippetIDs: [snippetID], customKeyIDs: [compact.id])
        #expect(contents(store.resolvedLayout(availability: everything)) == [
            .action(.skills), .snippet(snippetID), .customKey(compact.id), .modifier(.control), Self.more,
        ])
    }
}
