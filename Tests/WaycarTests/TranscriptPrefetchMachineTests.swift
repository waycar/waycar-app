import Foundation
import Testing

@testable import Waycar

struct TranscriptPrefetchMachineTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let host = UUID()
    private var id: ConsoleAgent.ID { .init(hostID: host, paneID: "a") }

    @Test func aPassIsSingleFlightAndOnlyActualAttemptsGetCooldowns() {
        var machine = TranscriptPrefetchMachine()
        #expect(machine.handle(.update(active: true, hasDue: true, now: now, nextWake: nil)) == [.run(1)])
        #expect(machine.canTry(id, now: now))
        #expect(machine.handle(.update(active: true, hasDue: true, now: now, nextWake: nil)).isEmpty)
        #expect(machine.handle(.attempted(1, id, now: now)).isEmpty)
        #expect(!machine.canTry(id, now: now + 599))
        #expect(machine.canTry(id, now: now + 600))
        #expect(machine.handle(.ended(1, active: true, now: now, nextWake: now + 600)) == [.sleep(2, .seconds(600))])
        #expect(machine.handle(.woke(2)) == [.update])
        #expect(machine.state == .idle)
    }

    @Test func cancelledFailureCannotCoolDownHostOrEndTheReplacementPass() {
        var machine = TranscriptPrefetchMachine().after([
            .update(active: true, hasDue: true, now: now, nextWake: nil),
            .attempted(1, id, now: now), .cancel,
            .update(active: true, hasDue: true, now: now, nextWake: nil),
        ])
        let other = ConsoleAgent.ID(hostID: host, paneID: "b")
        #expect(machine.handle(.unreadable(1, host, now: now)).isEmpty)
        #expect(machine.canTry(other, now: now))
        #expect(machine.handle(.ended(1, active: true, now: now, nextWake: now + 600)).isEmpty)
        #expect(machine.ownsPass(2))
        #expect(machine.handle(.unreadable(2, host, now: now)).isEmpty)
        #expect(!machine.canTry(other, now: now + 599))
        #expect(machine.canTry(other, now: now + 600))
    }

    @Test func cancellationRetainsAttemptsButAnUnstartedPassHasNone() {
        var machine = TranscriptPrefetchMachine().after([
            .update(active: true, hasDue: true, now: now, nextWake: nil), .cancel,
        ])
        #expect(machine.canTry(id, now: now))
        #expect(machine.handle(.attempted(1, id, now: now)).isEmpty)
        #expect(machine.canTry(id, now: now))
        _ = machine.handle([
            .update(active: true, hasDue: true, now: now, nextWake: nil),
            .attempted(2, id, now: now), .cancel,
        ])
        #expect(!machine.canTry(id, now: now))
    }

    @Test func returningDuringCooldownReplacesWakeAndRejectsTheOldOne() {
        var machine = TranscriptPrefetchMachine()
        #expect(machine.handle(.update(active: false, hasDue: true, now: now, nextWake: nil)).isEmpty)
        #expect(machine.handle(.update(active: true, hasDue: false, now: now, nextWake: now + 600)) == [.sleep(1, .seconds(600))])
        #expect(machine.handle(.cancel) == [.cancel(1)])
        #expect(machine.handle(.update(active: true, hasDue: false, now: now + 10, nextWake: now + 600)) == [.sleep(2, .seconds(590))])
        #expect(machine.handle(.woke(1)).isEmpty)
        #expect(machine.handle(.update(active: true, hasDue: true, now: now, nextWake: nil)) == [.cancel(2), .run(3)])
        #expect(machine.handle(.woke(2)).isEmpty)
        #expect(machine.handle(.ended(3, active: false, now: now, nextWake: nil)).isEmpty)
        #expect(machine.state == .idle)
    }

    @Test func wakeDeadlineCombinesCopyAttemptAndHostCooldowns() {
        var machine = TranscriptPrefetchMachine().after([
            .update(active: true, hasDue: true, now: now, nextWake: nil),
            .attempted(1, id, now: now + 10), .unreadable(1, host, now: now + 20),
        ])
        let candidates = [TranscriptPrefetchMachine.Candidate(id: id, savedAt: now + 30)]
        #expect(machine.nextWake(for: candidates, now: now) == now + 630)
        #expect(machine.nextWake(for: [], now: now) == nil)
        #expect(machine.handle(.ended(1, active: true, now: now, nextWake: nil)).isEmpty)
        #expect(machine.state == .idle)
        #expect(machine.handle(.unreadable(1, host, now: now + 100)).isEmpty)
        #expect(machine.handle(.woke(1)).isEmpty)
    }
}
