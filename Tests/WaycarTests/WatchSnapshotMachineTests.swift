import Foundation
import Testing
@testable import Waycar

struct WatchSnapshotMachineTests {
    @Test func acceptsEqualOrNewerSnapshotsAndRetainsStateOnMismatch() {
        var machine = WatchSnapshotMachine()
        #expect(machine.snapshot == nil)
        #expect(machine.handle(.snapshot(.empty)) == [.accepted(previous: nil, next: .empty)])
        #expect(machine.handle(.versionMismatch(99)).isEmpty)
        #expect(machine.snapshot == .empty)
        #expect(machine.peerVersion == 99)
        #expect(machine.handle(.snapshot(.empty)) == [.accepted(previous: .empty, next: .empty)])
        #expect(machine.peerVersion == nil)
    }

    @Test func mismatchBeforeFirstSnapshot() {
        var machine = WatchSnapshotMachine()
        #expect(machine.handle(.versionMismatch(0)).isEmpty)
        #expect(machine.snapshot == nil)
        #expect(machine.peerVersion == 0)
        #expect(machine.handle(.snapshot(.empty)) == [.accepted(previous: nil, next: .empty)])
    }

    @Test func rejectedSnapshotCannotClearIncompatibility() {
        let newer = WatchState(generatedAt: Date(timeIntervalSince1970: 2), hosts: [], rows: [], voiceTranscription: true)
        var machine = WatchSnapshotMachine().after([.snapshot(newer), .versionMismatch(99)])
        #expect(machine.handle(.snapshot(.empty)).isEmpty)
        #expect(machine.state == .incompatible(peerVersion: 99, previous: newer))
    }

    @Test func olderSnapshotIsNotApplied() {
        let newer = WatchState(generatedAt: Date(timeIntervalSince1970: 2), hosts: [], rows: [], voiceTranscription: true)
        var machine = WatchSnapshotMachine().after([.snapshot(newer)])
        #expect(machine.handle(.snapshot(.empty)).isEmpty)
        #expect(machine.snapshot == newer)
    }
}
