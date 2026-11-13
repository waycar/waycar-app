import Testing

@testable import Waycar

@Suite("Natural voice model machine")
struct NaturalVoiceModelMachineTests {
    private let downloading = NaturalVoiceModelMachine.Operation(token: 1, model: .pocket, kind: .download)
    private let deleting = NaturalVoiceModelMachine.Operation(token: 1, model: .pocket, kind: .delete)

    @Test func refreshChecksAndPublishesTheWholeSnapshot() {
        var machine = NaturalVoiceModelMachine()
        let snapshot = NaturalVoiceModelMachine.Snapshot(
            phases: [.pocket: .installed(bytes: 123)], voices: [:], freed: [.pocket: 123],
            download: [.pocket: 456], total: 123)
        #expect(machine.handle(.refresh) == [.readSnapshot(1)])
        #expect(machine.state == .checking(1))
        #expect(machine.handle(.snapshot(1, snapshot)).isEmpty)
        #expect(machine.snapshot == snapshot)
        #expect(machine.state == .ready)
    }

    @Test func newerSnapshotDemandSupersedesAnOlderRead() {
        var machine = NaturalVoiceModelMachine().after([.refresh])
        #expect(machine.handle(.refresh) == [.readSnapshot(2)])
        #expect(machine.handle(.snapshot(1, .init(total: 100))).isEmpty)
        #expect(machine.snapshot.total == 0)
        #expect(machine.state == .checking(2))
        #expect(machine.handle(.snapshot(2, .init(total: 200))).isEmpty)
        #expect(machine.snapshot.total == 200)
    }

    @Test func downloadPreparesThenRefreshesWithoutOpeningTheWorkSlotEarly() {
        var machine = NaturalVoiceModelMachine()
        #expect(machine.handle(.download(.pocket)) == [.download(downloading)])
        #expect(machine.state == .downloading(downloading))
        #expect(machine.busyModel == .pocket)
        #expect(machine.isDownloading)
        #expect(!machine.fetched)
        #expect(machine.handle(.progress(1, 0.5)).isEmpty)
        #expect(machine.snapshot.phases[.pocket] == .downloading(0.5))
        #expect(machine.handle(.fetched(1)).isEmpty)
        #expect(machine.state == .preparing(downloading))
        #expect(machine.fetched)
        #expect(machine.snapshot.phases[.pocket] == .preparing)
        #expect(machine.handle(.progress(1, 0.9)).isEmpty)
        #expect(machine.snapshot.phases[.pocket] == .preparing)
        #expect(machine.handle(.completed(1)) == [.clearWork(1), .readSnapshot(2)])
        #expect(machine.busyModel == nil)
        #expect(!machine.isDownloading)
        #expect(machine.snapshot.phases[.pocket] == .preparing)
    }

    @Test func deletionUsesCheckingAndTheSameSerializedSlot() {
        var machine = NaturalVoiceModelMachine()
        #expect(machine.handle(.delete(.pocket)) == [.delete(deleting)])
        #expect(machine.state == .deleting(deleting))
        #expect(!machine.isDownloading)
        #expect(machine.snapshot.phases[.pocket] == .checking)
        #expect(machine.handle(.refresh).isEmpty)
        #expect(machine.handle(.download(.kokoro)).isEmpty)
        #expect(machine.handle(.delete(.kokoro)).isEmpty)
        #expect(machine.handle(.completed(1)) == [.clearWork(1), .readSnapshot(2)])
    }

    @Test func cancelRetainsNetworkExclusionUntilWorkActuallyCompletes() {
        for fetched in [false, true] {
            var machine = NaturalVoiceModelMachine().after([.download(.pocket)])
            if fetched { _ = machine.handle(.fetched(1)) }
            #expect(machine.handle(.cancel) == [.cancel(1)])
            #expect(machine.state == .cancelling(downloading, fetched: fetched))
            #expect(machine.isDownloading)
            #expect(machine.fetched == fetched)
            #expect(machine.handle(.cancel) == [.cancel(1)])
            #expect(machine.handle(.download(.kokoro)).isEmpty)
            #expect(machine.handle(.delete(.kokoro)).isEmpty)
            #expect(machine.handle(.delete(.pocket)) == [.cancel(1)])
            #expect(machine.handle(.completed(1)) == [.clearWork(1), .readSnapshot(2)])
        }
    }

    @Test func cancellingWorkCanFinishFetchingBeforeCleanup() {
        var machine = NaturalVoiceModelMachine().after([.download(.pocket), .cancel])
        #expect(machine.handle(.progress(1, 0.5)).isEmpty)
        #expect(machine.snapshot.phases[.pocket] == .downloading(0.5))
        #expect(machine.handle(.fetched(1)).isEmpty)
        #expect(machine.fetched)
        #expect(machine.snapshot.phases[.pocket] == .preparing)
        #expect(machine.handle(.progress(1, 0.9)).isEmpty)
        #expect(machine.snapshot.phases[.pocket] == .preparing)
        var deletion = NaturalVoiceModelMachine().after([.delete(.pocket)])
        #expect(deletion.handle(.delete(.pocket)) == [.cancel(1)])
        #expect(deletion.handle(.fetched(1)).isEmpty)
        #expect(deletion.handle(.progress(1, 0.5)).isEmpty)
        #expect(!deletion.isDownloading)
        #expect(deletion.snapshot.phases[.pocket] == .checking)
    }

    @Test func staleReadsAndWorkCompletionsCannotOverwriteNewWork() {
        var machine = NaturalVoiceModelMachine().after([.refresh])
        #expect(machine.handle(.download(.pocket)) == [.download(.init(token: 2, model: .pocket, kind: .download))])
        #expect(machine.handle([
            .snapshot(1, .init(total: 123)), .progress(1, 0.9), .fetched(1), .completed(1),
        ]).isEmpty)
        #expect(machine.snapshot.total == 0)
        #expect(machine.snapshot.phases[.pocket] == .downloading(0))
        #expect(machine.handle(.completed(2)) == [.clearWork(2), .readSnapshot(3)])
        #expect(machine.handle(.delete(.kokoro)) == [.delete(.init(token: 4, model: .kokoro, kind: .delete))])
        #expect(machine.handle(.snapshot(3, .init(total: 456))).isEmpty)
        #expect(machine.handle(.completed(2)).isEmpty)
        #expect(machine.busyModel == .kokoro)
    }

    @Test func idleAndActiveStatesIgnoreUnrelatedEvents() {
        var idle = NaturalVoiceModelMachine()
        #expect(idle.handle([.cancel, .progress(1, 1), .fetched(1), .completed(1), .snapshot(1, .init())]).isEmpty)
        for setup in [
            [NaturalVoiceModelMachine.Event.download(.pocket)],
            [.download(.pocket), .fetched(1)], [.download(.pocket), .cancel], [.delete(.pocket)],
        ] {
            var machine = NaturalVoiceModelMachine().after(setup)
            #expect(machine.handle([.refresh, .download(.kokoro), .snapshot(99, .init()), .completed(99)]).isEmpty)
        }
    }
}
