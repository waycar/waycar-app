import Foundation
import Testing

@testable import Waycar

@Suite("Transcript cache machine")
struct TranscriptCacheMachineTests {
    private let host = UUID()
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func key(_ pane: String = "p1", host: UUID? = nil) -> ChatTranscriptCache.Key {
        ChatTranscriptCache.Key(hostID: host ?? self.host, paneID: pane, terminalID: "t", launchedAt: "")
    }

    private func list(_ text: String) -> [ChatTranscriptMessage] {
        [ChatTranscriptMessage(id: text, role: .assistant, text: text, timestamp: nil)]
    }

    private func found(_ text: String, identity: String = "") -> TranscriptCacheMachine.Found {
        .init(messages: list(text), savedAt: start, identity: identity)
    }

    @Test func anUnknownKeyAsksTheDiskOnceAndRemembersWhatItFound() {
        var machine = TranscriptCacheMachine()
        #expect(machine.messages(for: key(), identity: "") == nil)
        #expect(machine.handle(.diskRead(key(), nil)).isEmpty)
        #expect(machine.messages(for: key(), identity: "") == [])
        #expect(machine.handle(.diskRead(key("p2"), found("a", identity: "x"))).isEmpty)
        #expect(machine.messages(for: key("p2"), identity: "x") == list("a"))
        #expect(machine.messages(for: key("p2"), identity: "") == [])
        #expect(machine.savedAt(for: key("p2")) == start)
    }

    @Test func aHeldListWinsOverALateDiskRead() {
        var machine = TranscriptCacheMachine().after([.saved(key(), list("new"), identity: "", at: start)])
        #expect(machine.handle(.diskRead(key(), found("old"))).isEmpty)
        #expect(machine.handle(.diskRead(key(), nil)).isEmpty)
        #expect(machine.messages(for: key(), identity: "") == list("new"))
    }

    @Test func aReadLandingAfterARemovalStillHoldsWhatItFound() {
        var machine = TranscriptCacheMachine().after([.removed(key())])
        #expect(machine.handle(.diskRead(key(), found("read"))).isEmpty)
        #expect(machine.messages(for: key(), identity: "") == list("read"))
        #expect(machine.state.entries[key()]?.missing == true)
    }

    /// The mark kept beside the raced list answers once the list is gone:
    /// a removal during a read, the read's list kept, then `retainOnly([])`
    /// (or `prune`) reads `[]`, not nil, so the cache never asks the disk
    /// and another writer's later file is not seen (review of CHAT-07). An
    /// owner pin would need the disk read held open, which the cache has no
    /// seam for; a FIFO-held read killed the test host.
    @Test(arguments: [true, false])
    func theMissingMarkOutlivesTheRacedList(byRetain: Bool) {
        var machine = TranscriptCacheMachine().after([.removed(key()), .diskRead(key(), found("read"))])
        _ = machine.handle(byRetain ? .retained([]) : .pruned(key()))
        #expect(machine.state.entries[key()] == .missing)
        #expect(machine.messages(for: key(), identity: "") == [])
        // A save clears it; removing the pane forgets the key.
        _ = machine.handle(.saved(key(), list("new"), identity: "", at: start))
        #expect(machine.state.entries[key()]?.missing == false)
        _ = machine.handle(.removedPane(host, paneID: "p1"))
        #expect(machine.messages(for: key(), identity: "") == nil)
    }

    @Test func savesCoalesceIntoOneQueuedWriteOfTheNewestList() {
        var machine = TranscriptCacheMachine()
        #expect(machine.handle(.saved(key(), list("a"), identity: "", at: start)) == [.scheduleWrite(key())])
        #expect(machine.handle(.saved(key(), list("b"), identity: "", at: start)).isEmpty)
        #expect(machine.handle(.writeDue(key())) == [.write(key(), list("b"), savedAt: start, identity: "")])
        #expect(machine.handle(.writeDue(key())).isEmpty)
        #expect(machine.handle(.saved(key(), list("c"), identity: "", at: start)) == [.scheduleWrite(key())])
    }

    @Test func anEqualSaveUnderTheSameIdentityWritesNothing() {
        var machine = TranscriptCacheMachine().after([.diskRead(key(), found("a"))])
        #expect(machine.handle(.saved(key(), list("a"), identity: "", at: start)).isEmpty)
        #expect(machine.handle(.saved(key(), list("a"), identity: "other", at: start)) == [.scheduleWrite(key())])
        #expect(machine.messages(for: key(), identity: "") == [])
    }

    @Test func confirmingMovesTheTimeOnlyPastTheGranularity() {
        var machine = TranscriptCacheMachine().after([.diskRead(key(), found("a"))])
        #expect(machine.handle(.confirmed(key(), identity: "", at: start.addingTimeInterval(60))).isEmpty)
        let later = start.addingTimeInterval(61)
        #expect(machine.handle(.confirmed(key(), identity: "", at: later)) == [.moved, .scheduleWrite(key())])
        #expect(machine.savedAt(for: key()) == later)
        #expect(machine.handle(.confirmed(key(), identity: "", at: later.addingTimeInterval(61))) == [.moved])
        #expect(machine.handle(.confirmed(key("none"), identity: "", at: later)).isEmpty)
    }

    @Test func removalsForgetWhatTheyCoverAndAskForTheDeletion() {
        let other = UUID()
        var machine = TranscriptCacheMachine().after([
            .diskRead(key("p1"), found("a")), .diskRead(key("p2"), nil),
            .diskRead(key("p1", host: other), found("b")), .diskRead(key("p2", host: other), nil),
        ])
        #expect(machine.handle(.removed(key("p1"))) == [.deleteFile(key("p1"))])
        #expect(machine.state.entries[key("p1")] == .missing)
        #expect(machine.handle(.removedPane(host, paneID: "p1")) == [.deletePane(host, paneID: "p1")])
        #expect(machine.state.entries[key("p1")] == nil)
        #expect(machine.handle(.retained([host])) == [.deleteHosts(except: [host])])
        #expect(machine.state.entries[key("p1", host: other)] == nil)
        #expect(machine.state.entries[key("p2", host: other)] == .missing)
        #expect(machine.state.entries[key("p2")] == .missing)
        #expect(machine.handle(.removedHost(other)) == [.deleteHost(other)])
        #expect(machine.state.entries.keys.map(\.hostID) == [host])
    }

    @Test func pruningForgetsOnlyAHeldListWithNoWriteQueued() {
        var machine = TranscriptCacheMachine().after([
            .diskRead(key("clean"), found("a")), .saved(key("dirty"), list("b"), identity: "", at: start),
            .diskRead(key("missing"), nil),
        ])
        for pane in ["clean", "dirty", "missing", "unknown"] {
            #expect(machine.handle(.pruned(key(pane))).isEmpty)
        }
        #expect(machine.state.entries[key("clean")] == nil)
        #expect(machine.messages(for: key("dirty"), identity: "") == list("b"))
        #expect(machine.state.entries[key("missing")] == .missing)
    }
}
