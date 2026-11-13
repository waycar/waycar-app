#if DEBUG || WAYCAR_ADMIN
import Foundation
import Testing

@testable import Waycar

@MainActor
struct ReviewPromptAdminRequestTests {
    private final class Counter: @unchecked Sendable {
        var calls = 0
    }

    private func makeStore() throws -> (store: ReviewPromptStore, cleanup: () -> Void) {
        let name = "review-admin-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        let store = ReviewPromptStore(defaults: defaults, marketingVersion: "1.2.0")
        return (store, { defaults.removePersistentDomain(forName: name) })
    }

    @Test func firesOnceAfterTheDelayAndLeavesCountersAlone() async throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        store.recordValueEvent()
        let before = store.state
        let fired = Counter()
        store.registerRootRequest { fired.calls += 1 }

        let slept = Counter()
        let task = store.requestSheetForAdmin(
            after: .seconds(5),
            sleep: { duration in
                #expect(duration == .seconds(5))
                slept.calls += 1
            })
        #expect(fired.calls == 0)
        await task?.value

        #expect(slept.calls == 1)
        #expect(fired.calls == 1)
        #expect(store.state == before)
    }

    @Test func doesNothingWithoutARegisteredClosure() async throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        let before = store.state
        let slept = Counter()

        let task = store.requestSheetForAdmin(sleep: { _ in slept.calls += 1 })
        #expect(task == nil)
        #expect(slept.calls == 0)
        #expect(store.state == before)

        let fired = Counter()
        let token = store.registerRootRequest { fired.calls += 1 }
        store.unregisterRootRequest(token: token)
        #expect(store.requestSheetForAdmin(sleep: { _ in }) == nil)
        #expect(fired.calls == 0)
    }

    @Test func readsTheClosureAfterTheWait() async throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        let old = Counter()
        let new = Counter()
        store.registerRootRequest { old.calls += 1 }

        let task = store.requestSheetForAdmin(sleep: { _ in
            await MainActor.run { _ = store.registerRootRequest { new.calls += 1 } }
        })
        await task?.value

        #expect(old.calls == 0)
        #expect(new.calls == 1)
    }

    @Test func unregisteringDuringTheWaitFiresNothing() async throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        let fired = Counter()
        let token = store.registerRootRequest { fired.calls += 1 }

        let task = store.requestSheetForAdmin(sleep: { _ in
            await MainActor.run { store.unregisterRootRequest(token: token) }
        })
        await task?.value

        #expect(fired.calls == 0)
    }

    @Test func aStaleTokenDoesNotClearANewerRegistration() async throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        let old = Counter()
        let new = Counter()
        let oldToken = store.registerRootRequest { old.calls += 1 }
        store.registerRootRequest { new.calls += 1 }

        store.unregisterRootRequest(token: oldToken)
        let task = store.requestSheetForAdmin(sleep: { _ in })
        await task?.value

        #expect(old.calls == 0)
        #expect(new.calls == 1)
    }

    @Test func aCancelledSleepFiresNothing() async throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        let fired = Counter()
        store.registerRootRequest { fired.calls += 1 }

        let task = store.requestSheetForAdmin(sleep: { _ in throw CancellationError() })
        await task?.value

        #expect(fired.calls == 0)
    }
}
#endif
