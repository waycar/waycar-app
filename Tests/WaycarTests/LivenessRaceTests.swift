import Foundation
import Synchronization
import Testing

@testable import Waycar

/// `LivenessRace` (#105, HERDR-14) through its own API: a proof raced
/// against its deadline and a hedge that starts once the proof is slow or
/// has failed on the link. The first success wins, a hedge that succeeds
/// after the race is decided is discarded, and when both fail the hedge's
/// failure is thrown. Time is a `ScriptedLivenessClock`; the proof and the
/// hedge answer when the test says, ignoring cancellation like a stalled
/// SSH call.
@Suite("LivenessRace", .timeLimit(.minutes(1)))
struct LivenessRaceTests {
    private static let deadline = Duration.seconds(2)
    private static let hedgeDelay = Duration.milliseconds(200)
    private let proofLink = TransportError.sshUnreachable(detail: "proof")
    private let hedgeLink = TransportError.sshUnreachable(detail: "hedge")
    private let answer = TransportError.apiRejected(code: "busy", message: "no")

    private struct Race {
        let clock = ScriptedLivenessClock()
        let proof = Pending<String>()
        let hedge = Pending<String>()
        let discarded = Discards()

        func start(hedged: Bool = true) -> Task<LivenessRace.Outcome<String, String>, any Error> {
            let clock = clock
            let proof = proof
            let hedge = hedge
            let discarded = discarded
            return Task {
                try await LivenessRace.run(
                    deadline: LivenessRaceTests.deadline,
                    clock: clock.clock,
                    proof: { try await proof.value() },
                    hedge: hedged
                        ? LivenessRace.Hedging(
                            after: LivenessRaceTests.hedgeDelay,
                            startsOn: { EventsSession.isTransportLinkFailure($0) },
                            start: { try await hedge.value() },
                            discard: { discarded.record($0) })
                        : nil)
            }
        }

        func startHedgeByTimer() async throws {
            #expect(await clock.waitForSleep(LivenessRaceTests.hedgeDelay))
            #expect(clock.fire(LivenessRaceTests.hedgeDelay) == 1)
            try await waitUntil("the hedge should start") { await hedge.entries == 1 }
        }
    }

    private func proven(_ outcome: LivenessRace.Outcome<String, String>) -> String? {
        if case .proof(let value) = outcome { value } else { nil }
    }

    private func hedged(_ outcome: LivenessRace.Outcome<String, String>) -> String? {
        if case .hedge(let value) = outcome { value } else { nil }
    }

    @Test func aProofThatAnswersFirstWinsAndTheHedgeNeverStarts() async throws {
        let race = Race()
        let running = race.start()
        try await waitUntil("the proof should start") { await race.proof.entries == 1 }
        await race.proof.resolve(.success("proof"))
        #expect(proven(try await running.value) == "proof")
        #expect(await race.hedge.entries == 0)
        // The hedge's timer went with the race.
        #expect(race.clock.fire(Self.hedgeDelay) == 0)
        #expect(race.clock.fire(Self.deadline) == 0)
    }

    @Test func aHedgeThatAnswersWhileTheProofIsSlowWins() async throws {
        let race = Race()
        let running = race.start()
        try await race.startHedgeByTimer()
        await race.hedge.resolve(.success("hedge"))
        #expect(hedged(try await running.value) == "hedge")
        // The proof answering later changes nothing.
        await race.proof.resolve(.success("late proof"))
        #expect(race.discarded.values.isEmpty)
    }

    @Test func aProofThatAnswersWhileTheHedgeDialsWinsAndTheLateHedgeIsDiscarded() async throws {
        let race = Race()
        let running = race.start()
        try await race.startHedgeByTimer()
        await race.proof.resolve(.success("proof"))
        #expect(proven(try await running.value) == "proof")
        await race.hedge.resolve(.success("late hedge"))
        try await waitUntil("the late hedge should be discarded") {
            race.discarded.values == ["late hedge"]
        }
    }

    @Test func aProofThatFailsOnTheServerFailsTheRaceWithoutAHedge() async throws {
        let race = Race()
        let running = race.start()
        try await waitUntil("the proof should start") { await race.proof.entries == 1 }
        await race.proof.resolve(.failure(answer))
        await #expect(throws: answer) { try await running.value }
        #expect(await race.hedge.entries == 0)
        #expect(race.clock.fire(Self.hedgeDelay) == 0)
    }

    @Test func aProofThatFailsOnTheLinkStartsTheHedgeAtOnce() async throws {
        let race = Race()
        let running = race.start()
        try await waitUntil("the proof should start") { await race.proof.entries == 1 }
        await race.proof.resolve(.failure(proofLink))
        try await waitUntil("the hedge should start without its timer") {
            await race.hedge.entries == 1
        }
        await race.hedge.resolve(.success("hedge"))
        #expect(hedged(try await running.value) == "hedge")
    }

    @Test func whenBothFailTheHedgesFailureIsThrown() async throws {
        let race = Race()
        let running = race.start()
        try await waitUntil("the proof should start") { await race.proof.entries == 1 }
        await race.proof.resolve(.failure(proofLink))
        try await waitUntil("the hedge should start") { await race.hedge.entries == 1 }
        await race.hedge.resolve(.failure(hedgeLink))
        await #expect(throws: hedgeLink) { try await running.value }
    }

    // Resolving a `Pending` only releases its waiter: it does not show that
    // the race recorded the outcome. So these owner pins assert only what
    // every order of the two releases yields; the order-dependent rules
    // (a hedge failure recorded first outranks a later link failure of the
    // proof, but not a later server answer) are `LivenessRaceMachineTests`'.

    /// A failed hedge does not decide the race: a proof that answers wins,
    /// in whichever order the two land.
    @Test func aFailedHedgeLeavesTheRaceToAProofThatAnswers() async throws {
        let race = Race()
        let running = race.start()
        try await race.startHedgeByTimer()
        await race.hedge.resolve(.failure(hedgeLink))
        await race.proof.resolve(.success("proof"))
        #expect(proven(try await running.value) == "proof")
    }

    /// Both fail on the link while both are out: the hedge's failure is
    /// thrown, in whichever order the two land.
    @Test func whenBothFailOnTheLinkWhileRacingTheHedgesFailureIsThrown() async throws {
        let race = Race()
        let running = race.start()
        try await race.startHedgeByTimer()
        await race.hedge.resolve(.failure(hedgeLink))
        await race.proof.resolve(.failure(proofLink))
        await #expect(throws: hedgeLink) { try await running.value }
        #expect(await race.hedge.entries == 1)
    }

    /// A proof the server answers while the hedge still dials decides the
    /// race with that answer; the hedge failing afterwards changes nothing.
    /// The hedge stays blocked until the race is decided.
    @Test func aProofTheServerAnswersWhileTheHedgeDialsThrowsItsOwnFailure() async throws {
        let race = Race()
        let running = race.start()
        try await race.startHedgeByTimer()
        await race.proof.resolve(.failure(answer))
        await #expect(throws: answer) { try await running.value }
        await race.hedge.resolve(.failure(hedgeLink))
    }

    @Test func theDeadlineFailsTheProofOnTheLinkAndStartsTheHedge() async throws {
        let race = Race()
        let running = race.start()
        try await waitUntil("the proof should start") { await race.proof.entries == 1 }
        #expect(await race.clock.waitForSleep(Self.deadline))
        race.clock.fire(Self.deadline)
        try await waitUntil("the hedge should start once the deadline passed") {
            await race.hedge.entries == 1
        }
        await race.hedge.resolve(.success("hedge"))
        #expect(hedged(try await running.value) == "hedge")
        await race.proof.resolve(.failure(CancellationError()))
    }

    @Test func withoutAHedgeTheProofDecides() async throws {
        let race = Race()
        let running = race.start(hedged: false)
        try await waitUntil("the proof should start") { await race.proof.entries == 1 }
        await race.proof.resolve(.failure(proofLink))
        await #expect(throws: proofLink) { try await running.value }
        #expect(race.clock.fire(Self.hedgeDelay) == 0)

        let unhedgedTimeout = Race()
        let timing = unhedgedTimeout.start(hedged: false)
        #expect(await unhedgedTimeout.clock.waitForSleep(Self.deadline))
        unhedgedTimeout.clock.fire(Self.deadline)
        await #expect(throws: TransportError.timedOut) { try await timing.value }
        await unhedgedTimeout.proof.resolve(.failure(CancellationError()))
    }

    @Test func cancellingTheCallerEndsTheRace() async throws {
        let race = Race()
        let running = race.start()
        try await waitUntil("the proof should start") { await race.proof.entries == 1 }
        #expect(await race.clock.waitForSleep(Self.hedgeDelay))
        running.cancel()
        await #expect(throws: CancellationError.self) { try await running.value }
        #expect(race.clock.fire(Self.hedgeDelay) == 0)
        #expect(await race.hedge.entries == 0)
        await race.proof.resolve(.failure(CancellationError()))
    }
}

/// A value the test hands a waiting proof or hedge. It ignores
/// cancellation, as a stalled SSH call does.
private actor Pending<Value: Sendable> {
    private var result: Result<Value, any Error>?
    private var waiters: [CheckedContinuation<Result<Value, any Error>, Never>] = []
    private(set) var entries = 0

    func value() async throws -> Value {
        entries += 1
        if let result { return try result.get() }
        let result = await withCheckedContinuation { waiters.append($0) }
        return try result.get()
    }

    func resolve(_ result: Result<Value, any Error>) {
        self.result = result
        let resuming = waiters
        waiters.removeAll()
        for waiter in resuming { waiter.resume(returning: result) }
    }
}

/// The hedges a race discarded, in order.
private final class Discards: Sendable {
    private let recorded = Mutex<[String]>([])

    var values: [String] { recorded.withLock { $0 } }

    func record(_ value: String) {
        recorded.withLock { $0.append(value) }
    }
}
