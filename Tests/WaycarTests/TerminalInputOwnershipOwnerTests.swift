import Foundation
import Observation
import Synchronization
import Testing

@testable import Waycar

/// Characterizes the existing controller API independently of its machine.
@MainActor
@Suite("Terminal input ownership owner")
struct TerminalInputOwnershipOwnerTests {
    @Test func inputDoesNotInvalidateObserversOfTheSessionGeneration() {
        let input = TerminalInputController()
        let generation = input.beginSession { _ in }
        let changes = Mutex(0)
        withObservationTracking {
            _ = input.liveGeneration
        } onChange: {
            changes.withLock { $0 += 1 }
        }

        #expect(input.send(Data("a".utf8)))
        #expect(input.insertSnippet("b", bracketedPaste: false))
        #expect(changes.withLock { $0 } == 0)
        input.endSession(generation)
        #expect(changes.withLock { $0 } == 1)
    }

    @Test func aStaleEndKeepsTheReplacementWriterAndScroller() {
        let input = TerminalInputController()
        var oldWrites: [Data] = []
        var newWrites: [Data] = []
        var oldScrolls = 0
        var newScrolls = 0
        let old = input.beginSession(
            writer: { oldWrites.append($0) }, scroller: { _, _ in oldScrolls += 1 })
        let replacement = input.beginSession(
            writer: { newWrites.append($0) }, scroller: { _, _ in newScrolls += 1 })

        input.endSession(old)
        #expect(input.liveGeneration == replacement)
        #expect(input.send(Data("new".utf8)))
        input.scroll(Data("wheel".utf8), rows: 1)
        input.recordSubmitted("old submission", generation: old)
        #expect(input.userMessageIndex.entries.isEmpty)
        #expect(oldWrites.isEmpty)
        #expect(oldScrolls == 0)
        #expect(newWrites == [Data("new".utf8)])
        #expect(newScrolls == 1)

        input.endSession(replacement)
        #expect(input.liveGeneration == nil)
        #expect(!input.send(Data("retired".utf8)))
        input.scroll(Data("wheel".utf8), rows: 1)
        #expect(newScrolls == 1)
    }

    @Test func userInputWaitsInOrderButTerminalReportsBypassTheHold() async throws {
        var release: CheckedContinuation<Void, Never>?
        var leaves = 0
        let history = TmuxPaneHistory(
            scroll: { _, _ in PaneHistoryScroll(position: .inHistory) },
            leave: {
                leaves += 1
                await withCheckedContinuation { release = $0 }
            })
        defer { release?.resume() }
        history.refresh()
        try await waitUntil { history.position == .inHistory }
        let input = TerminalInputController(paneHistory: history)
        var writes: [Data] = []
        var uses = 0
        input.onUserInput = { uses += 1 }
        input.beginSession { writes.append($0) }

        #expect(input.send(Data("a".utf8)))
        try await waitUntil { release != nil }
        #expect(input.insertSnippet("b", bracketedPaste: false))
        #expect(input.sendEscapeKey())
        let report = Data("\u{1B}[I".utf8)
        #expect(input.send(report))
        #expect(writes == [report])
        #expect(uses == 0)
        #expect(leaves == 1)

        release?.resume()
        release = nil
        try await waitUntil { writes.count == 4 }
        #expect(writes == [report, Data("a".utf8), Data("b".utf8), Data([0x1B])])
        #expect(uses == 3)
    }

    @Test func aReplacementDropsPredecessorInputWhileHistoryIsLeaving() async throws {
        var release: CheckedContinuation<Void, Never>?
        let history = TmuxPaneHistory(
            scroll: { _, _ in PaneHistoryScroll(position: .inHistory) },
            leave: { await withCheckedContinuation { release = $0 } })
        defer { release?.resume() }
        history.refresh()
        try await waitUntil { history.position == .inHistory }
        let input = TerminalInputController(paneHistory: history)
        var oldWrites: [Data] = []
        var newWrites: [Data] = []
        let old = input.beginSession { oldWrites.append($0) }
        #expect(input.send(Data("old".utf8)))
        try await waitUntil { release != nil }

        input.detachSessionForReplacement()
        let replacement = input.beginSession { newWrites.append($0) }
        input.endSession(old)
        #expect(input.send(Data("new".utf8)))
        #expect(newWrites.isEmpty)
        release?.resume()
        release = nil

        try await waitUntil { newWrites == [Data("new".utf8)] }
        #expect(input.liveGeneration == replacement)
        #expect(oldWrites.isEmpty)
    }
}
