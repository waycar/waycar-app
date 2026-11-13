import Foundation
import Testing

@testable import Waycar

@MainActor
@Suite("What's New")
struct WhatsNewStoreTests {
    private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suiteName = "waycar-whats-new-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    /// A `WhatsNew.json` payload with one item per text, in the given order.
    /// Carries an unknown field so every test also exercises lenient decoding.
    private func notes(_ builds: [(build: Int, texts: [String])]) throws -> Data {
        let payload: [String: Any] = [
            "generator": "test",
            "builds": builds.map { entry in
                [
                    "build": entry.build,
                    "date": "2026-09-26",
                    "items": entry.texts.map { ["symbol": "sparkles", "text": $0] },
                ] as [String: Any]
            },
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    @Test func freshInstallShowsNothingAndTheNextBuildShowsOnlyItsNotes() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let history = try notes([(121, ["Dictation."]), (120, ["Sync."])])

        let fresh = WhatsNewStore(notes: history, currentBuild: 121, isExistingInstall: false, defaults: defaults)
        #expect(fresh.pending == nil)

        let next = try notes([(122, ["Default Shell."]), (121, ["Dictation."]), (120, ["Sync."])])
        let upgraded = WhatsNewStore(notes: next, currentBuild: 122, isExistingInstall: true, defaults: defaults)
        #expect(upgraded.pending?.map(\.build) == [122])
        #expect(upgraded.pending?.first?.items.map(\.text) == ["Default Shell."])
    }

    @Test func skippedBuildsAreAllShownNewestFirst() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        defaults.set(120, forKey: WhatsNewStore.lastSeenBuildKey)
        // Out of order on purpose: the store owns the ordering.
        let data = try notes([(121, ["A."]), (123, ["C."]), (122, ["B."]), (120, ["Old."])])

        let store = WhatsNewStore(notes: data, currentBuild: 123, isExistingInstall: true, defaults: defaults)

        #expect(store.pending?.map(\.build) == [123, 122, 121])
    }

    @Test func buildsAboveTheRunningOneAndEmptyBuildsAreExcluded() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        defaults.set(120, forKey: WhatsNewStore.lastSeenBuildKey)
        let data = try notes([(124, ["Future."]), (123, []), (122, ["B."]), (121, [])])

        let store = WhatsNewStore(notes: data, currentBuild: 123, isExistingInstall: true, defaults: defaults)

        #expect(store.pending?.map(\.build) == [122])
    }

    @Test func aBuildWithoutNotesStillAdvancesTheMarker() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        defaults.set(120, forKey: WhatsNewStore.lastSeenBuildKey)

        let quiet = WhatsNewStore(notes: try notes([(121, [])]), currentBuild: 121, isExistingInstall: true, defaults: defaults)
        #expect(quiet.pending == nil)

        // Build 121's notes changed after the fact; they must not resurface.
        let data = try notes([(122, ["B."]), (121, ["Late edit."])])
        let next = WhatsNewStore(notes: data, currentBuild: 122, isExistingInstall: true, defaults: defaults)
        #expect(next.pending?.map(\.build) == [122])
    }

    @Test func acknowledgingPersistsAcrossLaunches() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        defaults.set(120, forKey: WhatsNewStore.lastSeenBuildKey)
        let data = try notes([(122, ["B."]), (121, ["A."])])

        let store = WhatsNewStore(notes: data, currentBuild: 122, isExistingInstall: true, defaults: defaults)
        #expect(store.pending?.map(\.build) == [122, 121])
        store.acknowledge()
        #expect(store.pending == nil)

        let relaunch = WhatsNewStore(notes: data, currentBuild: 122, isExistingInstall: true, defaults: defaults)
        #expect(relaunch.pending == nil)
    }

    @Test func acknowledgementIsAppWideButEachWindowWaitsForItsOwnDismissal() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        defaults.set(120, forKey: WhatsNewStore.lastSeenBuildKey)
        let store = WhatsNewStore(
            notes: try notes([(121, ["New notes."])]), currentBuild: 121,
            isExistingInstall: true, defaults: defaults)
        var first = LaunchSheetMachine().after([.appeared(notesPending: store.pending != nil)])
        var second = LaunchSheetMachine().after([.appeared(notesPending: store.pending != nil)])

        store.acknowledge()
        _ = first.handle(.notesChanged(pending: store.pending != nil))
        _ = second.handle(.notesChanged(pending: store.pending != nil))
        #expect(!first.isReadyForConsent)
        #expect(!second.isReadyForConsent)
        _ = first.handle(.dismissed(notesPending: store.pending != nil))
        #expect(first.isReadyForConsent)
        #expect(!second.isReadyForConsent)
        _ = second.handle(.dismissed(notesPending: store.pending != nil))
        #expect(second.isReadyForConsent)
        #expect(defaults.integer(forKey: WhatsNewStore.lastSeenBuildKey) == 121)
    }

    @Test func upgradingFromTheChangelogVersionShowsOnlyTheCurrentBuild() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        defaults.set(["fingerprint"], forKey: "whats-new.seen-entries")
        defaults.set(["0.1.0"], forKey: "whats-new.seen-releases")
        let data = try notes([(122, ["B."]), (121, ["A."])])

        // No Hosts saved, so only the legacy keys mark this as an upgrade.
        let store = WhatsNewStore(notes: data, currentBuild: 122, isExistingInstall: false, defaults: defaults)
        #expect(store.pending?.map(\.build) == [122])

        store.acknowledge()
        #expect(defaults.object(forKey: "whats-new.seen-entries") == nil)
        #expect(defaults.object(forKey: "whats-new.seen-releases") == nil)
        #expect(defaults.object(forKey: WhatsNewStore.lastSeenBuildKey) as? Int == 122)
    }

    @Test func runningAnOlderBuildNeverLowersTheMarker() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        defaults.set(125, forKey: WhatsNewStore.lastSeenBuildKey)
        let data = try notes([(123, ["C."]), (122, ["B."])])

        let store = WhatsNewStore(notes: data, currentBuild: 123, isExistingInstall: true, defaults: defaults)

        #expect(store.pending == nil)
        #expect(defaults.object(forKey: WhatsNewStore.lastSeenBuildKey) as? Int == 125)
    }

    @Test func anExistingInstallWithoutAMarkerShowsOnlyTheCurrentBuild() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let data = try notes([(122, ["B."]), (121, ["A."])])

        let store = WhatsNewStore(notes: data, currentBuild: 122, isExistingInstall: true, defaults: defaults)

        #expect(store.pending?.map(\.build) == [122])
    }

    @Test func malformedNotesShowNothing() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        defaults.set(120, forKey: WhatsNewStore.lastSeenBuildKey)

        let store = WhatsNewStore(
            notes: Data(#"{"builds": [{"build": "122"}]}"#.utf8),
            currentBuild: 122, isExistingInstall: true, defaults: defaults)

        #expect(store.pending == nil)
    }

    /// A local device build's `WhatsNew.json`: one entry carrying an `id`.
    private func localNotes(id: String, build: Int) throws -> Data {
        let payload: [String: Any] = [
            "builds": [[
                "id": id, "build": build, "date": "2026-10-11",
                "items": [["symbol": "hammer.fill", "text": "local-build-notes @ abc1234"]],
            ] as [String: Any]],
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    @Test func aLocalBuildShowsEvenBelowTheLastShownBuild() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        defaults.set(146, forKey: WhatsNewStore.lastSeenBuildKey)

        let store = WhatsNewStore(
            notes: try localNotes(id: "a@1-1", build: 145), currentBuild: 145,
            isExistingInstall: true, defaults: defaults, readsLocalNotes: true)

        #expect(store.pending?.map(\.id) == ["a@1-1"])
    }

    @Test func aLocalIDShowsOnceAndANewOneShowsAgain() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        defaults.set(146, forKey: WhatsNewStore.lastSeenBuildKey)
        let first = try localNotes(id: "a@1-1", build: 147)

        let store = WhatsNewStore(notes: first, currentBuild: 147, isExistingInstall: true, defaults: defaults, readsLocalNotes: true)
        #expect(store.pending?.count == 1)
        store.acknowledge()
        #expect(defaults.string(forKey: WhatsNewStore.lastSeenLocalIDKey) == "a@1-1")

        let relaunch = WhatsNewStore(notes: first, currentBuild: 147, isExistingInstall: true, defaults: defaults, readsLocalNotes: true)
        #expect(relaunch.pending == nil)

        // Another worktree, same build number.
        let other = WhatsNewStore(
            notes: try localNotes(id: "b@2-2", build: 147), currentBuild: 147,
            isExistingInstall: true, defaults: defaults, readsLocalNotes: true)
        #expect(other.pending?.map(\.id) == ["b@2-2"])
    }

    @Test func localBuildsLeaveTheBuildMarkerSoTheNextCIBuildStillShows() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        defaults.set(146, forKey: WhatsNewStore.lastSeenBuildKey)

        let local = WhatsNewStore(
            notes: try localNotes(id: "a@1-1", build: 147), currentBuild: 147,
            isExistingInstall: true, defaults: defaults, readsLocalNotes: true)
        local.acknowledge()
        // Relaunching an already-acknowledged local build moves nothing either.
        _ = WhatsNewStore(
            notes: try localNotes(id: "a@1-1", build: 147), currentBuild: 147,
            isExistingInstall: true, defaults: defaults, readsLocalNotes: true)
        #expect(defaults.object(forKey: WhatsNewStore.lastSeenBuildKey) as? Int == 146)

        let testFlight = WhatsNewStore(
            notes: try notes([(147, ["Shipped."])]), currentBuild: 147,
            isExistingInstall: true, defaults: defaults, readsLocalNotes: true)
        #expect(testFlight.pending?.map(\.build) == [147])
        #expect(testFlight.pending?.first?.id == nil)
    }

    @Test func releaseBuildsIgnoreLocalEntries() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        defaults.set(146, forKey: WhatsNewStore.lastSeenBuildKey)

        let store = WhatsNewStore(
            notes: try localNotes(id: "a@1-1", build: 147), currentBuild: 147,
            isExistingInstall: true, defaults: defaults, readsLocalNotes: false)
        #expect(store.pending == nil)
        store.acknowledge()
        #expect(defaults.string(forKey: WhatsNewStore.lastSeenLocalIDKey) == nil)
    }

    @Test func anEmptyLocalEntryShowsNothingAndLeavesTheBuildMarker() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        defaults.set(146, forKey: WhatsNewStore.lastSeenBuildKey)
        let payload: [String: Any] = [
            "builds": [["id": "a@1-1", "build": 147, "date": "2026-10-11", "items": []] as [String: Any]],
        ]

        let store = WhatsNewStore(
            notes: try JSONSerialization.data(withJSONObject: payload), currentBuild: 147,
            isExistingInstall: true, defaults: defaults, readsLocalNotes: true)
        #expect(store.pending == nil)
        #expect(defaults.object(forKey: WhatsNewStore.lastSeenBuildKey) as? Int == 146)
    }

    /// A bundle carrying both a CI entry and a local entry for build 147.
    private func mixedNotes() throws -> Data {
        let payload: [String: Any] = [
            "builds": [
                ["id": "a@1-1", "build": 147, "date": "2026-10-11",
                 "items": [["symbol": "hammer.fill", "text": "Local."]]] as [String: Any],
                ["build": 147, "date": "2026-10-10",
                 "items": [["symbol": "sparkles", "text": "Shipped."]]] as [String: Any],
            ],
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    @Test func aMixedBundleShowsTheLocalEntryInDebug() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        defaults.set(146, forKey: WhatsNewStore.lastSeenBuildKey)

        let store = WhatsNewStore(
            notes: try mixedNotes(), currentBuild: 147,
            isExistingInstall: true, defaults: defaults, readsLocalNotes: true)
        #expect(store.pending?.map(\.id) == ["a@1-1"])
        store.acknowledge()
        #expect(defaults.object(forKey: WhatsNewStore.lastSeenBuildKey) as? Int == 146)
    }

    @Test func aMixedBundleShowsTheCIEntryInRelease() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        defaults.set(146, forKey: WhatsNewStore.lastSeenBuildKey)

        let store = WhatsNewStore(
            notes: try mixedNotes(), currentBuild: 147,
            isExistingInstall: true, defaults: defaults, readsLocalNotes: false)
        #expect(store.pending?.map(\.build) == [147])
        #expect(store.pending?.first?.id == nil)
    }

    @Test func aFreshInstallShowsLocalNotes() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }

        let store = WhatsNewStore(
            notes: try localNotes(id: "a@1-1", build: 147), currentBuild: 147,
            isExistingInstall: false, defaults: defaults, readsLocalNotes: true)
        #expect(store.pending?.map(\.id) == ["a@1-1"])
    }

    @Test func ciNotesAreUnaffectedByLocalNoteSupport() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        defaults.set(120, forKey: WhatsNewStore.lastSeenBuildKey)
        let data = try notes([(122, ["B."]), (121, ["A."])])

        for readsLocalNotes in [true, false] {
            let store = WhatsNewStore(
                notes: data, currentBuild: 122, isExistingInstall: true,
                defaults: defaults, readsLocalNotes: readsLocalNotes)
            #expect(store.pending?.map(\.build) == [122, 121])
        }
    }

    @Test func theAppBundlesDecodableNotes() throws {
        let data = try #require(WhatsNewStore.bundledNotes())
        _ = try WhatsNewStore.builds(from: data)
    }
}
