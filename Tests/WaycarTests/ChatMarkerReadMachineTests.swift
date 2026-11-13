import Foundation
import Testing

@testable import Waycar

@Suite("Chat Marker read machine")
struct ChatMarkerReadMachineTests {
    private typealias Machine = ChatMarkerReadMachine
    private let start = Date(timeIntervalSince1970: 1_000)
    private let interval: TimeInterval = 30

    private func token(_ serial: UInt64, entry: UInt64 = 7) -> Machine.Token {
        Machine.Token(entry: entry, serial: serial)
    }

    /// Verified on herdr, its first read scheduled.
    private var verified: Machine {
        Machine(entry: 7).after([
            .observed(verified: true, fallback: false, verifiedBackends: [.herdr]),
        ])
    }

    @Test func aVerificationStartsWhenTheRowsBecomeVerified() {
        var machine = Machine(entry: 7)
        #expect(machine.handle(.observed(verified: false, fallback: false, verifiedBackends: []))
            .isEmpty)
        #expect(machine.handle(.observed(verified: true, fallback: false, verifiedBackends: [.herdr]))
            == [.keep])
        #expect(machine.verification == 1 && machine.isVerified)
        #expect(machine.handle(.observed(verified: true, fallback: false, verifiedBackends: [.herdr]))
            .isEmpty)
        // A gap is no new verification until the rows verify again.
        #expect(machine.handle(.observed(verified: false, fallback: false, verifiedBackends: []))
            == [.keep])
        #expect(machine.verification == 1)
        _ = machine.handle(.observed(verified: true, fallback: false, verifiedBackends: [.herdr]))
        #expect(machine.verification == 2)
    }

    @Test func movingTheMarkersOrReverifyingABackendStartsAVerification() {
        var machine = verified
        _ = machine.handle(.observed(verified: true, fallback: true, verifiedBackends: [.herdr, .tmux]))
        #expect(machine.verification == 2 && machine.isFallback)
        // Losing a backend alone starts none; regaining it does.
        _ = machine.handle(.observed(verified: true, fallback: true, verifiedBackends: [.tmux]))
        #expect(machine.verification == 2)
        _ = machine.handle(.observed(verified: true, fallback: true, verifiedBackends: [.herdr, .tmux]))
        #expect(machine.verification == 3)
    }

    @Test func aNewVerificationReadsAtOnce() {
        var machine = verified
        #expect(machine.handle(.schedule(now: start, interval: interval))
            == [.start(token(1), wait: 0)])
        #expect(machine.state == .running(token(1)))
        #expect(machine.handle(.schedule(now: start, interval: interval)).isEmpty)
    }

    @Test func aReadThatLandsInItsVerificationConfirms() {
        var machine = verified.after([.schedule(now: start, interval: interval)])
        #expect(machine.handle(.began(eligible: true, now: start)) == [.read(verification: 1)])
        #expect(machine.startedVerification == 1 && machine.startedAt == start)
        #expect(!machine.isConfirmed)
        #expect(machine.handle(.landed(verification: 1)) == [.confirmed])
        #expect(machine.isConfirmed)
        #expect(machine.handle(.ended(token(1))) == [.release])
        #expect(machine.state == .idle)
    }

    @Test func readsInOneVerificationWaitOutTheInterval() {
        var machine = verified.after([
            .schedule(now: start, interval: interval), .began(eligible: true, now: start),
            .landed(verification: 1), .ended(token(1)),
        ])
        #expect(machine.handle(.schedule(now: start.addingTimeInterval(10), interval: interval))
            == [.start(token(2), wait: 20)])
        #expect(machine.state == .waiting(token(2)))
        // Another change inside the interval leaves the wait alone.
        #expect(machine.handle(.schedule(now: start.addingTimeInterval(11), interval: interval))
            .isEmpty)
        #expect(machine.handle(.began(eligible: true, now: start.addingTimeInterval(30)))
            == [.read(verification: 1)])
        #expect(machine.state == .running(token(2)))
    }

    @Test func aNewVerificationPreemptsAWaitingRead() {
        var machine = verified.after([
            .schedule(now: start, interval: interval), .began(eligible: true, now: start),
            .landed(verification: 1), .ended(token(1)),
            .schedule(now: start.addingTimeInterval(10), interval: interval),
            .observed(verified: false, fallback: false, verifiedBackends: []),
            .observed(verified: true, fallback: false, verifiedBackends: [.herdr]),
        ])
        #expect(machine.handle(.schedule(now: start.addingTimeInterval(12), interval: interval))
            == [.cancel(token(2)), .start(token(3), wait: 0)])
        // The preempted Task ending finds a newer token.
        #expect(machine.handle(.ended(token(2))).isEmpty)
        #expect(machine.state == .running(token(3)))
    }

    @Test func aReadSpanningANewVerificationConfirmsNothingAndReschedules() {
        var machine = verified.after([
            .schedule(now: start, interval: interval), .began(eligible: true, now: start),
            .observed(verified: false, fallback: false, verifiedBackends: []),
            .observed(verified: true, fallback: false, verifiedBackends: [.herdr]),
        ])
        // The running read holds back a second one.
        #expect(machine.handle(.schedule(now: start, interval: interval)).isEmpty)
        #expect(machine.handle(.landed(verification: 1)).isEmpty)
        #expect(!machine.isConfirmed)
        #expect(machine.handle(.ended(token(1))) == [.release, .reschedule])
        #expect(machine.handle(.schedule(now: start, interval: interval))
            == [.start(token(2), wait: 0)])
    }

    @Test func anIneligibleReadEndsWithoutRecordingAStart() {
        var machine = verified.after([.schedule(now: start, interval: interval)])
        #expect(machine.handle(.began(eligible: false, now: start)).isEmpty)
        #expect(machine.startedVerification == nil)
        // Its verification never had a read, so its end asks for one.
        #expect(machine.handle(.ended(token(1))) == [.release, .reschedule])
    }

    @Test func aWaitingReadThatEndsIneligibleIsReleased() {
        var machine = verified.after([
            .schedule(now: start, interval: interval), .began(eligible: true, now: start),
            .landed(verification: 1), .ended(token(1)),
            .schedule(now: start.addingTimeInterval(1), interval: interval),
        ])
        #expect(machine.handle(.began(eligible: false, now: start.addingTimeInterval(30))).isEmpty)
        #expect(machine.state == .waiting(token(2)))
        #expect(machine.handle(.ended(token(2))) == [.release])
        #expect(machine.state == .idle)
    }

    @Test func tokensNameTheirEntry() {
        var machine = verified.after([.schedule(now: start, interval: interval)])
        #expect(machine.handle(.ended(token(1, entry: 6))).isEmpty)
        #expect(machine.state == .running(token(1)))
        var idle = Machine(entry: 7)
        #expect(idle.handle(.ended(token(1))).isEmpty)
    }

    /// A Task cancelled after its sleep ended still begins; it reads and
    /// confirms by verification, as before.
    @Test func aStaleReaderStillBeginsAndConfirmsByVerification() {
        var machine = verified.after([.schedule(now: start, interval: interval)])
        #expect(machine.handle(.began(eligible: true, now: start)) == [.read(verification: 1)])
        #expect(machine.handle(.began(eligible: true, now: start)) == [.read(verification: 1)])
        #expect(machine.handle(.landed(verification: 1)) == [.confirmed])
        #expect(machine.handle(.landed(verification: 0)).isEmpty)
    }
}
