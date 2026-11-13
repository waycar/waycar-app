import Foundation
import SwiftUI

/// Catalogue bytes are either readable and editable, or untouched. An empty
/// readable catalogue is not the same as bytes this build cannot understand.
struct SnippetCatalogMachine: StateMachine {
    enum State: Equatable, Sendable {
        case available([Snippet])
        case unreadable
    }

    enum Event: Sendable {
        case reloaded(State)
        case add(Snippet)
        case update(Snippet)
        case remove(Snippet.ID)
        case move(IndexSet, to: Int)
    }

    enum Effect: Equatable, Sendable {
        case persist([Snippet])
        case refuse(SnippetStoreError)
    }

    private(set) var state: State = .available([])

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (_, .reloaded(let loaded)):
            state = loaded
            return []
        case (.available(var items), .add(let snippet)):
            items.append(snippet)
            return replace(items)
        case (.available(var items), .update(let snippet)):
            guard let index = items.firstIndex(where: { $0.id == snippet.id }) else {
                return [.refuse(.unknownSnippet)]
            }
            items[index] = snippet
            return replace(items)
        case (.available(var items), .remove(let id)):
            guard let index = items.firstIndex(where: { $0.id == id }) else {
                return [.refuse(.unknownSnippet)]
            }
            items.remove(at: index)
            return replace(items)
        case (.available(var items), .move(let source, let destination)):
            items.move(fromOffsets: source, toOffset: destination)
            return replace(items)
        case (.unreadable, .add), (.unreadable, .update),
             (.unreadable, .remove), (.unreadable, .move):
            return [.refuse(.catalogUnreadable)]
        }
    }

    var snippets: [Snippet] {
        if case .available(let items) = state { return items }
        return []
    }

    var catalogLoadError: SnippetStoreError? {
        if case .unreadable = state { return .catalogUnreadable }
        return nil
    }

    private mutating func replace(_ items: [Snippet]) -> [Effect] {
        state = .available(items)
        return [.persist(items)]
    }
}
