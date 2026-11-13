import Foundation
import Testing

@testable import Waycar

@MainActor
@Suite("Console multi-selection")
struct ConsoleMultiSelectionTests {
    private func makeAgent(host: Host, paneID: String) -> ConsoleAgent {
        let agent = Agent(
            terminalID: "term_\(paneID)", kind: "codex", title: "Task", status: .idle,
            workspaceID: "w1", tabID: "w1:t1", paneID: paneID, cwd: "/work/w1", revision: 1,
            name: nil, terminalTitle: nil, terminalTitleStripped: nil, paneTitle: nil)
        return ConsoleAgent(
            hostID: host.id,
            hostName: host.displayName,
            agent: agent,
            workspaceLabel: nil,
            repositoryCheckout: nil,
            tabLabel: nil,
            paneLabel: nil)
    }

    // MARK: Selection set

    @Test func toggleAddsThenRemoves() {
        let a = makeAgent(host: .fixture(name: "studio"), paneID: "w1:p1")
        var selection = ConsoleMultiSelection()
        selection.toggle(a.id)
        #expect(selection.contains(a.id))
        #expect(selection.count == 1)
        selection.toggle(a.id)
        #expect(selection.isEmpty)
    }

    @Test func selectAllReplacesExistingSelection() {
        let host = Host.fixture(name: "studio")
        let a = makeAgent(host: host, paneID: "w1:p1")
        let b = makeAgent(host: host, paneID: "w1:p2")
        let c = makeAgent(host: host, paneID: "w1:p3")
        var selection = ConsoleMultiSelection()
        selection.insert(a.id)
        selection.selectAll([b.id, c.id])
        #expect(selection.ids == [b.id, c.id])
    }

    @Test func pruneDropsIdsMissingFromLiveList() {
        let host = Host.fixture(name: "studio")
        let a = makeAgent(host: host, paneID: "w1:p1")
        let b = makeAgent(host: host, paneID: "w1:p2")
        let c = makeAgent(host: host, paneID: "w1:p3")
        var selection = ConsoleMultiSelection()
        selection.selectAll([a.id, b.id])
        selection.prune(keeping: [b.id, c.id])
        #expect(selection.ids == [b.id])
    }

    // MARK: Pin

    @Test func pinActionRules() {
        let host = Host.fixture(name: "studio")
        let a = makeAgent(host: host, paneID: "w1:p1")
        let b = makeAgent(host: host, paneID: "w1:p2")
        #expect(ConsoleBulkActions.pinAction(for: [], isPinned: { _ in true }) == nil)
        #expect(ConsoleBulkActions.pinAction(for: [a, b], isPinned: { _ in true }) == .unpin)
        #expect(ConsoleBulkActions.pinAction(for: [a, b], isPinned: { $0.id == a.id }) == .pin)
    }

    // MARK: Read

    @Test func readActionAllUnreadMarksRead() {
        let host = Host.fixture(name: "studio")
        let agents = [makeAgent(host: host, paneID: "w1:p1"), makeAgent(host: host, paneID: "w1:p2")]
        let action = ConsoleBulkActions.readAction(
            for: agents, isMarkedUnread: { _ in true }, canMarkUnread: { _ in true })
        #expect(action == .markRead)
    }

    @Test func readActionSomeMarkableMarksUnread() {
        let host = Host.fixture(name: "studio")
        let a = makeAgent(host: host, paneID: "w1:p1")
        let b = makeAgent(host: host, paneID: "w1:p2")
        let action = ConsoleBulkActions.readAction(
            for: [a, b], isMarkedUnread: { $0 == a.id }, canMarkUnread: { $0.id == b.id })
        #expect(action == .markUnread)
    }

    @Test func readActionNoneMarkableButSomeUnreadMarksRead() {
        let host = Host.fixture(name: "studio")
        let a = makeAgent(host: host, paneID: "w1:p1")
        let b = makeAgent(host: host, paneID: "w1:p2")
        let action = ConsoleBulkActions.readAction(
            for: [a, b], isMarkedUnread: { $0 == a.id }, canMarkUnread: { _ in false })
        #expect(action == .markRead)
    }

    @Test func readActionNothingApplicableIsNil() {
        let host = Host.fixture(name: "studio")
        let a = makeAgent(host: host, paneID: "w1:p1")
        #expect(
            ConsoleBulkActions.readAction(
                for: [a], isMarkedUnread: { _ in false }, canMarkUnread: { _ in false }) == nil)
        #expect(
            ConsoleBulkActions.readAction(
                for: [], isMarkedUnread: { _ in true }, canMarkUnread: { _ in true }) == nil)
    }

    // MARK: Move

    @Test func moveUnavailableWhenEmpty() {
        #expect(ConsoleBulkActions.moveAvailability(for: []) == .unavailable)
    }

    @Test func moveAvailableOnOneHost() {
        let host = Host.fixture(name: "studio")
        let agents = [makeAgent(host: host, paneID: "w1:p1"), makeAgent(host: host, paneID: "w1:p2")]
        #expect(ConsoleBulkActions.moveAvailability(for: agents) == .available(hostID: host.id))
    }

    @Test func moveSpansHostsListsOneSortedNamePerHost() {
        let host10 = Host.fixture(name: "host10")
        let host9One = Host.fixture(name: "host9")
        let host9Two = Host.fixture(name: "host9")
        let agents = [
            makeAgent(host: host10, paneID: "w1:p1"),
            makeAgent(host: host9One, paneID: "w1:p1"),
            makeAgent(host: host9One, paneID: "w1:p2"),
            makeAgent(host: host9Two, paneID: "w1:p1"),
        ]
        // Plain `<` would put "host10" first; localizedStandardCompare sorts numerically.
        #expect(
            ConsoleBulkActions.moveAvailability(for: agents)
                == .spansHosts(hostNames: [host9One.displayName, host9Two.displayName, host10.displayName]))
    }

    @Test func spansHostsMessageFormatsTwoAndThree() {
        #expect(
            ConsoleBulkActions.spansHostsMessage(hostNames: ["A", "B"])
                == "Your selection is on A and B.")
        #expect(
            ConsoleBulkActions.spansHostsMessage(hostNames: ["A", "B", "C"])
                == "Your selection is on A, B, and C.")
    }
}
