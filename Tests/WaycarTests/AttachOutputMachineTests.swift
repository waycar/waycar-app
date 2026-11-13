import Foundation
import Testing

@testable import Waycar

@Suite("Attach output machine")
struct AttachOutputMachineTests {
    private typealias Machine = AttachOutputMachine

    private static let a = Data("a".utf8)
    private static let b = Data("b".utf8)
    private static let claimant = 1
    private static let other = 2

    private func read(_ reader: Int = claimant) -> Machine.Event { .read(reader: reader) }

    @Test func theFirstReadClaimsAndParksWithNothingBuffered() {
        var machine = Machine()
        #expect(machine.handle(read()) == [.park])
        #expect(machine.state.consumer == Self.claimant)
        #expect(machine.hasParkedConsumer)
    }

    @Test func aYieldGoesToTheParkedConsumer() {
        var machine = Machine().after([read()])
        #expect(machine.handle(.yield(Self.a)) == [.resumeWaiter(.bytes(Self.a))])
        #expect(!machine.hasParkedConsumer)
        #expect(machine.state.delivery == .open(.init(), waiting: false))
    }

    @Test func yieldsBufferAndDrainInOrder() {
        var machine = Machine().after([.yield(Self.a), .yield(Self.b)])
        #expect(machine.handle(read()) == [.answer(.bytes(Self.a))])
        #expect(machine.handle(read()) == [.answer(.bytes(Self.b))])
        #expect(machine.handle(read()) == [.park])
    }

    @Test func anotherReaderIsRefusedWhetherParkedOrBuffered() {
        var parked = Machine().after([read()])
        #expect(parked.handle(read(Self.other)) == [.answer(.alreadyClaimed)])
        #expect(parked.hasParkedConsumer)

        var buffered = Machine().after([.yield(Self.a), read(), .yield(Self.b)])
        #expect(buffered.handle(read(Self.other)) == [.answer(.alreadyClaimed)])
        #expect(buffered.handle(read()) == [.answer(.bytes(Self.b))])
    }

    @Test func aCleanFinishDrainsThenEnds() {
        var machine = Machine().after([.yield(Self.a), .finish(failed: false)])
        #expect(machine.handle(read()) == [.answer(.bytes(Self.a))])
        #expect(machine.handle(read()) == [.answer(.end)])
        #expect(machine.handle(read()) == [.answer(.end)])
    }

    @Test func aFailedFinishKeepsItsFailureDrainsThenFails() {
        var machine = Machine().after([.yield(Self.a)])
        #expect(machine.handle(.finish(failed: true)) == [.keepFailure])
        #expect(machine.handle(read()) == [.answer(.bytes(Self.a))])
        #expect(machine.handle(read()) == [.answer(.failure)])
    }

    @Test func aFinishEndsOrFailsTheParkedConsumer() {
        var clean = Machine().after([read()])
        #expect(clean.handle(.finish(failed: false)) == [.resumeWaiter(.end)])
        var failed = Machine().after([read()])
        #expect(failed.handle(.finish(failed: true)) == [.keepFailure, .resumeWaiter(.failure)])
    }

    @Test func theFirstFinishWinsAndLaterOutputIsDropped() {
        var machine = Machine().after([.finish(failed: false)])
        #expect(machine.handle(.finish(failed: true)) == [])
        #expect(machine.handle(.yield(Self.a)) == [])
        #expect(machine.handle(read()) == [.answer(.end)])
    }

    @Test func anExplicitEndDiscardsTheBufferAndEndsTheParkedConsumer() {
        var buffered = Machine().after([.yield(Self.a)])
        #expect(buffered.handle(.beginExplicitEnd) == [])
        #expect(buffered.handle(.yield(Self.b)) == [])
        #expect(buffered.handle(read()) == [.answer(.end)])

        var parked = Machine().after([read()])
        #expect(parked.handle(.beginExplicitEnd) == [.resumeWaiter(.end)])
        #expect(parked.handle(.beginExplicitEnd) == [])
    }

    @Test func anExplicitEndAfterAFinishStillDiscards() {
        var machine = Machine().after([.yield(Self.a), .finish(failed: true), .beginExplicitEnd])
        #expect(machine.state.delivery == .ended)
        #expect(machine.handle(read()) == [.answer(.end)])
    }

    @Test func theClaimantsCancellationEndsDelivery() {
        var parked = Machine().after([.yield(Self.a), read(), read()])
        #expect(parked.handle(.consumerCancelled(reader: Self.claimant)) == [.resumeWaiter(.end)])
        #expect(parked.handle(.yield(Self.b)) == [])
        #expect(parked.handle(read()) == [.answer(.end)])
        #expect(parked.handle(read(Self.other)) == [.answer(.alreadyClaimed)])

        var finishing = Machine().after([.yield(Self.a), read(), .yield(Self.b), .finish(failed: false)])
        #expect(finishing.handle(.consumerCancelled(reader: Self.claimant)) == [])
        #expect(finishing.handle(read()) == [.answer(.end)])
    }

    /// #164: a refused reader's cancellation never ends the claimant's output.
    @Test func anotherReadersCancellationIsIgnored() {
        var machine = Machine().after([read()])
        #expect(machine.handle(.consumerCancelled(reader: Self.other)) == [])
        #expect(machine.hasParkedConsumer)
        #expect(machine.handle(.yield(Self.a)) == [.resumeWaiter(.bytes(Self.a))])
    }

    /// A first reader still racing its claim may end delivery.
    @Test func aCancellationBeforeAnyClaimEndsDelivery() {
        var machine = Machine().after([.yield(Self.a)])
        #expect(machine.handle(.consumerCancelled(reader: Self.other)) == [])
        #expect(machine.state.delivery == .ended)
        #expect(machine.handle(read()) == [.answer(.end)])
        #expect(machine.state.consumer == Self.claimant)
    }

    @Test func endedDeliveryIgnoresEveryLaterEnding() {
        var machine = Machine().after([.beginExplicitEnd])
        #expect(machine.handle(.finish(failed: true)) == [])
        #expect(machine.handle(.consumerCancelled(reader: Self.claimant)) == [])
        #expect(machine.handle(.beginExplicitEnd) == [])
        #expect(machine.state.delivery == .ended)
    }
}
