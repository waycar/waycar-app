import Foundation
import Testing

@testable import Waycar

@Suite("herdr-core inventory", .timeLimit(.minutes(1)))
struct CoreInventoryTests {
    // MARK: Helpers

    private static func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    /// One notification line as the events channel carries it.
    private static func notification(line: String) throws -> CoreNotification {
        let value = try json(line)
        let params = try #require(value["params"])
        guard case .number(let seqValue)? = params["seq"], let seq = Int(exactly: seqValue) else {
            throw CocoaError(.coderInvalidValue)
        }
        switch value["method"]?.stringValue {
        case "heartbeat":
            return .heartbeat(seq: seq)
        case "event":
            return .event(
                CoreEvent(
                    seq: seq, type: try #require(params["type"]?.stringValue),
                    terminal: params["terminal"]?.stringValue, data: params["data"] ?? .null))
        default:
            throw CocoaError(.coderInvalidValue)
        }
    }

    /// The captured notifications by `seq` (heartbeats by their own `seq`,
    /// after the event that has it), in capture order.
    private static func capturedNotifications() throws -> [CoreNotification] {
        try CoreTranscripts.eventFrames
            .flatMap { $0.split(separator: "\n").map(String.init) }
            .map(notification(line:))
    }

    private static func event(
        _ seq: Int, _ type: String, _ terminal: String?, _ data: String = "{}"
    ) throws -> CoreNotification {
        .event(CoreEvent(seq: seq, type: type, terminal: terminal, data: try json(data)))
    }

    private static func terminal(
        _ address: String, state: String = "live", status: CoreStatus? = nil,
        reported: Bool = false, foreground: CoreForeground? = nil
    ) -> CoreTerminal {
        CoreTerminal(
            address: address, state: state, status: status, reported: reported,
            foreground: foreground)
    }

    private static func inventory(
        seq: Int = 100, _ terminals: [CoreTerminal]
    ) -> CoreInventory {
        CoreInventory(CoreSubscription(channel: 1, seq: seq, terminals: terminals))
    }

    // MARK: Snapshot

    @Test func aSnapshotKeepsCoresOrderIncludingFinishedTerminals() {
        let inventory = Self.inventory(
            seq: 103, [Self.terminal("t2"), Self.terminal("t1", state: "finished"), Self.terminal("box/t3")])
        #expect(inventory.terminals.map(\.address) == ["t2", "t1", "box/t3"])
        #expect(inventory.seq == 103)
        #expect(inventory.terminal(address: "t1")?.isFinished == true)
        #expect(inventory.terminal(address: "nope") == nil)
    }

    @Test func aNewSnapshotReplacesEverything() {
        var inventory = Self.inventory(seq: 500, [Self.terminal("t1"), Self.terminal("t2")])
        inventory.replace(
            with: CoreSubscription(channel: 1, seq: 15, terminals: [Self.terminal("t9")]))
        #expect(inventory.terminals.map(\.address) == ["t9"])
        #expect(inventory.seq == 15)
    }

    // MARK: The captured sequence

    @Test func theCapturedEventSequenceProducesTheExpectedStateAndEffects() throws {
        // The snapshot before the capture: seq 103, one unrelated terminal.
        var inventory = Self.inventory(seq: 103, [Self.terminal("t1")])
        var effects: [Int: [CoreInventory.Effect]] = [:]
        var snapshots: [Int: [CoreTerminal]] = [:]
        for notification in try Self.capturedNotifications() {
            let result = inventory.apply(notification)
            if case .event(let event) = notification {
                effects[event.seq] = result
                snapshots[event.seq] = inventory.terminals
            } else {
                #expect(result.isEmpty, "a heartbeat changes nothing")
            }
        }
        let t1d = CoreInventory.Effect.status(address: "t1d")
        let resync = CoreInventory.Effect.resync
        let expected: [Int: [CoreInventory.Effect]] = [
            104: [resync], 105: [t1d], 106: [.paneUpdated(address: "t1d")], 107: [resync],
            108: [t1d], 109: [], 110: [], 111: [], 112: [], 113: [], 114: [resync], 115: [],
            116: [t1d], 117: [resync], 118: [resync], 119: [resync], 120: [], 121: [resync],
            122: [resync], 123: [resync], 124: [resync], 125: [resync], 126: [resync],
            127: [resync], 128: [resync], 129: [resync],
        ]
        for seq in expected.keys.sorted() {
            #expect(effects[seq] == expected[seq], "seq \(seq)")
        }

        func record(_ seq: Int, _ address: String) throws -> CoreTerminal {
            try #require(snapshots[seq]?.first { $0.address == address }, "seq \(seq) \(address)")
        }
        // created: the whole record, appended after the snapshot's terminal.
        #expect(snapshots[104]?.map(\.address) == ["t1", "t1d"])
        #expect(try record(104, "t1d").name == "ev1")
        #expect(try record(104, "t1d").labels == ["a": "b"])
        #expect(try record(104, "t1d").createdMs == 1_793_309_148_244)
        // status, title, foreground, turn.
        #expect(try record(105, "t1d").status == CoreStatus(state: "working", app: "fake"))
        #expect(try record(105, "t1d").reported)
        #expect(try record(106, "t1d").title == "mytitle")
        #expect(try record(107, "t1d").foreground?.name == "sh")
        #expect(try record(108, "t1d").status?.state == "idle")
        #expect(try record(109, "t1d").turn == 1)
        // size, labels, keep.
        #expect(try record(112, "t1d").cols == 52 && record(112, "t1d").rows == 28)
        #expect(try record(113, "t1d").cols == 200 && record(113, "t1d").rows == 120)
        #expect(try record(114, "t1d").labels == ["a": "b", "x": "y"])
        #expect(try record(115, "t1d").keep)
        // The status cleared before `lost`; `lost` keeps the terminal live.
        let lost = try record(117, "t1d")
        #expect(lost.status == nil)
        #expect(lost.state == "live")
        #expect(lost.reason == "signaled")
        #expect(lost.reported, "`reported` is a history, not a state")
        // `restarted` replaces the whole record in place: nothing of the old
        // run survives.
        #expect(snapshots[118]?.map(\.address) == ["t1", "t1d"])
        let restarted = try record(118, "t1d")
        #expect(restarted.argv == ["/bin/sh"])
        #expect(restarted.reported == false)
        #expect(restarted.title == "")
        #expect(restarted.reason == nil)
        #expect(restarted.status == nil)
        #expect(restarted.foreground == nil)
        #expect(restarted.keep)
        #expect(restarted.turn == 1)
        #expect(restarted.statusMs == 1_793_309_154_140)
        #expect(restarted.labels == ["a": "b", "x": "y"])
        #expect(try record(119, "t1d").foreground?.argv == ["/bin/sh"])
        // `finished` keeps the record, with its exit fields and no status.
        let killed = try record(121, "t1d")
        #expect(killed.isFinished)
        #expect(killed.reason == "killed")
        #expect(killed.signal == 1)
        #expect(killed.exitCode == nil)
        #expect(killed.finishedMs == 1_793_309_158_946)
        #expect(killed.status == nil)
        // `removed` drops it.
        #expect(snapshots[122]?.map(\.address) == ["t1"])
        // The end: the two later terminals finished and are still listed.
        #expect(inventory.terminals.map(\.address) == ["t1", "t1f", "t1g"])
        let exited5 = try #require(inventory.terminal(address: "t1f"))
        #expect(exited5.isFinished && exited5.exitCode == 5 && exited5.reason == "exited")
        #expect(inventory.terminal(address: "t1g")?.exitCode == 0)
        #expect(try record(125, "t1f").foreground?.name == "sleep")
        #expect(inventory.seq == 129)
    }

    // MARK: seq

    @Test func eventsAtOrBelowTheLastSeqAreIgnored() throws {
        var inventory = Self.inventory(seq: 10, [Self.terminal("t1")])
        let rename = try Self.event(11, "title", "t1", #"{"title":"new"}"#)
        #expect(inventory.apply(rename) == [.paneUpdated(address: "t1")])
        let before = inventory
        #expect(inventory.apply(rename).isEmpty, "the same seq again")
        #expect(inventory.apply(try Self.event(10, "removed", "t1")).isEmpty, "the snapshot's own seq")
        #expect(inventory.apply(try Self.event(3, "finished", "t1")).isEmpty)
        #expect(inventory == before)
        #expect(inventory.apply(try Self.event(12, "title", "t1", #"{"title":"newer"}"#)).count == 1)
        #expect(inventory.terminal(address: "t1")?.title == "newer")
        #expect(inventory.seq == 12)
    }

    @Test func missedReplacesEverythingAndRaisesTheFloor() throws {
        var inventory = Self.inventory(seq: 10, [Self.terminal("t1"), Self.terminal("t2")])
        let effects = inventory.apply(
            .missed(seq: 80, terminals: [Self.terminal("t2", state: "finished"), Self.terminal("t5")]))
        #expect(effects == [.resync])
        #expect(inventory.terminals.map(\.address) == ["t2", "t5"])
        #expect(inventory.terminal(address: "t2")?.isFinished == true)
        #expect(inventory.seq == 80)
        #expect(inventory.apply(try Self.event(80, "removed", "t5")).isEmpty)
        #expect(inventory.apply(try Self.event(70, "removed", "t5")).isEmpty)
        #expect(inventory.terminals.count == 2)
        #expect(inventory.apply(try Self.event(81, "removed", "t5")) == [.resync])
        #expect(inventory.terminals.map(\.address) == ["t2"])
    }

    @Test func aHeartbeatChangesNothing() {
        var inventory = Self.inventory(seq: 10, [Self.terminal("t1")])
        let before = inventory
        #expect(inventory.apply(.heartbeat(seq: 99)).isEmpty)
        #expect(inventory == before)
    }

    // MARK: Per-type behaviour

    @Test func aStatusEffectNeedsANewWordOrANewReportedFlag() throws {
        var inventory = Self.inventory(
            seq: 1, [Self.terminal("t1", status: CoreStatus(state: "working", app: "fake"), reported: true)])
        // Same word, new app and message: no effect.
        let sameWord = try Self.event(
            2, "status", "t1",
            #"{"records":{},"reported":true,"status":{"app":"other","msg":"thinking","state":"working"},"status_ms":1793309154140}"#)
        #expect(inventory.apply(sameWord).isEmpty)
        let record = try #require(inventory.terminal(address: "t1"))
        #expect(record.status?.app == "other")
        #expect(record.status?.msg == "thinking")
        #expect(record.statusMs == 1_793_309_154_140)
        // A new word.
        let done = try Self.event(3, "status", "t1", #"{"reported":true,"status":{"state":"done"}}"#)
        #expect(inventory.apply(done) == [.status(address: "t1")])
        // `blocked` keeps its kind.
        let blocked = try Self.event(
            4, "status", "t1", #"{"reported":true,"status":{"kind":"permission","state":"blocked"}}"#)
        #expect(inventory.apply(blocked) == [.status(address: "t1")])
        #expect(inventory.terminal(address: "t1")?.status?.kind == "permission")
        // The status cleared.
        let cleared = try Self.event(5, "status", "t1", #"{"reported":true,"status":null}"#)
        #expect(inventory.apply(cleared) == [.status(address: "t1")])
        #expect(inventory.terminal(address: "t1")?.status == nil)
        // The first report of a program: the flag flips with no status word change.
        var fresh = Self.inventory(seq: 1, [Self.terminal("t2")])
        let first = try Self.event(2, "status", "t2", #"{"reported":true,"status":null}"#)
        #expect(fresh.apply(first) == [.status(address: "t2")])
    }

    @Test func aForegroundEffectDependsOnWhatChanged() throws {
        let sh = CoreForeground(pid: 5, name: "sh", argv: ["sh"], cwd: "/a")
        var inventory = Self.inventory(seq: 1, [Self.terminal("t1", foreground: sh)])
        // Only the folder: a row detail.
        let cd = try Self.event(
            2, "foreground", "t1", #"{"argv":["sh"],"cwd":"/b","name":"sh","pid":5}"#)
        #expect(inventory.apply(cd) == [.paneUpdated(address: "t1")])
        // Only the pid: nothing a row shows.
        let newPid = try Self.event(
            3, "foreground", "t1", #"{"argv":["sh"],"cwd":"/b","name":"sh","pid":9}"#)
        #expect(inventory.apply(newPid).isEmpty)
        // A new program: the identity may change, so a resync.
        let claude = try Self.event(
            4, "foreground", "t1", #"{"argv":["node","claude"],"cwd":"/b","name":"node","pid":9}"#)
        #expect(inventory.apply(claude) == [.resync])
        // Same name, different argv (Claude renames its process): still a resync.
        let argv = try Self.event(
            5, "foreground", "t1", #"{"argv":["node","codex"],"cwd":"/b","name":"node","pid":9}"#)
        #expect(inventory.apply(argv) == [.resync])
        #expect(inventory.terminal(address: "t1")?.foreground?.argv == ["node", "codex"])
    }

    @Test func eventsThatNeedNoEffectUpdateTheRecord() throws {
        var inventory = Self.inventory(seq: 1, [Self.terminal("t1")])
        #expect(inventory.apply(try Self.event(2, "turn", "t1", #"{"state":"idle","turn":4}"#)).isEmpty)
        #expect(inventory.apply(try Self.event(3, "size", "t1", #"{"cols":52,"rows":28}"#)).isEmpty)
        #expect(inventory.apply(try Self.event(4, "keep", "t1", #"{"keep":true}"#)).isEmpty)
        let record = try #require(inventory.terminal(address: "t1"))
        #expect(record.turn == 4 && record.cols == 52 && record.rows == 28 && record.keep)
    }

    @Test func unknownTypesDocAndUnknownAddressesAreIgnored() throws {
        var inventory = Self.inventory(seq: 1, [Self.terminal("t1")])
        let before = inventory.terminals
        #expect(inventory.apply(try Self.event(2, "doc", nil, #"{"name":"probe","version":2}"#)).isEmpty)
        #expect(inventory.apply(try Self.event(3, "mood", "t1", #"{"mood":"fine"}"#)).isEmpty)
        #expect(inventory.apply(try Self.event(4, "status", "t9", #"{"reported":true,"status":{"state":"idle"}}"#)).isEmpty)
        #expect(inventory.apply(try Self.event(5, "finished", "t9")).isEmpty)
        #expect(inventory.apply(try Self.event(6, "removed", "t9")).isEmpty)
        #expect(inventory.apply(try Self.event(7, "labels", "t9", #"{"labels":{"a":"b"}}"#)).isEmpty)
        #expect(inventory.terminals == before)
    }

    @Test func createdAppendsAndRestartedReplacesInPlace() throws {
        var inventory = Self.inventory(seq: 1, [Self.terminal("t1"), Self.terminal("t2")])
        let record = #"{"address":"t1","argv":["/bin/sh"],"state":"live","title":"fresh","reported":false}"#
        #expect(inventory.apply(try Self.event(2, "restarted", "t1", record)) == [.resync])
        #expect(inventory.terminals.map(\.address) == ["t1", "t2"])
        #expect(inventory.terminal(address: "t1")?.title == "fresh")
        #expect(
            inventory.apply(try Self.event(3, "restarted", "t7", #"{"address":"t7","state":"live"}"#))
                == [.resync])
        #expect(inventory.terminals.map(\.address) == ["t1", "t2", "t7"])
        // A record that carries no address of its own takes the event's.
        #expect(inventory.apply(try Self.event(4, "created", "t8", #"{"state":"live"}"#)) == [.resync])
        #expect(inventory.terminal(address: "t8") != nil)
    }

    @Test func labelsFinishedAndLostEffects() throws {
        var inventory = Self.inventory(
            seq: 1,
            [Self.terminal("t1", status: CoreStatus(state: "idle"), reported: true), Self.terminal("t2", status: CoreStatus(state: "idle"), reported: true)])
        #expect(
            inventory.apply(try Self.event(2, "labels", "t1", #"{"labels":{"herdr.space":"s1"}}"#))
                == [.resync])
        #expect(inventory.terminal(address: "t1")?.labels == ["herdr.space": "s1"])
        // lost: the terminal stays live, its status is gone.
        #expect(
            inventory.apply(try Self.event(3, "lost", "t1", #"{"exit_code":null,"finished_ms":null,"reason":"signaled","signal":9}"#))
                == [.resync])
        #expect(inventory.terminal(address: "t1")?.state == "live")
        #expect(inventory.terminal(address: "t1")?.status == nil)
        // finished: marked finished, exit fields set, status cleared.
        #expect(
            inventory.apply(try Self.event(4, "finished", "t2", #"{"exit_code":3,"finished_ms":1793307229389,"reason":"exited","signal":null}"#))
                == [.resync])
        let finished = try #require(inventory.terminal(address: "t2"))
        #expect(finished.isFinished && finished.exitCode == 3 && finished.status == nil)
        #expect(inventory.terminals.map(\.address) == ["t1", "t2"])
    }
}
