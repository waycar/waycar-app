import Foundation
import Testing

@testable import Waycar

@Suite("Connection memory machine")
struct ConnectionMemoryMachineTests {
    @Test func unreadableRetriesAndChangedFactsPersistOnlyOnce() {
        let target = ConsoleInventoryCache.Target(Host.fixture())
        var machine = ConnectionMemoryMachine().after([.claim(target), .loaded(1, nil)])
        #expect(machine.state == .unreadable(.init(token: 1, target: target)))
        #expect(machine.handle(.remember(1, .init(homeDirectory: "/partial"))).isEmpty)
        #expect(machine.handle(.loaded(1, .init(protocolVersion: 22))).isEmpty)
        let facts = ConsoleInventoryCache.ConnectionFacts(homeDirectory: "/home/dev", protocolVersion: 22)
        #expect(machine.handle(.remember(1, facts)) == [.persist(target, facts)])
        #expect(machine.handle(.remember(1, facts)).isEmpty)
        #expect(machine.facts(for: 1) == facts)
    }

    @Test func retargetAndRemovalFenceOldClaimsIncludingABA() {
        let host = Host.fixture()
        var replacement = host
        replacement.address = "replacement"
        let first = ConsoleInventoryCache.Target(host)
        let second = ConsoleInventoryCache.Target(replacement)
        var machine = ConnectionMemoryMachine().after([
            .claim(first), .loaded(1, .init(homeDirectory: "/first")), .claim(second)
        ])
        #expect(machine.facts(for: 2) == ConsoleInventoryCache.ConnectionFacts())
        #expect(machine.handle(.remember(1, .init(homeDirectory: "/late"))).isEmpty)
        #expect(machine.handle(.remember(2, .init(homeDirectory: "/second"))) == [
            .persist(second, .init(homeDirectory: "/second"))
        ])
        _ = machine.handle(.claim(first))
        #expect(machine.handle(.loaded(1, .init(homeDirectory: "/late"))).isEmpty)
        #expect(machine.handle(.remember(1, .init(homeDirectory: "/late"))).isEmpty)
        _ = machine.handle(.invalidate)
        #expect(machine.state == .invalidated)
        #expect(machine.handle(.remember(3, .init(homeDirectory: "/late"))).isEmpty)
        _ = machine.handle(.claim(first))
        #expect(machine.token == 4)
    }
}
