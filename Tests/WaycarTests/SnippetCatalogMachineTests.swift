import Foundation
import Testing

@testable import Waycar

@Suite("Snippet catalogue machine")
struct SnippetCatalogMachineTests {
    @Test func readableEditsPersistInManualOrder() throws {
        let a = try Snippet.make(title: "A", body: "one")
        let b = try Snippet.make(title: "B", body: "two")
        let edited = try Snippet.make(id: a.id, title: "Edited", body: "changed")
        var machine = SnippetCatalogMachine()
        #expect(machine.state == .available([]))
        #expect(machine.handle(.add(a)) == [.persist([a])])
        #expect(machine.handle(.add(b)) == [.persist([a, b])])
        #expect(machine.handle(.update(edited)) == [.persist([edited, b])])
        #expect(machine.handle(.move(IndexSet(integer: 1), to: 0)) == [.persist([b, edited])])
        #expect(machine.handle(.remove(b.id)) == [.persist([edited])])
        #expect(machine.snippets == [edited])
        #expect(machine.catalogLoadError == nil)
    }

    @Test func unknownEditsRefuseWithoutChangingTheCatalogue() throws {
        let a = try Snippet.make(title: "A", body: "one")
        var machine = SnippetCatalogMachine()
        #expect(machine.handle(.update(a)) == [.refuse(.unknownSnippet)])
        #expect(machine.handle(.remove(a.id)) == [.refuse(.unknownSnippet)])
        #expect(machine.state == .available([]))
    }

    @Test func unreadableBytesRefuseEveryEditUntilAReadableReload() throws {
        let a = try Snippet.make(title: "A", body: "one")
        var machine = SnippetCatalogMachine().after([.add(a)])
        #expect(machine.handle(.reloaded(.unreadable)) == [])
        #expect(machine.snippets.isEmpty)
        #expect(machine.catalogLoadError == .catalogUnreadable)
        #expect(machine.handle(.add(a)) == [.refuse(.catalogUnreadable)])
        #expect(machine.handle(.update(a)) == [.refuse(.catalogUnreadable)])
        #expect(machine.handle(.remove(a.id)) == [.refuse(.catalogUnreadable)])
        #expect(machine.handle(.move(IndexSet(integer: 0), to: 1)) == [.refuse(.catalogUnreadable)])
        #expect(machine.state == .unreadable)
        #expect(machine.handle(.reloaded(.unreadable)) == [])
        #expect(machine.handle(.reloaded(.available([a]))) == [])
        #expect(machine.snippets == [a])
        #expect(machine.catalogLoadError == nil)
        #expect(machine.handle(.remove(a.id)) == [.persist([])])
    }

    @Test func readableReloadReplacesRatherThanMerges() throws {
        let a = try Snippet.make(title: "A", body: "one")
        var machine = SnippetCatalogMachine().after([.add(a)])
        #expect(machine.handle(.reloaded(.available([]))) == [])
        #expect(machine.state == .available([]))
        #expect(machine.handle(.reloaded(.available([]))) == [])
    }
}
