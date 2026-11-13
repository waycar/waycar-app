import Foundation
import Testing

@testable import Waycar

@Suite("Session usage follow machine")
struct SessionUsageFollowMachineTests {
    private let start = ContinuousClock.now
    private let path = "/home/dev/.omp/sessions/s.jsonl"

    @Test func aFirstRefreshDropsTotalsFollowsThePathAndReadsTheConfig() {
        var machine = SessionUsageFollowMachine()
        #expect(machine.handle(.refreshed(path: path, now: start)) == [.dropTotals, .readConfig(1)])
        #expect(machine.state.file == .following(path: path))
        #expect(machine.state.current == 1)
    }

    @Test func aConfigAnswerIsKeptForAMinuteAndThenReadAgain() {
        var machine = SessionUsageFollowMachine().after([.refreshed(path: path, now: start)])
        #expect(machine.handle(.configRead(1, showsRate: true, now: start)) == [.showTokenRate(true), .follow(1)])
        #expect(machine.state.config == .read(at: start))
        #expect(machine.handle(.refreshed(path: path, now: start.advanced(by: .seconds(59)))) == [.follow(2)])
        #expect(machine.handle(.refreshed(path: path, now: start.advanced(by: .seconds(60)))) == [.readConfig(3)])
    }

    @Test func aFailedConfigReadFollowsAndLeavesTheConfigUnread() {
        var machine = SessionUsageFollowMachine().after([.refreshed(path: path, now: start)])
        #expect(machine.handle(.configRead(1, showsRate: nil, now: start)) == [.follow(1)])
        #expect(machine.state.config == .unread)
    }

    @Test func anotherPathDropsTheFileAndItsConfig() {
        var machine = SessionUsageFollowMachine().after([
            .refreshed(path: path, now: start), .configRead(1, showsRate: true, now: start),
        ])
        #expect(machine.handle(.refreshed(path: "/other.jsonl", now: start)) == [.dropTotals, .readConfig(2)])
        #expect(machine.state.file == .following(path: "/other.jsonl"))
    }

    @Test func everyStepOfAnOlderRefreshIsStale() {
        var machine = SessionUsageFollowMachine().after([
            .refreshed(path: path, now: start), .refreshed(path: path, now: start),
        ])
        #expect(machine.handle(.configRead(1, showsRate: true, now: start)).isEmpty)
        #expect(machine.state.config == .unread)
        #expect(machine.handle(.chunkRead(1, fileExists: true)).isEmpty)
        #expect(machine.handle(.chunkRead(1, fileExists: false)).isEmpty)
        #expect(machine.state.file == .following(path: path))
        #expect(machine.handle(.followed(1)).isEmpty)
        #expect(machine.handle(.lookupEnded(1, selector: "p/m", .answered(1))).isEmpty)
    }

    @Test func aCurrentChunkFoldsAndAVanishedFileDropsItThenLooksUp() {
        var machine = SessionUsageFollowMachine().after([
            .refreshed(path: path, now: start), .configRead(1, showsRate: true, now: start),
        ])
        #expect(machine.handle(.chunkRead(1, fileExists: true)) == [.foldChunk(1)])
        #expect(machine.handle(.followed(1)) == [.lookUpWindow(1)])
        #expect(machine.handle(.chunkRead(1, fileExists: false)) == [.dropTotals, .lookUpWindow(1)])
        #expect(machine.state.file == .none)
        #expect(machine.state.config == .unread)
    }

    @Test func clearingDropsTheFileButLeavesTheRefreshCurrent() {
        var machine = SessionUsageFollowMachine().after([.refreshed(path: path, now: start)])
        #expect(machine.handle(.cleared) == [.dropTotals])
        #expect(machine.state.file == .none)
        #expect(machine.state.current == 1)
        #expect(machine.handle(.chunkRead(1, fileExists: true)) == [.foldChunk(1)])
        #expect(machine.handle(.refreshed(path: path, now: start)) == [.dropTotals, .readConfig(2)])
    }

    @Test func oneSelectorAtATimeAndAnyEndFreesTheSlot() {
        var machine = SessionUsageFollowMachine().after([.refreshed(path: path, now: start)])
        #expect(machine.handle(.lookupNeeded(1, selector: "p/a")) == [.resolve(1, selector: "p/a")])
        _ = machine.handle(.refreshed(path: path, now: start))
        #expect(machine.handle(.lookupNeeded(2, selector: "p/a")).isEmpty)
        #expect(machine.handle(.lookupNeeded(2, selector: "p/b")) == [.resolve(2, selector: "p/b")])
        #expect(machine.state.lookup == .resolving(selector: "p/b"))
        #expect(machine.handle(.lookupEnded(1, selector: "p/a", .answered(5))).isEmpty)
        #expect(machine.state.lookup == .idle)
        #expect(machine.handle(.lookupNeeded(2, selector: "p/b")) == [.resolve(2, selector: "p/b")])
    }

    @Test func onlyACurrentAnswerIsRemembered() {
        var machine = SessionUsageFollowMachine().after([
            .refreshed(path: path, now: start), .lookupNeeded(1, selector: "p/a"),
        ])
        #expect(machine.handle(.lookupEnded(1, selector: "p/a", .dropped)).isEmpty)
        _ = machine.handle(.lookupNeeded(1, selector: "p/a"))
        #expect(machine.handle(.lookupEnded(1, selector: "p/a", .answered(nil)))
            == [.rememberWindow(selector: "p/a", nil)])
        #expect(machine.state.lookup == .idle)
    }
}
